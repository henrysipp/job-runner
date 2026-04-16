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

final class RecordingDelegate: JobRunnerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _enqueued: [JobEnqueuedEvent] = []
    private var _started: [JobStartedEvent] = []
    private var _completed: [JobCompletedEvent] = []
    private var _failed: [JobFailedEvent] = []
    private var enqueuedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var startedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var completedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var failedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var enqueued: [JobEnqueuedEvent] { lock.withLock { _enqueued } }
    var started: [JobStartedEvent] { lock.withLock { _started } }
    var completed: [JobCompletedEvent] { lock.withLock { _completed } }
    var failed: [JobFailedEvent] { lock.withLock { _failed } }

    func jobEnqueued(_ event: JobEnqueuedEvent) {
        lock.withLock {
            _enqueued.append(event)
            resumeSatisfiedWaiters(&enqueuedWaiters, currentCount: _enqueued.count)
        }
    }

    func jobStarted(_ event: JobStartedEvent) {
        lock.withLock {
            _started.append(event)
            resumeSatisfiedWaiters(&startedWaiters, currentCount: _started.count)
        }
    }

    func jobCompleted(_ event: JobCompletedEvent) {
        lock.withLock {
            _completed.append(event)
            resumeSatisfiedWaiters(&completedWaiters, currentCount: _completed.count)
        }
    }

    func jobFailed(_ event: JobFailedEvent) {
        lock.withLock {
            _failed.append(event)
            resumeSatisfiedWaiters(&failedWaiters, currentCount: _failed.count)
        }
    }

    func reset() {
        lock.withLock {
            _enqueued.removeAll()
            _started.removeAll()
            _completed.removeAll()
            _failed.removeAll()
        }
    }

    func waitForEnqueuedCount(_ count: Int) async {
        await waitForCount(
            count,
            currentCount: { _enqueued.count },
            waiters: \.enqueuedWaiters
        )
    }

    func waitForStartedCount(_ count: Int) async {
        await waitForCount(
            count,
            currentCount: { _started.count },
            waiters: \.startedWaiters
        )
    }

    func waitForCompletedCount(_ count: Int) async {
        await waitForCount(
            count,
            currentCount: { _completed.count },
            waiters: \.completedWaiters
        )
    }

    func waitForFailedCount(_ count: Int) async {
        await waitForCount(
            count,
            currentCount: { _failed.count },
            waiters: \.failedWaiters
        )
    }

    private func waitForCount(
        _ count: Int,
        currentCount: () -> Int,
        waiters: ReferenceWritableKeyPath<RecordingDelegate, [(Int, CheckedContinuation<Void, Never>)]>
    ) async {
        let shouldWait = lock.withLock { currentCount() < count }
        guard shouldWait else { return }

        await withCheckedContinuation { continuation in
            lock.withLock {
                if currentCount() >= count {
                    continuation.resume()
                } else {
                    self[keyPath: waiters].append((count, continuation))
                }
            }
        }
    }

    private func resumeSatisfiedWaiters(
        _ waiters: inout [(Int, CheckedContinuation<Void, Never>)],
        currentCount: Int
    ) {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []

        for (targetCount, continuation) in waiters {
            if currentCount >= targetCount {
                continuation.resume()
            } else {
                remaining.append((targetCount, continuation))
            }
        }

        waiters = remaining
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
        await handler.waitForEnqueuedCount(1)

        let events = handler.enqueued
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
        await handler.waitForStartedCount(1)

        let events = handler.started
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
        await handler.waitForCompletedCount(1)

        let events = handler.completed
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
        await handler.waitForFailedCount(3)

        let events = handler.failed
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
        await handler.waitForFailedCount(1)

        let events = handler.failed
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
        await handler.waitForFailedCount(1)

        let events = handler.failed
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
        await handler.waitForEnqueuedCount(1)

        let event = handler.enqueued.first
        #expect(event != nil)
        #expect(event!.jobData.contains("json-test"))
    }

    @Test func noHandlerDoesNotCrash() async throws {
        try await waitForBackgroundJobs()

        let runner = SimpleJobRunner(context: (), maxConcurrent: 1)
        try await runner.register(EventTestJob.self)
        try await runner.start()

        try await runner.enqueue(EventTestJob(key: "no-handler"))
        await waitUntilIdle(runner)

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
        await handler.waitForCompletedCount(1)

        let enqueuedCount = handler.enqueued.count
        let startedCount = handler.started.count
        let completedCount = handler.completed.count
        let failedCount = handler.failed.count

        #expect(enqueuedCount == 1)
        #expect(startedCount == 1)
        #expect(completedCount == 1)
        #expect(failedCount == 0)
    }
}
