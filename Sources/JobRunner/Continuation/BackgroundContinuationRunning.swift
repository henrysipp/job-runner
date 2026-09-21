import Foundation

/// Outcomes for the current continuation. A job contributes one outcome even if retried later.
public struct BackgroundWorkSnapshot: Sendable, Equatable {
    public let remaining: Int
    public let succeeded: Int
    public let failed: Int
    public let interrupted: Int

    public var finished: Int { succeeded + failed }
    public var total: Int { finished + interrupted + remaining }

    public init(remaining: Int, succeeded: Int = 0, failed: Int = 0, interrupted: Int = 0) {
        self.remaining = remaining
        self.succeeded = succeeded
        self.failed = failed
        self.interrupted = interrupted
    }

    public static let empty = BackgroundWorkSnapshot(remaining: 0)
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
