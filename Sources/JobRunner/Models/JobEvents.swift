//
//  JobEvents.swift
//  job-runner
//
//  Created by Henry on 4/1/26.
//

import Foundation

public struct JobEnqueuedEvent: Sendable {
    public let id: UUID
    public let jobType: Any.Type
    public let priority: Priority
    public let constraints: JobConstraints
    public let jobData: String
}

public struct JobStartedEvent: Sendable {
    public let id: UUID
    public let jobType: Any.Type
    public let attempt: Int
    public let jobData: String
}

public struct JobCompletedEvent: Sendable {
    public let id: UUID
    public let jobType: Any.Type
    public let duration: Duration
    public let jobData: String
}

public struct JobFailedEvent: Sendable {
    public let id: UUID
    public let jobType: Any.Type
    public let errorType: String
    public let errorDescription: String
    public let attempt: Int
    public let willRetry: Bool
    public let nextRetryAt: Date?
    public let jobData: String
}

/// A job that was cancelled mid-flight by `shutdown(timeout:)` and returned to `.pending`.
///
/// Distinct from `JobFailedEvent`: the job has not failed, its attempt count is untouched, and it
/// will run again on the next `start()`.
public struct JobInterruptedEvent: Sendable {
    public let id: UUID
    public let jobType: Any.Type
    public let attempt: Int
    public let jobData: String
}
