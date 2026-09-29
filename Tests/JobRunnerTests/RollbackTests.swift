//
//  RollbackTests.swift
//  job-runnerTests
//
//  Created by Henry on 9/18/26.
//

import Foundation
@testable import JobRunner
import Testing

// MARK: - Recorder

/// Records what each job did so a test can assert on rollback without reaching into the runner.
actor RollbackRecorder {
    private(set) var rolledBack: [String] = []
    private(set) var rollbackErrors: [String] = []
    private(set) var ran: [String] = []

    func didRun(_ key: String) {
        ran.append(key)
    }

    func didRollBack(_ key: String, error: any Error) {
        rolledBack.append(key)
        rollbackErrors.append(String(describing: type(of: error)))
    }

    func waitFor(_ condition: @escaping @Sendable (RollbackRecorder) async -> Bool) async throws {
        try await waitForCondition { await condition(self) }
    }

}

// MARK: - Errors

struct RollbackTestError: Error {}

// MARK: - Jobs

private struct PermanentFailureJob: Job {
    typealias Context = RollbackRecorder
    let key: String

    var constraints: JobConstraints {
        .init(retry: .init(maxAttempts: 3, strategy: .fixed(delay: 600)))
    }

    func run(context: RollbackRecorder) async throws {
        await context.didRun(key)
        throw JobFailure.permanent(RollbackTestError())
    }

    func rollback(context: RollbackRecorder, error: any Error) async {
        await context.didRollBack(key, error: error)
    }
}

private struct TransientFailureJob: Job {
    typealias Context = RollbackRecorder
    let key: String
    let maxAttempts: Int

    var constraints: JobConstraints {
        .init(retry: .init(maxAttempts: maxAttempts, strategy: .fixed(delay: 600)))
    }

    func run(context: RollbackRecorder) async throws {
        await context.didRun(key)
        throw JobFailure.transient(RollbackTestError())
    }

    func rollback(context: RollbackRecorder, error: any Error) async {
        await context.didRollBack(key, error: error)
    }
}

private struct NoRetryConstraintJob: Job {
    typealias Context = RollbackRecorder
    let key: String

    var constraints: JobConstraints {
        .init(retry: nil)
    }

    func run(context: RollbackRecorder) async throws {
        await context.didRun(key)
        throw RollbackTestError()
    }

    func rollback(context: RollbackRecorder, error: any Error) async {
        await context.didRollBack(key, error: error)
    }
}

private struct SucceedingJob: Job {
    typealias Context = RollbackRecorder
    let key: String

    func run(context: RollbackRecorder) async {
        await context.didRun(key)
    }

    func rollback(context: RollbackRecorder, error: any Error) async {
        await context.didRollBack(key, error: error)
    }
}

// MARK: - Tests

@Suite(.serialized)
struct RollbackTests {
    private func makeRunner(_ recorder: RollbackRecorder) -> JobRunner<RollbackRecorder> {
        JobRunner(context: recorder, store: InMemoryJobStore(), maxConcurrent: 1)
    }

    @Test("Permanent failure rolls back with the underlying error, not the JobFailure wrapper")
    func permanentFailureRollsBackWithUnderlyingError() async throws {
        let recorder = RollbackRecorder()
        let runner = makeRunner(recorder)
        try await runner.register(PermanentFailureJob.self)
        try await runner.start()

        try await runner.enqueue(PermanentFailureJob(key: "a"))
        try await recorder.waitFor { await !$0.rolledBack.isEmpty }

        #expect(await recorder.rolledBack == ["a"])
        #expect(await recorder.rollbackErrors == ["RollbackTestError"])
        await runner.stop()
    }

    @Test("A transient failure that will retry does not roll back")
    func transientFailureWithRetriesLeftDoesNotRollBack() async throws {
        let recorder = RollbackRecorder()
        let runner = makeRunner(recorder)
        try await runner.register(TransientFailureJob.self)
        try await runner.start()

        try await runner.enqueue(TransientFailureJob(key: "a", maxAttempts: 3))
        try await recorder.waitFor { await !$0.ran.isEmpty }
        try await waitForBackgroundJobs()

        #expect(await recorder.ran == ["a"])
        #expect(await recorder.rolledBack.isEmpty)
        await runner.stop()
    }

    @Test("Exhausting the retry budget rolls back")
    func exhaustedRetriesRollBack() async throws {
        let recorder = RollbackRecorder()
        let runner = makeRunner(recorder)
        try await runner.register(TransientFailureJob.self)
        try await runner.start()

        // maxAttempts: 1 means the first failure is already terminal.
        try await runner.enqueue(TransientFailureJob(key: "a", maxAttempts: 1))
        try await recorder.waitFor { await !$0.rolledBack.isEmpty }

        #expect(await recorder.rolledBack == ["a"])
        await runner.stop()
    }

    @Test("A job with no retry constraint rolls back on its first failure")
    func noRetryConstraintRollsBackImmediately() async throws {
        let recorder = RollbackRecorder()
        let runner = makeRunner(recorder)
        try await runner.register(NoRetryConstraintJob.self)
        try await runner.start()

        try await runner.enqueue(NoRetryConstraintJob(key: "a"))
        try await recorder.waitFor { await !$0.rolledBack.isEmpty }

        #expect(await recorder.rolledBack == ["a"])
        // A bare error is passed through unwrapped.
        #expect(await recorder.rollbackErrors == ["RollbackTestError"])
        await runner.stop()
    }

    @Test("A successful job never rolls back")
    func successDoesNotRollBack() async throws {
        let recorder = RollbackRecorder()
        let runner = makeRunner(recorder)
        try await runner.register(SucceedingJob.self)
        try await runner.start()

        try await runner.enqueue(SucceedingJob(key: "a"))
        try await recorder.waitFor { await !$0.ran.isEmpty }
        try await waitForBackgroundJobs()

        #expect(await recorder.ran == ["a"])
        #expect(await recorder.rolledBack.isEmpty)
        await runner.stop()
    }

    @Test("A job that fails to decode is failed without a rollback")
    func undecodableJobFailsWithoutRollback() async throws {
        let recorder = RollbackRecorder()
        let store = InMemoryJobStore()
        let runner = JobRunner(context: recorder, store: store, maxConcurrent: 1)
        try await runner.register(SucceedingJob.self)
        try await runner.start()

        // Payload the registered type cannot decode: `key` is missing.
        let orphan = SerializedJob(
            id: UUID(),
            typeName: String(describing: SucceedingJob.self),
            priority: .medium,
            constraints: .init(retry: .noRetry),
            originalCreatedAt: Date.now,
            attempts: 0,
            status: .pending,
            jobData: Data("{}".utf8)
        )
        try await store.save(orphan)
        try await runner.enqueue(SucceedingJob(key: "kick"))

        try await recorder.waitFor { await $0.ran.contains("kick") }
        try await waitForBackgroundJobs()

        #expect(await recorder.rolledBack.isEmpty)
        #expect(try await store.load(id: orphan.id)?.status == .permanentlyFailed)
        await runner.stop()
    }
}
