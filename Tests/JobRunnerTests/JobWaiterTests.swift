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

        let results = try await withThrowingTaskGroup(of: Result<Void, Error>.self) { group in
            group.addTask {
                await waiter.wait(for: id, timeout: .seconds(1))
            }
            group.addTask {
                await waiter.wait(for: id, timeout: .seconds(1))
            }

            var results: [Result<Void, Error>] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        for result in results {
            try result.get()
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

        try (await waiter.wait(for: id, timeout: .seconds(1))).get()
        try (await waiter.wait(for: id, timeout: .seconds(1))).get()

        await waitUntilIdle(runner)
        let didExecute = await TestJobTracker.shared.didExecute(jobKey)
        #expect(didExecute)
    }

    @Test func failedJobReturnsFailureResult() async throws {
        try await prepareTest()

        let runner = SimpleJobRunner(context: (), maxConcurrent: 1)
        let waiter = JobWaiter()

        await runner.setDelegate(waiter)
        try await runner.register(NoRetryJob.self)
        try await runner.start()

        let jobKey = "failed-result-\(UUID())"
        let id = try await runner.enqueue(NoRetryJob(key: jobKey), priority: .medium)

        let result = await waiter.wait(for: id, timeout: .seconds(1))

        switch result {
        case .success:
            Issue.record("Expected failed job to return a failure result")
        case .failure(let error):
            let waiterError = try #require(error as? JobWaiterError)
            #expect(waiterError.errorType.contains("TestError"))
            #expect(waiterError.attempts == 1)
        }
    }
}
