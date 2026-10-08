//
//  BackgroundPolicy.swift
//  job-runner
//
//  Created by Henry on 9/18/26.
//

import Foundation

/// Whether a job may keep running once the host application is backgrounded.
///
/// The runner compares the live state supplied via `JobRunner.setExecutionContext(_:)` against
/// the job's requirement and defers the jobs that don't qualify. This stays a policy rather than
/// a `Constraint` because the runner also reads it for the first-attempt-only rule while
/// backgrounded and for continuation accounting.
///
/// `.continuesInBackground` states intent, not mechanism. It tells the runner to keep dequeuing the
/// job while backgrounded, and it tells the host that this work is worth asking the OS for time on
/// behalf of. How the host does that is entirely its business.
public struct BackgroundPolicy: JobTrait, Equatable {
    public static let key: TraitKey = "background"

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

    public static let foregroundOnly = BackgroundPolicy(requirement: .foregroundOnly)
    public static let continuesInBackground = BackgroundPolicy(requirement: .continuesInBackground)

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
