//
//  MockJobRunnerTests.swift
//  job-runner
//
//  Created by Henry on 2/3/26.
//

import Foundation
@testable import JobRunner
import Testing

@Suite(.serialized)
struct MockJobRunnerTests {}

extension MockJobRunnerTests {
    @Test func mockJobRunnerCanRegisterTypes() async throws {
        let mock = MockJobRunner<Void>(context: ())

        try await mock.register(SuccessJob.self)

        let types = await mock.registeredTypes
        #expect(types.contains("SuccessJob"))
    }

    @Test func mockJobRunnerTracksEnqueuedJobs() async throws {
        let mock = MockJobRunner<Void>(context: ())

        try await mock.register(SuccessJob.self)
        try await mock.start()

        let job1 = SuccessJob(key: "test-1")
        let job2 = SuccessJob(key: "test-2")

        try await mock.enqueue(job1, priority: .high)
        try await mock.enqueue(job2, priority: .medium)

        let count = await mock.getEnqueuedJobCount()
        #expect(count == 2)

        let jobs = await mock.getEnqueuedJobs(ofType: SuccessJob.self)
        #expect(jobs.count == 2)
        #expect(jobs[0].key == "test-1")
        #expect(jobs[1].key == "test-2")
    }

    @Test func mockJobRunnerTracksStartCalls() async throws {
        let mock = MockJobRunner<Void>(context: ())

        try await mock.start()
        try await mock.start()

        let callCount = await mock.startCallCount
        let isStarted = await mock.isStarted

        #expect(callCount == 2)
        #expect(isStarted)
    }

    @Test func mockJobRunnerCanSimulateErrors() async throws {
        let mock = MockJobRunner<Void>(context: ())

        await mock.reset()
        await mock.setErrorOnStart(JobError.notStarted)

        do {
            try await mock.start()
            #expect(Bool(false), "Should have thrown error")
        } catch let error as JobError {
            #expect(error == .notStarted)
        }
    }

    @Test func mockJobRunnerReset() async throws {
        let mock = MockJobRunner<Void>(context: ())

        try await mock.register(SuccessJob.self)
        try await mock.start()
        try await mock.enqueue(SuccessJob(key: "test"), priority: .medium)

        await mock.reset()

        let types = await mock.registeredTypes
        let jobCount = await mock.getEnqueuedJobCount()
        let callCount = await mock.startCallCount
        let isStarted = await mock.isStarted

        #expect(types.isEmpty)
        #expect(jobCount == 0)
        #expect(callCount == 0)
        #expect(!isStarted)
    }

    @Test func mockJobRunnerConformsToProtocol() async throws {
        // Test that MockJobRunner conforms to JobRunnerProtocol
        // We need a generic function to test this properly
        func testProtocolConformance<R: JobRunnerProtocol>(
            _ runner: R
        ) async throws where R.Context == Void {
            try await runner.register(SuccessJob.self)
            try await runner.start()
            try await runner.enqueue(SuccessJob(key: "protocol-test"), priority: .high)
        }

        let mock = MockJobRunner<Void>(context: ())
        try await testProtocolConformance(mock)

        // If this compiles and runs, the protocol conformance works
        #expect(Bool(true))
    }
}
