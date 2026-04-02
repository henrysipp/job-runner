//
//  JobRunnerDelegateBehaviorTests.swift
//  job-runnerTests
//
//  Created by Henry on 4/2/26.
//

import Foundation
@testable import JobRunner
import Testing

private final class NonSendableJobError: Error {}

private struct NonSendableErrorJob: Job {
    typealias Context = Void
    let key: String

    var constraints: JobConstraints {
        JobConstraints(retry: nil)
    }

    func run(context _: Void) async throws {
        throw NonSendableJobError()
    }
}

private actor DelegateTimingTracker {
    static let shared = DelegateTimingTracker()

    private var startTimes: [String: Date] = [:]

    func recordStart(for key: String) {
        startTimes[key] = Date.now
    }

    func startTime(for key: String) -> Date? {
        startTimes[key]
    }

    func reset() {
        startTimes.removeAll()
    }
}

private struct DelegateTimingJob: Job {
    typealias Context = Void
    let key: String
    let duration: Duration

    func run(context _: Void) async throws {
        await DelegateTimingTracker.shared.recordStart(for: key)
        try await Task.sleep(for: duration)
    }
}

private actor SlowCompletionDelegate: JobRunnerDelegate {
    let delay: Duration
    private(set) var completedCount = 0

    init(delay: Duration) {
        self.delay = delay
    }

    func jobEnqueued(_ event: JobEnqueuedEvent) async {}

    func jobStarted(_ event: JobStartedEvent) async {}

    func jobCompleted(_ event: JobCompletedEvent) async {
        completedCount += 1
        try? await Task.sleep(for: delay)
    }

    func jobFailed(_ event: JobFailedEvent) async {}
}

@Suite(.serialized)
struct JobRunnerDelegateBehaviorTests {
    @Test func nonSendableErrorIsReportedAsSnapshot() async throws {
        try await waitForBackgroundJobs()

        let delegate = RecordingDelegate()
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1)
        await runner.setDelegate(delegate)
        try await runner.register(NonSendableErrorJob.self)
        try await runner.start()

        try await runner.enqueue(NonSendableErrorJob(key: "non-sendable"))
        try await Task.sleep(for: .milliseconds(200))

        let events = await delegate.failed
        let status = await runner.currentStatus()

        #expect(events.count == 1)
        #expect(events[0].errorType.contains("NonSendableJobError"))
        #expect(!events[0].errorDescription.isEmpty)
        #expect(status.failed == 1)
    }

    @Test func slowCompletionDelegateDoesNotBlockNextJob() async throws {
        await DelegateTimingTracker.shared.reset()

        let delegate = SlowCompletionDelegate(delay: .milliseconds(300))
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1)
        await runner.setDelegate(delegate)
        try await runner.register(DelegateTimingJob.self)
        try await runner.start()

        let firstKey = "first-\(UUID())"
        let secondKey = "second-\(UUID())"

        try await runner.enqueue(DelegateTimingJob(key: firstKey, duration: .milliseconds(50)))
        try await runner.enqueue(DelegateTimingJob(key: secondKey, duration: .milliseconds(50)))
        try await Task.sleep(for: .milliseconds(500))

        let firstStartedAt = await DelegateTimingTracker.shared.startTime(for: firstKey)
        let secondStartedAt = await DelegateTimingTracker.shared.startTime(for: secondKey)
        let completionCount = await delegate.completedCount
        let unwrappedFirstStartedAt = try #require(firstStartedAt)
        let unwrappedSecondStartedAt = try #require(secondStartedAt)

        #expect(unwrappedSecondStartedAt.timeIntervalSince(unwrappedFirstStartedAt) < 0.25)
        #expect(completionCount == 2)
    }
}
