//
//  BackgroundConstraint.swift
//  job-runner
//
//  Created by Henry on 9/18/26.
//

import Foundation

/// Whether a job may keep running once the host application is backgrounded.
///
/// An eligibility constraint in the same sense as `ConnectivityConstraint`: the runner compares the
/// live state supplied via `JobRunner.setExecutionContext(_:)` against the job's requirement and
/// defers the jobs that don't qualify.
///
/// `.continuesInBackground` states intent, not mechanism. It tells the runner to keep dequeuing the
/// job while backgrounded, and it tells the host that this work is worth asking the OS for time on
/// behalf of. How the host does that is entirely its business.
public struct BackgroundConstraint: Codable, Sendable, Equatable {
    public enum Requirement: String, Codable, Sendable, Equatable {
        /// Deferred while backgrounded. Resumes when the host reports `.foreground` again.
        case foregroundOnly

        /// Eligible for a first attempt while backgrounded. Failed attempts retry in foreground.
        case continuesInBackground
    }

    public let requirement: Requirement

    public init(requirement: Requirement) {
        self.requirement = requirement
    }

    public static let foregroundOnly = BackgroundConstraint(requirement: .foregroundOnly)
    public static let continuesInBackground = BackgroundConstraint(requirement: .continuesInBackground)

    func isSatisfied(by context: ExecutionContext) -> Bool {
        switch requirement {
        case .foregroundOnly:
            return context == .foreground
        case .continuesInBackground:
            return true
        }
    }
}

/// The host application's current lifecycle state, as reported to the runner.
///
/// The runner cannot observe this itself: it has no UI framework to ask, and it builds for
/// platforms where the question means something different. The host pushes it in via
/// `JobRunner.setExecutionContext(_:)`.
public enum ExecutionContext: String, Codable, Sendable, Equatable {
    case foreground
    case background
}
