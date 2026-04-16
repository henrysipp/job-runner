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
        await delegate.waitForFailedCount(1)
        await waitUntilIdle(runner)

        let events = delegate.failed
        let status = await runner.currentStatus()

        #expect(events.count == 1)
        #expect(events[0].errorType.contains("NonSendableJobError"))
        #expect(!events[0].errorDescription.isEmpty)
        #expect(status.failed == 1)
    }
}
