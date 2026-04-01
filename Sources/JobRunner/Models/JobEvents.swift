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
    public let error: any Error & Sendable
    public let attempt: Int
    public let willRetry: Bool
    public let nextRetryAt: Date?
    public let jobData: String
}
