//
//  JobRunnerDelegate.swift
//  job-runner
//
//  Created by Henry on 4/1/26.
//

import Foundation

public protocol JobRunnerDelegate: Sendable {
    func jobEnqueued(_ event: JobEnqueuedEvent)
    func jobStarted(_ event: JobStartedEvent)
    func jobCompleted(_ event: JobCompletedEvent)
    func jobFailed(_ event: JobFailedEvent)
}

extension JobRunnerDelegate {
    public func jobEnqueued(_ event: JobEnqueuedEvent) {}
    public func jobStarted(_ event: JobStartedEvent) {}
    public func jobCompleted(_ event: JobCompletedEvent) {}
    public func jobFailed(_ event: JobFailedEvent) {}
}
