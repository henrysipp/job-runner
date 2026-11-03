//
//  JobProgress.swift
//  job-runner
//

import Foundation

/// How far a running job has got, as reported by the job itself.
///
/// The runner only reads `completed` and `total`. `description` belongs to the job: it is shown to
/// people as-is and may hold free text, so never log it.
public struct JobProgress: Sendable, Equatable {
    public var completed: Int64
    /// `nil` when the job can't yet say how much work there is.
    public var total: Int64?
    public var description: String?

    public init(completed: Int64, total: Int64?, description: String? = nil) {
        self.completed = completed
        self.total = total
        self.description = description
    }

    /// 0...1, or `nil` while the total is unknown.
    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

/// A job that reports progress while it runs.
///
/// Implement `run(context:progress:)` instead of `run(context:)`. Jobs that don't report progress
/// conform to `Job` alone and are unaffected.
public protocol ProgressReportingJob<Context>: Job {
    // Restated so `Context` is inferred from this requirement rather than the default `run(context:)`.
    associatedtype Context
    nonisolated func run(context: Context, progress: JobProgressReporter) async throws
}

public extension ProgressReportingJob {
    nonisolated func run(context: Context) async throws {
        try await run(context: context, progress: .discarding)
    }
}

/// Hands a running job's progress to its runner.
///
/// `report` is synchronous and safe from any thread, so it can be called straight from a delegate
/// callback. Reports after the job has finished are dropped.
public struct JobProgressReporter: Sendable {
    let box: ProgressBox

    /// A reporter that hands every report to `onReport`, for running a job outside a runner, such
    /// as in a test.
    public init(onReport: @escaping @Sendable (JobProgress) -> Void) {
        self.init(box: ProgressBox(minimumEventInterval: .zero, onEvent: onReport))
    }

    init(box: ProgressBox) {
        self.box = box
    }

    /// A reporter that drops everything, for running a job outside a runner.
    public static var discarding: JobProgressReporter {
        let box = ProgressBox(minimumEventInterval: .zero) { _ in }
        box.close()
        return JobProgressReporter(box: box)
    }

    public func report(_ progress: JobProgress) {
        box.report(progress)
    }

    public func report(completed: Int64, total: Int64?, description: String? = nil) {
        report(JobProgress(completed: completed, total: total, description: description))
    }
}

/// Latest progress for one running job.
///
/// The runner reads `latest` when polled; `onEvent` fires at most every `minimumEventInterval`,
/// or sooner when the description changes so a new stage isn't held back.
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumEventInterval: Duration
    private let onEvent: @Sendable (JobProgress) -> Void
    private let clock = ContinuousClock()
    private var progress: JobProgress?
    private var lastEvent: (at: ContinuousClock.Instant, description: String?)?
    private var isClosed = false

    init(minimumEventInterval: Duration, onEvent: @escaping @Sendable (JobProgress) -> Void) {
        self.minimumEventInterval = minimumEventInterval
        self.onEvent = onEvent
    }

    var latest: JobProgress? {
        lock.withLock { progress }
    }

    func report(_ new: JobProgress) {
        let shouldEmit: Bool = lock.withLock {
            guard !isClosed else { return false }
            progress = new
            let now = clock.now
            if let lastEvent, lastEvent.description == new.description,
               now - lastEvent.at < minimumEventInterval {
                return false
            }
            lastEvent = (now, new.description)
            return true
        }
        if shouldEmit { onEvent(new) }
    }

    func close() {
        lock.withLock { isClosed = true }
    }
}
