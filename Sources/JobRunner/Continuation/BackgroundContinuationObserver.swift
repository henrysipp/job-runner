//
//  BackgroundContinuationObserver.swift
//  job-runner
//
//  Created by Henry on 9/21/26.
//

import Foundation

/// Why a submission attempt did nothing.
public enum ContinuationSkipReason: Sendable, Equatable {
    /// `ContinuationConfiguration.isEnabled` returned false.
    case disabled
    /// The host is backgrounded; the platform only accepts submissions from the foreground.
    case backgrounded
    /// A continuation is already outstanding.
    case alreadyActive
    /// The runner provider returned nil.
    case runnerUnavailable
}

/// How a continuation ended.
public enum ContinuationOutcome: Sendable, Equatable {
    /// Every `.continuesInBackground` job finished.
    case drained
    /// At least one job failed, including failures deferred for a foreground retry.
    case failed
    /// Work was interrupted rather than completed.
    case interrupted
    /// `ContinuationConfiguration.maxDuration` elapsed with work still queued.
    case budgetExceeded
    /// The platform expired the continuation, or the person cancelled it.
    case expired
}

/// Observability for the coordinator. All methods default to no-ops, so a host implements only the
/// events it logs.
public protocol BackgroundContinuationObserver: Sendable {
    func continuationRegistrationFailed(identifier: String)
    func continuationSkipped(reason: ContinuationSkipReason)
    func continuationSubmitted(identifier: String)
    func continuationSubmissionFailed(identifier: String, error: any Error)
    func continuationStarted()
    func continuationProgressed(_ progress: BackgroundWorkSnapshot)
    func continuationCompleted(outcome: ContinuationOutcome)
}

public extension BackgroundContinuationObserver {
    func continuationRegistrationFailed(identifier _: String) {}
    func continuationSkipped(reason _: ContinuationSkipReason) {}
    func continuationSubmitted(identifier _: String) {}
    func continuationSubmissionFailed(identifier _: String, error _: any Error) {}
    func continuationStarted() {}
    func continuationProgressed(_: BackgroundWorkSnapshot) {}
    func continuationCompleted(outcome _: ContinuationOutcome) {}
}
