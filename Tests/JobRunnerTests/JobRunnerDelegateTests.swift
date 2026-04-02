//
//  JobRunnerDelegateTests.swift
//  job-runnerTests
//
//  Created by Henry on 4/1/26.
//

import Foundation
@testable import JobRunner
import Testing

// MARK: - Test Delegate

actor RecordingDelegate: JobRunnerDelegate {
    var enqueued: [JobEnqueuedEvent] = []
    var started: [JobStartedEvent] = []
    var completed: [JobCompletedEvent] = []
    var failed: [JobFailedEvent] = []

    func jobEnqueued(_ event: JobEnqueuedEvent) async {
        enqueued.append(event)
    }

    func jobStarted(_ event: JobStartedEvent) async {
        started.append(event)
    }

    func jobCompleted(_ event: JobCompletedEvent) async {
        completed.append(event)
    }

    func jobFailed(_ event: JobFailedEvent) async {
        failed.append(event)
    }

    func reset() {
        enqueued.removeAll()
        started.removeAll()
        completed.removeAll()
        failed.removeAll()
    }
}

// MARK: - Job Types

private struct EventTestJob: Job {
    typealias Context = Void
    let key: String

    func run(context _: Void) async throws {}
}

private struct EventFailingJob: Job {
    typealias Context = Void
    let key: String
    var constraints: JobConstraints {
        JobConstraints(retry: RetryConstraint(maxAttempts: 3, strategy: .immediate))
    }

    func run(context _: Void) async throws {
        throw JobFailure.transient(TestError.intentionalFailure)
    }
}

private struct EventPermanentFailJob: Job {
    typealias Context = Void
    let key: String

    func run(context _: Void) async throws {
        throw JobFailure.permanent(TestError.intentionalFailure)
    }
}

private struct EventNoRetryFailJob: Job {
    typealias Context = Void
    let key: String
    var constraints: JobConstraints {
        JobConstraints(retry: nil)
    }

    func run(context _: Void) async throws {
        throw JobFailure.transient(TestError.intentionalFailure)
    }
}

// MARK: - Tests

@Suite(.serialized)
struct JobRunnerDelegateTests {
    @Test func enqueuedEventFires() async throws {
        try await waitForBackgroundJobs()

        let handler = RecordingDelegate()
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1)
        await runner.setDelegate(handler)
        try await runner.register(EventTestJob.self)
        try await runner.start()

        try await runner.enqueue(EventTestJob(key: "enqueue-test"), priority: .high)
        try await Task.sleep(for: .milliseconds(200))

        let events = await handler.enqueued
        #expect(events.count == 1)
        #expect(events[0].jobType is EventTestJob.Type)
        #expect(events[0].priority == .high)
        #expect(!events[0].jobData.isEmpty)
    }

    @Test func startedEventFires() async throws {
        try await waitForBackgroundJobs()

        let handler = RecordingDelegate()
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1)
        await runner.setDelegate(handler)
        try await runner.register(EventTestJob.self)
        try await runner.start()

        try await runner.enqueue(EventTestJob(key: "start-test"))
        try await Task.sleep(for: .milliseconds(200))

        let events = await handler.started
        #expect(events.count == 1)
        #expect(events[0].jobType is EventTestJob.Type)
        #expect(events[0].attempt == 1)
    }

    @Test func completedEventFires() async throws {
        try await waitForBackgroundJobs()

        let handler = RecordingDelegate()
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1)
        await runner.setDelegate(handler)
        try await runner.register(EventTestJob.self)
        try await runner.start()

        try await runner.enqueue(EventTestJob(key: "complete-test"))
        try await Task.sleep(for: .milliseconds(200))

        let events = await handler.completed
        #expect(events.count == 1)
        #expect(events[0].jobType is EventTestJob.Type)
        #expect(events[0].duration > .zero)
    }

    @Test func failedEventWithRetry() async throws {
        try await waitForBackgroundJobs()

        let handler = RecordingDelegate()
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1)
        await runner.setDelegate(handler)
        try await runner.register(EventFailingJob.self)
        try await runner.start()

        try await runner.enqueue(EventFailingJob(key: "retry-test"))
        try await Task.sleep(for: .milliseconds(500))

        let events = await handler.failed
        #expect(events.count == 3)

        // First two attempts should indicate willRetry
        #expect(events[0].willRetry == true)
        #expect(events[0].attempt == 1)
        #expect(!events[0].errorType.isEmpty)
        #expect(!events[0].errorDescription.isEmpty)
        #expect(events[1].willRetry == true)
        #expect(events[1].attempt == 2)

        // Final attempt should not retry
        #expect(events[2].willRetry == false)
        #expect(events[2].attempt == 3)
    }

    @Test func failedEventPermanentFailure() async throws {
        try await waitForBackgroundJobs()

        let handler = RecordingDelegate()
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1)
        await runner.setDelegate(handler)
        try await runner.register(EventPermanentFailJob.self)
        try await runner.start()

        try await runner.enqueue(EventPermanentFailJob(key: "permanent-test"))
        try await Task.sleep(for: .milliseconds(200))

        let events = await handler.failed
        #expect(events.count == 1)
        #expect(events[0].willRetry == false)
        #expect(events[0].attempt == 1)
        #expect(events[0].jobType is EventPermanentFailJob.Type)
    }

    @Test func failedEventNoRetryConstraint() async throws {
        try await waitForBackgroundJobs()

        let handler = RecordingDelegate()
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1)
        await runner.setDelegate(handler)
        try await runner.register(EventNoRetryFailJob.self)
        try await runner.start()

        try await runner.enqueue(EventNoRetryFailJob(key: "no-retry-test"))
        try await Task.sleep(for: .milliseconds(200))

        let events = await handler.failed
        #expect(events.count == 1)
        #expect(events[0].willRetry == false)
    }

    @Test func jobDataContainsEncodedProperties() async throws {
        try await waitForBackgroundJobs()

        let handler = RecordingDelegate()
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1)
        await runner.setDelegate(handler)
        try await runner.register(EventTestJob.self)
        try await runner.start()

        try await runner.enqueue(EventTestJob(key: "json-test"))
        try await Task.sleep(for: .milliseconds(200))

        let event = await handler.enqueued.first
        #expect(event != nil)
        #expect(event!.jobData.contains("json-test"))
    }

    @Test func noHandlerDoesNotCrash() async throws {
        try await waitForBackgroundJobs()

        let runner = SimpleJobRunner(context: (), maxConcurrent: 1)
        try await runner.register(EventTestJob.self)
        try await runner.start()

        try await runner.enqueue(EventTestJob(key: "no-handler"))
        try await Task.sleep(for: .milliseconds(200))

        let status = await runner.currentStatus()
        #expect(status.isIdle)
    }

    @Test func eventOrderIsCorrect() async throws {
        try await waitForBackgroundJobs()

        let handler = RecordingDelegate()
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1)
        await runner.setDelegate(handler)
        try await runner.register(EventTestJob.self)
        try await runner.start()

        try await runner.enqueue(EventTestJob(key: "order-test"))
        try await Task.sleep(for: .milliseconds(200))

        let enqueuedCount = await handler.enqueued.count
        let startedCount = await handler.started.count
        let completedCount = await handler.completed.count
        let failedCount = await handler.failed.count

        #expect(enqueuedCount == 1)
        #expect(startedCount == 1)
        #expect(completedCount == 1)
        #expect(failedCount == 0)
    }
}
