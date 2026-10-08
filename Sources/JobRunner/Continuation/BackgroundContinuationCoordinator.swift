import Foundation

/// The synchronous expiration callback and asynchronous drain loop complete the task exactly once.
final class DrainState: @unchecked Sendable {
    private let lock = NSLock()
    private var expiring = false
    private var completed = false

    var isExpiring: Bool { lock.withLock { expiring } }

    func claimExpiration() -> Bool {
        lock.withLock {
            guard !completed else { return false }
            expiring = true
            completed = true
            return true
        }
    }

    func claimCompletion() -> Bool {
        lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
    }
}

/// Continues user-initiated work in the background and reports successes and failures separately.
public actor BackgroundContinuationCoordinator: JobRunnerDelegate {
    private nonisolated let scheduler: any ContinuationScheduler
    private nonisolated let runner: @Sendable () -> (any BackgroundContinuationRunning)?
    private nonisolated let configuration: ContinuationConfiguration
    private nonisolated let observer: any BackgroundContinuationObserver

    private struct Session {
        let id = UUID()
        let runner: any BackgroundContinuationRunning
    }

    private var isForeground = true
    private var lifecycleRevision = 0
    private var activeSession: Session?
    private var teardown: Task<Void, Never>?

    /// Construct once before the host finishes launching, so registration happens in time.
    public init(
        scheduler: any ContinuationScheduler,
        runner: @escaping @Sendable () -> (any BackgroundContinuationRunning)?,
        configuration: ContinuationConfiguration,
        observer: any BackgroundContinuationObserver = NoOpContinuationObserver()
    ) {
        self.scheduler = scheduler
        self.runner = runner
        self.configuration = configuration
        self.observer = observer
        registerLaunchHandler()
    }

    private nonisolated func registerLaunchHandler() {
        let registered = scheduler.register(identifier: configuration.identifier) { [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { await self.drain(task: task) }
        }
        if !registered {
            observer.continuationRegistrationFailed(identifier: configuration.identifier)
        }
    }

    public func appDidEnterForeground() async {
        isForeground = true
        lifecycleRevision += 1
        let revision = lifecycleRevision
        // Expiration may already have started shutdown. Never race that shutdown with restart.
        await teardown?.value
        guard isForeground, revision == lifecycleRevision, let runner = runner() else { return }
        await runner.setExecutionContext(.foreground)
        guard isForeground, revision == lifecycleRevision else { return }
        try? await runner.start()
    }

    public func appDidEnterBackground() async {
        isForeground = false
        lifecycleRevision += 1
        await runner()?.setExecutionContext(.background)
    }

    public nonisolated func jobEnqueued(_ event: JobEnqueuedEvent) {
        guard event.traits.background.requirement == .continuesInBackground else { return }
        Task { await self.requestContinuation() }
    }

    public func requestContinuation() async {
        guard configuration.isEnabled() else {
            observer.continuationSkipped(reason: .disabled)
            return
        }
        guard isForeground else {
            observer.continuationSkipped(reason: .backgrounded)
            return
        }
        guard activeSession == nil else {
            observer.continuationSkipped(reason: .alreadyActive)
            return
        }
        guard let runner = runner() else {
            observer.continuationSkipped(reason: .runnerUnavailable)
            return
        }

        let session = Session(runner: runner)
        activeSession = session
        await runner.beginBackgroundContinuation()
        guard isForeground else {
            await finish(session)
            observer.continuationSkipped(reason: .backgrounded)
            return
        }
        do {
            let snapshot = await runner.backgroundWorkRemaining()
            try await scheduler.submit(
                identifier: configuration.identifier,
                title: configuration.title,
                subtitle: configuration.subtitle(snapshot)
            )
            observer.continuationSubmitted(identifier: configuration.identifier)
        } catch {
            await finish(session)
            observer.continuationSubmissionFailed(identifier: configuration.identifier, error: error)
        }
    }

    /// Stops background work once per session. A late expiration cannot stop resumed foreground work.
    private func stopBackgroundWork(for session: Session) async {
        guard activeSession?.id == session.id else { return }
        if let teardown {
            await teardown.value
            return
        }
        guard !isForeground else { return }
        let timeout = configuration.shutdownTimeout
        let task = Task { _ = await session.runner.shutdown(timeout: timeout) }
        teardown = task
        await task.value
    }

    private func finish(_ session: Session) async {
        guard activeSession?.id == session.id else { return }
        await teardown?.value
        await session.runner.endBackgroundContinuation()
        activeSession = nil
        teardown = nil
    }

    // Internal so tests can drive a launch without a platform scheduler.
    func drain(task: some ContinuationTask) async {
        let session: Session
        if let activeSession {
            session = activeSession
        } else if let runner = runner() {
            session = Session(runner: runner)
            activeSession = session
            await runner.beginBackgroundContinuation()
        } else {
            task.setTaskCompleted(success: false)
            return
        }

        let state = DrainState()
        let observer = observer
        observer.continuationStarted()
        task.setExpirationHandler { [weak self] in
            guard state.claimExpiration() else { return }
            task.setTaskCompleted(success: false)
            observer.continuationCompleted(outcome: .expired)
            Task { await self?.stopBackgroundWork(for: session) }
        }

        let outcome = await pumpProgress(of: task, runner: session.runner, state: state)
        if state.isExpiring || outcome == .budgetExceeded || outcome == .interrupted {
            await stopBackgroundWork(for: session)
        }
        if state.claimCompletion() {
            task.setTaskCompleted(success: outcome == .drained)
            observer.continuationCompleted(outcome: outcome)
        }
        task.setExpirationHandler {}
        await finish(session)
    }

    private func pumpProgress(
        of task: some ContinuationTask,
        runner: any BackgroundContinuationRunning,
        state: DrainState
    ) async -> ContinuationOutcome {
        let clock = ContinuousClock()
        let deadline = clock.now + configuration.maxDuration
        var lastProgress: BackgroundWorkSnapshot?
        while !state.isExpiring {
            let snapshot = await runner.backgroundWorkRemaining()
            guard !state.isExpiring else { return .expired }
            task.progress.totalUnitCount = Int64(snapshot.total)
            task.progress.completedUnitCount = Int64(snapshot.finished)
            if snapshot != lastProgress {
                task.updateTitle(configuration.title, subtitle: configuration.subtitle(snapshot))
                observer.continuationProgressed(snapshot)
                lastProgress = snapshot
            }
            if snapshot.remaining == 0 {
                if snapshot.interrupted > 0 { return .interrupted }
                return snapshot.failed > 0 ? .failed : .drained
            }
            let budgetLeft = deadline - clock.now
            if budgetLeft <= .zero { return .budgetExceeded }
            do {
                try await Task.sleep(for: min(configuration.pollInterval, budgetLeft))
            } catch {
                return .interrupted
            }
        }
        return .expired
    }
}

public struct NoOpContinuationObserver: BackgroundContinuationObserver {
    public init() {}
}
