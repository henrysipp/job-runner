//
//  ComplexJobRunnerTests.swift
//  job-runnerTests
//
//  Created by Henry on 2/3/26.
//

import Foundation
@testable import JobRunner
import Testing

// MARK: - Test Context

struct TestContext: Sendable {
    let counter: TestCounter
}

actor TestCounter {
    private(set) var count: Int = 0
    private(set) var messages: [String] = []

    func increment() {
        count += 1
    }

    func record(_ message: String) {
        messages.append(message)
    }

    func getCount() -> Int {
        count
    }

    func getMessages() -> [String] {
        messages
    }
}

// MARK: - Test Jobs with Context

struct CounterJob: Job {
    typealias Context = TestContext
    let id: String

    func run(context: TestContext) async throws {
        await context.counter.increment()
        await context.counter.record(id)
    }
}

// MARK: - Test Suite

@Suite(.serialized)
struct ComplexJobRunnerTests {}

// MARK: - Context Propagation Tests

extension ComplexJobRunnerTests {
    @Test func jobsReceiveCorrectContext() async throws {
        let counter = TestCounter()
        let context = TestContext(counter: counter)

        let runner = JobRunner<TestContext>(context: context, maxConcurrent: 1)
        try await runner.register(CounterJob.self)
        try await runner.start()

        try await runner.enqueue(CounterJob(id: "first"), priority: .high)
        try await runner.enqueue(CounterJob(id: "second"), priority: .medium)

        try await Task.sleep(for: .milliseconds(300))

        let messages = await counter.getMessages()
        #expect(messages.count == 2)
        #expect(messages[0] == "first")
        #expect(messages[1] == "second")
    }

    @Test func multipleJobsShareSameContext() async throws {
        let counter = TestCounter()
        let context = TestContext(counter: counter)

        let runner = JobRunner<TestContext>(context: context, maxConcurrent: 2)
        try await runner.register(CounterJob.self)
        try await runner.start()

        // Enqueue multiple jobs that should all use the same context
        try await runner.enqueue(CounterJob(id: "job-1"), priority: .medium)
        try await runner.enqueue(CounterJob(id: "job-2"), priority: .medium)
        try await runner.enqueue(CounterJob(id: "job-3"), priority: .medium)
        try await runner.enqueue(CounterJob(id: "job-4"), priority: .medium)

        try await Task.sleep(for: .milliseconds(400))

        let count = await counter.getCount()
        let messages = await counter.getMessages()

        #expect(count == 4)
        #expect(messages.count == 4)
    }
}

// MARK: - Multiple Runner Tests

extension ComplexJobRunnerTests {
    @Test func multipleRunnersWithDifferentContexts() async throws {
        let counter1 = TestCounter()
        let counter2 = TestCounter()

        let context1 = TestContext(counter: counter1)
        let context2 = TestContext(counter: counter2)

        // Create two runners with different contexts
        let runner1 = JobRunner<TestContext>(context: context1, maxConcurrent: 1)
        let runner2 = JobRunner<TestContext>(context: context2, maxConcurrent: 1)

        try await runner1.register(CounterJob.self)
        try await runner2.register(CounterJob.self)

        try await runner1.start()
        try await runner2.start()

        // Enqueue jobs to each runner
        try await runner1.enqueue(CounterJob(id: "runner1-job"), priority: .medium)
        try await runner2.enqueue(CounterJob(id: "runner2-job"), priority: .medium)

        try await Task.sleep(for: .milliseconds(300))

        // Verify each runner used its own context
        let messages1 = await counter1.getMessages()
        let messages2 = await counter2.getMessages()

        #expect(messages1.count == 1)
        #expect(messages1[0] == "runner1-job")

        #expect(messages2.count == 1)
        #expect(messages2[0] == "runner2-job")
    }
}

// MARK: - Error Type

enum ComplexJobTestError: Error {
    case intentionalFailure
}
