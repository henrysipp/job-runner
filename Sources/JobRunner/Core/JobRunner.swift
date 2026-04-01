//
//  JobRunner.swift
//  job-runner
//
//  Created by Henry on 2/3/26.
//

import Foundation

public actor JobRunner<Context: Sendable>: JobRunnerProtocol {
    public let context: Context
    private let store: JobStore
    private let registry: JobRegistry<Context>
    private let concurrencyPolicy: ConcurrencyPolicy
    private let eventHandler: (any JobEventHandler)?

    private var isRunning = false
    private var isProcessing = false
    private var networkCallbackId: UUID?
    private var statusContinuations: [UUID: AsyncStream<QueueStatus>.Continuation] = [:]

    public init(
        context: Context,
        store: JobStore = InMemoryJobStore(),
        concurrencyPolicy: ConcurrencyPolicy = FixedConcurrencyPolicy(limit: 3),
        eventHandler: (any JobEventHandler)? = nil
    ) {
        self.context = context
        self.store = store
        registry = JobRegistry()
        self.concurrencyPolicy = concurrencyPolicy
        self.eventHandler = eventHandler
    }

    public init(context: Context, store: JobStore = InMemoryJobStore(), maxConcurrent: Int, eventHandler: (any JobEventHandler)? = nil) {
        self.init(context: context, store: store, concurrencyPolicy: FixedConcurrencyPolicy(limit: maxConcurrent), eventHandler: eventHandler)
    }

    public var statusStream: AsyncStream<QueueStatus> {
        AsyncStream { continuation in
            let id = UUID()
            statusContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeContinuation(id)
                }
            }
            Task { [weak self] in
                if let status = await self?.currentStatus() {
                    continuation.yield(status)
                }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        statusContinuations.removeValue(forKey: id)
    }

    public func currentStatus() async -> QueueStatus {
        let pending = (try? await store.count(status: .pending)) ?? 0
        let running = (try? await store.count(status: .running)) ?? 0
        let failed = (try? await store.count(status: .permanentlyFailed)) ?? 0
        return QueueStatus(pending: pending, running: running, failed: failed)
    }

    private func emitStatus() async {
        let status = await currentStatus()
        for continuation in statusContinuations.values {
            continuation.yield(status)
        }
    }

    public func register<J: Job>(_ type: J.Type) async throws where J.Context == Context {
        guard !isRunning else {
            throw JobError.registrationAfterStart
        }
        registry.register(type)
    }

    public func start() async throws {
        guard !isRunning else { return }
        isRunning = true

        await NetworkMonitor.shared.start()

        // Capture callback ID before any await that could allow stop() to interleave
        let callbackId = await NetworkMonitor.shared.addCallback { [weak self] in
            Task { [weak self] in
                await self?.processQueue()
            }
        }

        // Check if stop() was called during the await
        guard isRunning else {
            await NetworkMonitor.shared.removeCallback(callbackId)
            return
        }
        networkCallbackId = callbackId
        let runningJobs = try await store.loadAll(status: .running)
        for var job in runningJobs {
            job.status = .pending
            try await store.save(job)
        }

        await emitStatus()
        Task { await processQueue() }
    }

    public func stop() async {
        isRunning = false
        if let callbackId = networkCallbackId {
            await NetworkMonitor.shared.removeCallback(callbackId)
            networkCallbackId = nil
        }
    }

    public func enqueue<J: Job>(_ job: J, priority: Priority = .medium) async throws where J.Context == Context {
        guard isRunning else {
            throw JobError.notStarted
        }

        let (typeName, jobData) = try registry.encode(job)

        let serialized = SerializedJob(
            id: UUID(),
            typeName: typeName,
            priority: priority,
            constraints: job.constraints,
            originalCreatedAt: Date.now,
            lastAttemptedAt: nil,
            scheduledAt: nil,
            attempts: 0,
            status: .pending,
            jobData: jobData
        )

        try await store.save(serialized)

        await eventHandler?.jobEnqueued(JobEnqueuedEvent(
            id: serialized.id,
            jobType: J.self,
            priority: priority,
            jobData: String(data: jobData, encoding: .utf8) ?? ""
        ))

        await emitStatus()

        Task { await processQueue() }
    }

    private func processQueue() async {
        guard isRunning else { return }
        guard !isProcessing else { return }

        isProcessing = true
        defer { isProcessing = false }

        let now = Date.now

        while isRunning {
            let runningCount = (try? await store.count(status: .running)) ?? 0
            let maxConcurrent = await concurrencyPolicy.maxConcurrent()
            guard runningCount < maxConcurrent else { break }

            let pendingJobs = (try? await store.loadAll(status: .pending)) ?? []
            let eligibleJobs = await filterEligibleJobs(pendingJobs, now: now)
            let sorted = sortedByPriority(eligibleJobs)
            guard let next = sorted.first else { break }

            var running = next
            running.status = .running
            try? await store.save(running)
            await emitStatus()

            Task {
                await executeJob(running)
            }
        }

        scheduleWakeUpIfNeeded()
    }

    private func filterEligibleJobs(_ jobs: [SerializedJob], now: Date) async -> [SerializedJob] {
        var eligible: [SerializedJob] = []

        for job in jobs {
            if let scheduledAt = job.scheduledAt, scheduledAt > now {
                continue
            }

            if let connectivity = job.constraints.connectivity {
                let satisfies = await NetworkMonitor.shared.satisfies(connectivity)
                if !satisfies {
                    continue
                }
            }

            eligible.append(job)
        }

        return eligible
    }

    private func scheduleWakeUpIfNeeded() {
        guard isRunning else { return }

        Task {
            let pendingJobs = (try? await store.loadAll(status: .pending)) ?? []
            let now = Date.now

            let nextScheduled = pendingJobs
                .compactMap { $0.scheduledAt }
                .filter { $0 > now }
                .min()

            guard let nextWake = nextScheduled else { return }

            let delay = nextWake.timeIntervalSince(now)
            guard delay > 0 else { return }

            try? await Task.sleep(for: .seconds(delay))
            guard isRunning else { return }
            await processQueue()
        }
    }

    private func executeJob(_ serialized: SerializedJob) async {
        let jobDataString = String(data: serialized.jobData, encoding: .utf8) ?? ""

        do {
            let job = try registry.decode(serialized)
            let jobType = type(of: job) as Any.Type

            await eventHandler?.jobStarted(JobStartedEvent(
                id: serialized.id,
                jobType: jobType,
                attempt: serialized.attempts + 1,
                jobData: jobDataString
            ))

            let clock = ContinuousClock()
            let start = clock.now
            try await job.run(context: context)
            let duration = clock.now - start

            await eventHandler?.jobCompleted(JobCompletedEvent(
                id: serialized.id,
                jobType: jobType,
                duration: duration,
                jobData: jobDataString
            ))

            try? await store.delete(id: serialized.id)
            await jobCompleted()

        } catch {
            await jobFailed(serialized, error: error)
        }
    }

    private func jobCompleted() async {
        await emitStatus()
        Task { await processQueue() }
    }

    private func jobFailed(_ serialized: SerializedJob, error: Error) async {
        var updated = serialized
        updated.attempts += 1
        updated.lastAttemptedAt = Date.now

        let jobType = registry.resolveType(serialized.typeName) ?? Never.self as Any.Type
        let sendableError = error as any Error & Sendable
        let jobDataString = String(data: serialized.jobData, encoding: .utf8) ?? ""

        if case .permanent(_)? = error as? JobFailure {
            updated.status = .permanentlyFailed
            try? await store.save(updated)

            await eventHandler?.jobFailed(JobFailedEvent(
                id: serialized.id,
                jobType: jobType,
                error: sendableError,
                attempt: updated.attempts,
                willRetry: false,
                nextRetryAt: nil,
                jobData: jobDataString
            ))

            await emitStatus()
            Task { await processQueue() }
            return
        }

        guard let retry = updated.constraints.retry else {
            updated.status = .permanentlyFailed
            try? await store.save(updated)

            await eventHandler?.jobFailed(JobFailedEvent(
                id: serialized.id,
                jobType: jobType,
                error: sendableError,
                attempt: updated.attempts,
                willRetry: false,
                nextRetryAt: nil,
                jobData: jobDataString
            ))

            await emitStatus()
            Task { await processQueue() }
            return
        }

        var willRetry = false
        var nextRetryAt: Date?

        if updated.attempts >= retry.maxAttempts {
            updated.status = .permanentlyFailed
        } else if let delay = retry.delay(forAttempt: updated.attempts) {
            updated.status = .pending
            updated.scheduledAt = Date.now.addingTimeInterval(delay)
            willRetry = true
            nextRetryAt = updated.scheduledAt
        } else {
            updated.status = .pending
            updated.scheduledAt = nil
            willRetry = true
        }

        try? await store.save(updated)

        await eventHandler?.jobFailed(JobFailedEvent(
            id: serialized.id,
            jobType: jobType,
            error: sendableError,
            attempt: updated.attempts,
            willRetry: willRetry,
            nextRetryAt: nextRetryAt,
            jobData: jobDataString
        ))

        await emitStatus()
        Task { await processQueue() }
    }

    private func sortedByPriority(_ jobs: [SerializedJob]) -> [SerializedJob] {
        jobs.sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority
            }
            return lhs.originalCreatedAt < rhs.originalCreatedAt
        }
    }
}
