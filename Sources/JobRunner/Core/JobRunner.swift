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
    private var delegate: (any JobRunnerDelegate)?

    private var isRunning = false
    private var isProcessing = false
    private var networkCallbackId: UUID?
    private var statusContinuations: [UUID: AsyncStream<QueueStatus>.Continuation] = [:]
    private struct RunningTask {
        let token: UUID
        let job: SerializedJob
        let task: Task<Void, Never>
    }
    private var runningTasks: [UUID: RunningTask] = [:]
    private var lifecycleGeneration = 0
    private var startingGeneration: Int?
    private var hasRecoveredStore = false
    private enum BackgroundOutcome { case succeeded, failed, interrupted }
    private var backgroundOutcomes: [UUID: BackgroundOutcome]?
    private var wakeUpTask: Task<Void, Never>?
    private var executionContext: ExecutionContext = .foreground

    public init(
        context: Context,
        store: JobStore = InMemoryJobStore(),
        concurrencyPolicy: ConcurrencyPolicy = FixedConcurrencyPolicy(limit: 3)
    ) {
        self.context = context
        self.store = store
        registry = JobRegistry()
        self.concurrencyPolicy = concurrencyPolicy
    }

    public init(
        context: Context,
        store: JobStore = InMemoryJobStore(),
        maxConcurrent: Int
    ) {
        self.init(
            context: context,
            store: store,
            concurrencyPolicy: FixedConcurrencyPolicy(limit: maxConcurrent)
        )
    }

    public func setDelegate(_ delegate: (any JobRunnerDelegate)?) {
        self.delegate = delegate
    }

    /// Reports the host application's lifecycle state.
    ///
    /// Jobs constrained `.foregroundOnly` are only eligible while this is `.foreground`. The runner
    /// cannot determine this on its own, so the host pushes it in. Changing it re-drives the queue,
    /// the same way a reachability change does.
    public func setExecutionContext(_ newValue: ExecutionContext) async {
        guard executionContext != newValue else { return }
        executionContext = newValue
        Task { await processQueue() }
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
        let jobs = (try? await store.loadAll()) ?? []
        return QueueStatus(
            pending: jobs.filter { $0.status == .pending }.count,
            running: jobs.filter { $0.status == .running }.count,
            failed: jobs.filter { $0.status == .permanentlyFailed }.count
        )
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
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        startingGeneration = generation
        defer {
            if startingGeneration == generation { startingGeneration = nil }
        }

        await NetworkMonitor.shared.start()
        guard isRunning, lifecycleGeneration == generation else { return }
        let callbackId = await NetworkMonitor.shared.addCallback { [weak self] in
            Task { await self?.processQueue() }
        }
        guard isRunning, lifecycleGeneration == generation else {
            await NetworkMonitor.shared.removeCallback(callbackId)
            return
        }
        networkCallbackId = callbackId
        do {
            let runningJobs = hasRecoveredStore ? [] : try await store.loadAll(status: .running)
            for var job in runningJobs {
                guard isRunning, lifecycleGeneration == generation else { return }
                // A timeout stops waiting; it does not terminate the original execution.
                guard runningTasks[job.id] == nil else { continue }
                job.status = .pending
                try await store.save(job)
            }
            if lifecycleGeneration == generation { hasRecoveredStore = true }
        } catch {
            if lifecycleGeneration == generation { await stop() }
            throw error
        }
        guard isRunning, lifecycleGeneration == generation else { return }
        await emitStatus()
        Task { await processQueue() }
    }

    /// Halts job pickup, leaving in-flight jobs to run to completion.
    ///
    /// This does not cancel anything and does not wait. Use `shutdown(timeout:)` when the caller
    /// needs in-flight work actually stopped.
    public func stop() async {
        let callbackId = haltPickup()
        if let callbackId { await NetworkMonitor.shared.removeCallback(callbackId) }
    }

    /// Mutate lifecycle state before suspending, so old teardown cannot alter a later start.
    private func haltPickup() -> UUID? {
        isRunning = false
        lifecycleGeneration += 1
        let callbackId = networkCallbackId
        networkCallbackId = nil
        wakeUpTask?.cancel()
        wakeUpTask = nil
        return callbackId
    }

    /// Stops the runner, cancels every in-flight job, and waits for their teardown.
    ///
    /// Cancelled jobs return to `.pending` with their attempt count untouched, and
    /// `rollback(context:error:)` is *not* invoked: an interrupted job has not failed, it has been
    /// deferred, and it runs again on the next `start()`.
    ///
    /// Cancellation is cooperative. A job whose `run(context:)` neither awaits a cancellable
    /// operation nor checks `Task.isCancelled` will not stop, which is what `timeout` is for.
    ///
    /// - Parameter timeout: How long to wait for in-flight jobs. `nil` waits indefinitely, which is
    ///   only safe in tests. Jobs still running after the timeout remain tracked. A subsequent
    ///   `start()` will not requeue them while their original execution is alive.
    /// - Returns: `true` if every in-flight job finished before the timeout elapsed.
    @discardableResult
    public func shutdown(timeout: Duration? = .seconds(5)) async -> Bool {
        let callbackId = haltPickup()
        let tasks = runningTasks
        for entry in tasks.values { entry.task.cancel() }
        if let callbackId { await NetworkMonitor.shared.removeCallback(callbackId) }

        // Only wait for these executions, never work started by a later foreground transition.
        func hasUnfinishedTasks() -> Bool {
            tasks.contains { id, entry in runningTasks[id]?.token == entry.token }
        }

        guard !tasks.isEmpty else {
            await emitStatus()
            return true
        }

        // Awaiting from inside the actor is safe: each `await` releases isolation, which is what
        // lets a job's teardown re-enter and call `clearRunningTask`.
        let finished: Bool
        if let timeout {
            // Polled rather than raced against a sleep, because `await task.value` on a
            // `Task<Void, Never>` ignores the awaiting task's cancellation. A task group would
            // therefore still block on a job that refuses to stop, defeating the timeout outright.
            // Watching the captured execution tokens is interruptible and ignores later starts.
            let clock = ContinuousClock()
            let deadline = clock.now + timeout
            while hasUnfinishedTasks(), clock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(10)) }
                catch { break }
            }
            finished = !hasUnfinishedTasks()
        } else {
            for entry in tasks.values {
                await entry.task.value
            }
            finished = true
        }

        await emitStatus()
        return finished
    }

    @discardableResult
    public func enqueue<J: Job>(_ job: J, priority: Priority = .medium) async throws -> UUID where J.Context == Context {
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

        delegate?.jobEnqueued(JobEnqueuedEvent(
            id: serialized.id,
            jobType: J.self,
            priority: priority,
            constraints: serialized.constraints,
            jobData: String(data: jobData, encoding: .utf8) ?? ""
        ))

        await emitStatus()

        Task { await processQueue() }

        return serialized.id
    }

    private func processQueue() async {
        guard isRunning else { return }
        guard !isProcessing, startingGeneration == nil else { return }

        let generation = lifecycleGeneration
        isProcessing = true
        defer {
            isProcessing = false
            if isRunning, lifecycleGeneration != generation {
                Task { await processQueue() }
            }
        }

        let now = Date.now

        // Enqueue jobs until we're at the concurrency limit or there are no eligible jobs left
        while isRunning {
            let runningCount = (try? await store.count(status: .running)) ?? 0
            let maxConcurrent = await concurrencyPolicy.maxConcurrent()
            guard runningCount < maxConcurrent else { break }

            let pendingJobs = (try? await store.loadAll(status: .pending)) ?? []
            let eligibleJobs = await filterEligibleJobs(pendingJobs, now: now)
            let sorted = sortedByPriority(eligibleJobs)
            guard let next = sorted.first else { break }
            guard isRunning, lifecycleGeneration == generation else { break }
            guard canPickUp(next), runningTasks[next.id] == nil else { continue }

            var running = next
            running.status = .running
            try? await store.save(running)

            // `shutdown()` may have interleaved during that save. Don't start work we just promised
            // to stop, and don't leave an orphaned `.running` row behind for `start()` to find.
            guard isRunning, lifecycleGeneration == generation, canPickUp(running) else {
                running.status = .pending
                try? await store.save(running)
                await emitStatus()
                break
            }

            // The handle is registered synchronously with task creation, with no `await` in
            // between, so `shutdown()` can never observe a `.running` job it doesn't hold a handle
            // for. The task's first act is to enter the actor, which can't happen until this
            // function next suspends.
            let runningJob = running
            let runningId = running.id
            let task = Task { [self, runningJob] in
                await executeJob(runningJob)
                clearRunningTask(runningId)
            }
            runningTasks[runningId] = RunningTask(token: UUID(), job: runningJob, task: task)

            await emitStatus()
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

            if !canPickUp(job) || runningTasks[job.id] != nil {
                continue
            }

            eligible.append(job)
        }

        return eligible
    }

    private func canPickUp(_ job: SerializedJob) -> Bool {
        job.constraints.background.isSatisfied(by: executionContext)
            && (executionContext == .foreground || job.attempts == 0)
    }

    private func scheduleWakeUpIfNeeded() {
        guard isRunning else { return }

        // Replaces the previous sleeper rather than stacking another one. This runs on every
        // `processQueue()` pass, so a queue holding backoff-scheduled retries would otherwise
        // accumulate sleepers without bound.
        wakeUpTask?.cancel()
        wakeUpTask = Task { [self] in
            let pendingJobs = (try? await store.loadAll(status: .pending)) ?? []
            let now = Date.now

            let nextScheduled = pendingJobs
                .filter { canPickUp($0) }
                .compactMap { $0.scheduledAt }
                .filter { $0 > now }
                .min()

            guard let nextWake = nextScheduled else { return }

            let delay = nextWake.timeIntervalSince(now)
            guard delay > 0 else { return }

            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard isRunning else { return }
            await processQueue()
        }
    }

    private func clearRunningTask(_ id: UUID) {
        runningTasks.removeValue(forKey: id)
        if isRunning { Task { await processQueue() } }
    }

    public func beginBackgroundContinuation() {
        backgroundOutcomes = [:]
    }

    public func endBackgroundContinuation() {
        backgroundOutcomes = nil
    }

    /// Each job contributes at most one outcome to a continuation, including retryable failures.
    private func recordBackgroundOutcome(_ outcome: BackgroundOutcome, for job: SerializedJob) {
        guard job.constraints.background.requirement == .continuesInBackground,
              backgroundOutcomes != nil, backgroundOutcomes?[job.id] == nil else { return }
        backgroundOutcomes?[job.id] = outcome
    }

    public func backgroundWorkRemaining() async -> BackgroundWorkSnapshot {
        let jobs = (try? await store.loadAll()) ?? []
        let outcomes = backgroundOutcomes ?? [:]
        // Include live handles while their store mutation is in flight, and exclude outcomes
        // already recorded even if the store snapshot was read before that mutation.
        let queued = jobs.filter {
            $0.constraints.background.requirement == .continuesInBackground
                && ($0.status == .running || ($0.status == .pending && $0.attempts == 0))
        }.map(\.id)
        let live = runningTasks.values.filter {
            $0.job.constraints.background.requirement == .continuesInBackground
        }.map { $0.job.id }
        let remaining = Set(queued + live).subtracting(outcomes.keys).count
        return BackgroundWorkSnapshot(
            remaining: remaining,
            succeeded: outcomes.values.filter { $0 == .succeeded }.count,
            failed: outcomes.values.filter { $0 == .failed }.count,
            interrupted: outcomes.values.filter { $0 == .interrupted }.count
        )
    }

    /// Retained in-flight job handles. Exposed for tests asserting that handles don't leak.
    var inFlightTaskCount: Int {
        runningTasks.count
    }

    private func executeJob(_ serialized: SerializedJob) async {
        let jobDataString = String(data: serialized.jobData, encoding: .utf8) ?? ""

        // A cancel can land between task creation and first execution.
        if Task.isCancelled {
            await jobInterrupted(serialized)
            return
        }

        let job: any Job<Context>
        do {
            job = try registry.decode(serialized)
        } catch {
            await jobFailed(serialized, job: nil, error: error)
            return
        }

        let jobType = type(of: job) as Any.Type

        delegate?.jobStarted(JobStartedEvent(
            id: serialized.id,
            jobType: jobType,
            attempt: serialized.attempts + 1,
            jobData: jobDataString
        ))

        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await job.run(context: context)
        } catch {
            // Test the task flag rather than the error type. A real job surfaces
            // `URLError(.cancelled)`, or a `JobFailure` wrapping it, or its own domain error;
            // only the flag is reliable.
            if Task.isCancelled {
                await jobInterrupted(serialized)
                return
            }
            await jobFailed(serialized, job: job, error: error)
            return
        }
        let duration = clock.now - start
        let completedEvent = JobCompletedEvent(
            id: serialized.id,
            jobType: jobType,
            duration: duration,
            jobData: jobDataString
        )

        try? await store.delete(id: serialized.id)
        recordBackgroundOutcome(.succeeded, for: serialized)
        await jobStateDidChange()
        delegate?.jobCompleted(completedEvent)
    }

    private func jobStateDidChange() async {
        await emitStatus()
        Task { await processQueue() }
    }

    /// Returns a cancelled job to `.pending` without touching its attempt count.
    ///
    /// Interruption is deferral, not failure: the job will run again on the next `start()`, so
    /// `rollback` must not fire — it compensates for work that will never be retried, and firing it
    /// here would either double-compensate or visibly revert the user's optimistic state.
    private func jobInterrupted(_ serialized: SerializedJob) async {
        var updated = serialized
        updated.status = .pending
        updated.scheduledAt = nil
        try? await store.save(updated)

        recordBackgroundOutcome(.interrupted, for: serialized)

        // clearRunningTask re-drives the queue if the host has already restarted.
        await emitStatus()

        delegate?.jobInterrupted(JobInterruptedEvent(
            id: serialized.id,
            jobType: registry.resolveType(serialized.typeName) ?? Never.self as Any.Type,
            attempt: serialized.attempts,
            jobData: String(data: serialized.jobData, encoding: .utf8) ?? ""
        ))
    }

    private func jobFailed(_ serialized: SerializedJob, job: (any Job<Context>)?, error: Error) async {
        var updated = serialized
        updated.attempts += 1
        updated.lastAttemptedAt = Date.now

        let jobType = registry.resolveType(serialized.typeName) ?? Never.self as Any.Type
        let jobDataString = String(data: serialized.jobData, encoding: .utf8) ?? ""
        let errorType = String(reflecting: type(of: error))
        let errorDescription = String(describing: error)
        let underlyingError = (error as? JobFailure)?.underlyingError ?? error

        let isPermanent: Bool
        if case .permanent(_)? = error as? JobFailure {
            isPermanent = true
        } else {
            isPermanent = false
        }

        let retry = updated.constraints.retry
        let willRetry = !isPermanent && retry.map { updated.attempts < $0.maxAttempts } == true
        updated.scheduledAt = nil
        if willRetry {
            updated.status = .pending
            if let delay = retry?.delay(forAttempt: updated.attempts) {
                updated.scheduledAt = Date.now.addingTimeInterval(delay)
            }
        } else {
            updated.status = .permanentlyFailed
            await job?.rollback(context: context, error: underlyingError)
        }

        try? await store.save(updated)
        recordBackgroundOutcome(.failed, for: serialized)

        await jobStateDidChange()
        delegate?.jobFailed(JobFailedEvent(
            id: serialized.id,
            jobType: jobType,
            errorType: errorType,
            errorDescription: errorDescription,
            error: underlyingError,
            attempt: updated.attempts,
            willRetry: willRetry,
            nextRetryAt: updated.scheduledAt,
            jobData: jobDataString
        ))
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
