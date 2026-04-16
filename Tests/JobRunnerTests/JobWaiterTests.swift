//
//  JobWaiterTests.swift
//  job-runnerTests
//

import Foundation
@testable import JobRunner
import Testing

@Suite(.serialized)
struct JobWaiterTests {
    @Test func multipleTasksCanWaitForSameJobID() async throws {
        try await prepareTest()

        let runner = SimpleJobRunner(context: (), maxConcurrent: 1)
        let waiter = JobWaiter()

        await runner.setDelegate(waiter)
        try await runner.register(SlowJob.self)
        try await runner.start()

        let jobKey = "shared-wait-\(UUID())"
        let id = try await runner.enqueue(
            SlowJob(key: jobKey, duration: .milliseconds(150)),
            priority: .medium
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await waiter.wait(for: id, timeout: .seconds(1))
            }
            group.addTask {
                try await waiter.wait(for: id, timeout: .seconds(1))
            }

            try await group.waitForAll()
        }

        await waitUntilIdle(runner)
        let executionOrder = await TestJobTracker.shared.getExecutionOrder()
        #expect(executionOrder.contains(jobKey))
    }

    @Test func completedJobCanBeWaitedOnMoreThanOnce() async throws {
        try await prepareTest()

        let runner = SimpleJobRunner(context: (), maxConcurrent: 1)
        let waiter = JobWaiter()

        await runner.setDelegate(waiter)
        try await runner.register(SuccessJob.self)
        try await runner.start()

        let jobKey = "repeat-wait-\(UUID())"
        let id = try await runner.enqueue(SuccessJob(key: jobKey), priority: .medium)

        try await waiter.wait(for: id, timeout: .seconds(1))
        try await waiter.wait(for: id, timeout: .seconds(1))

        await waitUntilIdle(runner)
        let didExecute = await TestJobTracker.shared.didExecute(jobKey)
        #expect(didExecute)
    }
}
