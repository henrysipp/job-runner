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
    private let maxConcurrent: Int

    private var isStarted = false
    private var isStopped = false
    private var isProcessing = false
    private var networkCallbackId: UUID?

    public init(context: Context, store: JobStore = InMemoryJobStore(), maxConcurrent: Int = 4) {
        self.context = context
        self.store = store
        registry = JobRegistry()
        self.maxConcurrent = maxConcurrent
    }

    public func register<J: Job>(_ type: J.Type) async throws where J.Context == Context {
        guard !isStarted else {
            throw JobError.registrationAfterStart
        }
        registry.register(type)
    }

    public func start() async throws {
        guard !isStarted else { return }
        isStarted = true
        isStopped = false

        await NetworkMonitor.shared.start()
        networkCallbackId = await NetworkMonitor.shared.addCallback { [weak self] in
            Task { [weak self] in
                await self?.processQueue()
            }
        }

        let runningJobs = try await store.loadAll(status: .running)
        for var job in runningJobs {
            job.status = .pending
            try await store.save(job)
        }

        Task { await processQueue() }
    }

    public func stop() async {
        isStopped = true
        if let callbackId = networkCallbackId {
            await NetworkMonitor.shared.removeCallback(callbackId)
            networkCallbackId = nil
        }
    }

    public func enqueue<J: Job>(_ job: J, priority: Priority = .medium) async throws where J.Context == Context {
        guard isStarted else {
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

        Task { await processQueue() }
    }

    private func processQueue() async {
        guard !isStopped else { return }
        guard !isProcessing else { return }

        isProcessing = true
        defer { isProcessing = false }

        let now = Date.now

        while !isStopped {
            let runningCount = (try? await store.loadAll(status: .running).count) ?? 0
            guard runningCount < maxConcurrent else { break }

            let pendingJobs = (try? await store.loadAll(status: .pending)) ?? []
            let eligibleJobs = await filterEligibleJobs(pendingJobs, now: now)
            let sorted = sortedByPriority(eligibleJobs)
            guard let next = sorted.first else { break }

            var running = next
            running.status = .running
            try? await store.save(running)

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
        guard !isStopped else { return }

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
            guard !isStopped else { return }
            await processQueue()
        }
    }

    private func executeJob(_ serialized: SerializedJob) async {
        do {
            let job = try registry.decode(serialized)
            try await job.run(context: context)

            try? await store.delete(id: serialized.id)
            await jobCompleted()

        } catch {
            await jobFailed(serialized, error: error)
        }
    }

    private func jobCompleted() async {
        Task { await processQueue() }
    }

    private func jobFailed(_ serialized: SerializedJob, error: Error) async {
        var updated = serialized
        updated.attempts += 1
        updated.lastAttemptedAt = Date.now

        if case JobFailure.permanent = error {
            updated.status = .permanentlyFailed
            try? await store.save(updated)
            Task { await processQueue() }
            return
        }

        guard let retry = updated.constraints.retry else {
            updated.status = .permanentlyFailed
            try? await store.save(updated)
            Task { await processQueue() }
            return
        }

        if updated.attempts >= retry.maxAttempts {
            updated.status = .permanentlyFailed
        } else if let delay = retry.delay(forAttempt: updated.attempts) {
            updated.status = .pending
            updated.scheduledAt = Date.now.addingTimeInterval(delay)
        } else {
            updated.status = .pending
            updated.scheduledAt = nil
        }

        try? await store.save(updated)
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
