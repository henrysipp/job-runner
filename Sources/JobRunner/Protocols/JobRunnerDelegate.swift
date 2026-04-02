//
//  JobRunnerDelegate.swift
//  job-runner
//
//  Created by Henry on 4/1/26.
//

import Foundation

public protocol JobRunnerDelegate: Sendable {
    func jobEnqueued(_ event: JobEnqueuedEvent) async
    func jobStarted(_ event: JobStartedEvent) async
    func jobCompleted(_ event: JobCompletedEvent) async
    func jobFailed(_ event: JobFailedEvent) async
}

extension JobRunnerDelegate {
    public func jobEnqueued(_ event: JobEnqueuedEvent) async {}
    public func jobStarted(_ event: JobStartedEvent) async {}
    public func jobCompleted(_ event: JobCompletedEvent) async {}
    public func jobFailed(_ event: JobFailedEvent) async {}
}
