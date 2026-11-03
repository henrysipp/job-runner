import Foundation

/// Outcomes for the current continuation. A job contributes one outcome even if retried later.
public struct BackgroundWorkSnapshot: Sendable, Equatable {
    public let remaining: Int
    public let succeeded: Int
    public let failed: Int
    public let interrupted: Int
    /// Jobs in flight that have reported progress, so a long single job can still show movement.
    public let running: [RunningJobProgress]

    public var finished: Int { succeeded + failed }
    public var total: Int { finished + interrupted + remaining }

    /// Finished jobs plus the reported fraction of each running one.
    public var completedWork: Double {
        Double(finished) + running.reduce(0) { $0 + ($1.progress.fraction ?? 0) }
    }

    public init(
        remaining: Int,
        succeeded: Int = 0,
        failed: Int = 0,
        interrupted: Int = 0,
        running: [RunningJobProgress] = []
    ) {
        self.remaining = remaining
        self.succeeded = succeeded
        self.failed = failed
        self.interrupted = interrupted
        self.running = running
    }

    public static let empty = BackgroundWorkSnapshot(remaining: 0)
}

public struct RunningJobProgress: Sendable, Equatable {
    public let id: UUID
    public let progress: JobProgress

    public init(id: UUID, progress: JobProgress) {
        self.id = id
        self.progress = progress
    }
}

/// The runner operations needed by the platform-independent continuation coordinator.
public protocol BackgroundContinuationRunning: Actor {
    func setExecutionContext(_ newValue: ExecutionContext) async
    func start() async throws
    @discardableResult
    func shutdown(timeout: Duration?) async -> Bool
    func beginBackgroundContinuation() async
    func endBackgroundContinuation() async
    func backgroundWorkRemaining() async -> BackgroundWorkSnapshot
}

extension JobRunner: BackgroundContinuationRunning {}
