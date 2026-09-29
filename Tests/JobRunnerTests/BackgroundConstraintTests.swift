//
//  BackgroundConstraintTests.swift
//  job-runnerTests
//
//  Created by Henry on 9/18/26.
//

import Foundation
@testable import JobRunner
import Testing

// MARK: - Recorder

actor ExecutionRecorder {
    private(set) var ran: [String] = []
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var arrived: [String] = []

    func didRun(_ key: String) {
        ran.append(key)
    }

    /// Parks the caller until `openGate()`, so a test can hold a job mid-flight.
    func arriveAndWait(_ key: String) async {
        arrived.append(key)
        await withCheckedContinuation { cont in
            gate = cont
        }
    }

    func openGate() {
        gate?.resume()
        gate = nil
    }

    func waitFor(_ condition: @Sendable (ExecutionRecorder) async -> Bool) async {
        for _ in 0 ..< 200 {
            if await condition(self) { return }
            await Task.yield()
        }
    }
}

// MARK: - Jobs

private struct ForegroundOnlyJob: Job {
    typealias Context = ExecutionRecorder
    let key: String

    var constraints: JobConstraints {
        .init(retry: .noRetry, background: .foregroundOnly)
    }

    func run(context: ExecutionRecorder) async {
        await context.didRun(key)
    }
}

private struct ContinuesInBackgroundJob: Job {
    typealias Context = ExecutionRecorder
    let key: String

    var constraints: JobConstraints {
        .init(retry: .noRetry, background: .continuesInBackground)
    }

    func run(context: ExecutionRecorder) async {
        await context.didRun(key)
    }
}

private struct GatedForegroundOnlyJob: Job {
    typealias Context = ExecutionRecorder
    let key: String

    var constraints: JobConstraints {
        .init(retry: .noRetry, background: .foregroundOnly)
    }

    func run(context: ExecutionRecorder) async {
        await context.arriveAndWait(key)
        await context.didRun(key)
    }
}

// MARK: - Tests

@Suite(.serialized)
struct BackgroundConstraintBehaviorTests {
    private func makeRunner(_ recorder: ExecutionRecorder) -> JobRunner<ExecutionRecorder> {
        JobRunner(context: recorder, store: InMemoryJobStore(), maxConcurrent: 1)
    }

    @Test("A foreground-only job is deferred while backgrounded and runs on return")
    func foregroundOnlyJobIsDeferredWhileBackgrounded() async throws {
        let recorder = ExecutionRecorder()
        let runner = makeRunner(recorder)
        try await runner.register(ForegroundOnlyJob.self)
        try await runner.start()
        await runner.setExecutionContext(.background)

        try await runner.enqueue(ForegroundOnlyJob(key: "a"))
        try await waitForBackgroundJobs()

        // Deferred, not failed: still pending, and the runner is still running.
        #expect(await recorder.ran.isEmpty)
        #expect(await runner.currentStatus().pending == 1)

        // No second enqueue — the context change alone has to re-drive the queue.
        await runner.setExecutionContext(.foreground)
        await recorder.waitFor { await !$0.ran.isEmpty }

        #expect(await recorder.ran == ["a"])
        await runner.stop()
    }

    @Test("Enqueue still succeeds while backgrounded")
    func enqueueSucceedsWhileBackgrounded() async throws {
        let recorder = ExecutionRecorder()
        let runner = makeRunner(recorder)
        try await runner.register(ForegroundOnlyJob.self)
        try await runner.start()
        await runner.setExecutionContext(.background)

        // The whole point of switching context rather than stopping: the queue keeps accepting
        // work. `stop()` would make this throw `JobError.notStarted`.
        try await runner.enqueue(ForegroundOnlyJob(key: "a"))

        #expect(await runner.currentStatus().pending == 1)
        await runner.stop()
    }

    @Test("A continues-in-background job runs while backgrounded")
    func continuesInBackgroundJobRunsWhileBackgrounded() async throws {
        let recorder = ExecutionRecorder()
        let runner = makeRunner(recorder)
        try await runner.register(ContinuesInBackgroundJob.self)
        try await runner.start()
        await runner.setExecutionContext(.background)

        try await runner.enqueue(ContinuesInBackgroundJob(key: "a"))
        await recorder.waitFor { await !$0.ran.isEmpty }

        #expect(await recorder.ran == ["a"])
        await runner.stop()
    }

    @Test("A continues-in-background job also runs in the foreground")
    func continuesInBackgroundJobRunsInForeground() async throws {
        let recorder = ExecutionRecorder()
        let runner = makeRunner(recorder)
        try await runner.register(ContinuesInBackgroundJob.self)
        try await runner.start()

        try await runner.enqueue(ContinuesInBackgroundJob(key: "a"))
        await recorder.waitFor { await !$0.ran.isEmpty }

        #expect(await recorder.ran == ["a"])
        await runner.stop()
    }

    @Test("Eligibility is checked at dequeue, so a running foreground-only job finishes")
    func runningForegroundOnlyJobFinishesAfterBackgrounding() async throws {
        let recorder = ExecutionRecorder()
        let runner = makeRunner(recorder)
        try await runner.register(GatedForegroundOnlyJob.self)
        try await runner.start()

        try await runner.enqueue(GatedForegroundOnlyJob(key: "a"))
        await recorder.waitFor { await !$0.arrived.isEmpty }

        // Backgrounding mid-flight must not interrupt work already in progress.
        await runner.setExecutionContext(.background)
        await recorder.openGate()
        await recorder.waitFor { await !$0.ran.isEmpty }

        #expect(await recorder.ran == ["a"])
        await runner.stop()
    }

    @Test("Setting the same context twice does not re-drive the queue")
    func settingSameContextIsANoOp() async throws {
        let recorder = ExecutionRecorder()
        let runner = makeRunner(recorder)
        try await runner.register(ForegroundOnlyJob.self)
        try await runner.start()

        await runner.setExecutionContext(.foreground)
        try await runner.enqueue(ForegroundOnlyJob(key: "a"))
        await recorder.waitFor { await !$0.ran.isEmpty }

        #expect(await recorder.ran == ["a"])
        await runner.stop()
    }
}

// MARK: - Constraint

struct BackgroundConstraintTests {
    @Test("foregroundOnly is satisfied only in the foreground")
    func foregroundOnlySatisfaction() {
        #expect(BackgroundConstraint.foregroundOnly.isSatisfied(by: .foreground))
        #expect(!BackgroundConstraint.foregroundOnly.isSatisfied(by: .background))
    }

    @Test("continuesInBackground is satisfied in either context")
    func continuesInBackgroundSatisfaction() {
        #expect(BackgroundConstraint.continuesInBackground.isSatisfied(by: .foreground))
        #expect(BackgroundConstraint.continuesInBackground.isSatisfied(by: .background))
    }

    @Test("Constraints default to foregroundOnly")
    func defaultIsForegroundOnly() {
        #expect(JobConstraints().background == .foregroundOnly)
    }

    @Test("Encoded constraints round-trip")
    func roundTrips() throws {
        let original = JobConstraints(background: .continuesInBackground)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JobConstraints.self, from: data)
        #expect(decoded.background == .continuesInBackground)
    }

    @Test("Legacy JSON without the key decodes as foregroundOnly")
    func legacyJSONDecodesAsForegroundOnly() throws {
        let legacyJSON = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(JobConstraints.self, from: legacyJSON)
        #expect(decoded.background == .foregroundOnly)
    }
}
