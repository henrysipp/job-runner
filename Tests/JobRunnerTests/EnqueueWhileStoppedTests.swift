//
//  EnqueueWhileStoppedTests.swift
//  job-runnerTests
//
//  Created by Henry on 10/30/26.
//

import Foundation
@testable import JobRunner
import Testing

private struct RecordedJob: Job {
    typealias Context = ExecutionRecorder
    let key: String

    var traits: JobTraits {
        [RetryPolicy.noRetry, Persistence.persisted]
    }

    func run(context: ExecutionRecorder) async {
        await context.didRun(key)
    }
}

/// Time-bounded rather than `ExecutionRecorder.waitFor`'s yield count, since file store I/O can
/// outlast a fixed number of yields.
private func waitUntilRan(_ recorder: ExecutionRecorder) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while await recorder.ran.isEmpty, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Suite(.serialized)
struct EnqueueWhileStoppedTests {
    @Test("Enqueue before start persists the job and runs it on start")
    func enqueueBeforeStartRunsOnStart() async throws {
        let recorder = ExecutionRecorder()
        let runner = JobRunner(context: recorder, store: InMemoryJobStore(), maxConcurrent: 1)
        try await runner.register(RecordedJob.self)

        try await runner.enqueue(RecordedJob(key: "a"))
        await Task.yield()

        #expect(await recorder.ran.isEmpty)
        #expect(await runner.currentStatus().pending == 1)

        try await runner.start()
        await waitUntilRan(recorder)

        #expect(await recorder.ran == ["a"])
        await runner.stop()
    }

    @Test("Enqueue after stop defers the job until the runner restarts")
    func enqueueAfterStopRunsOnRestart() async throws {
        let recorder = ExecutionRecorder()
        let runner = JobRunner(context: recorder, store: InMemoryJobStore(), maxConcurrent: 1)
        try await runner.register(RecordedJob.self)
        try await runner.start()
        await runner.stop()

        try await runner.enqueue(RecordedJob(key: "a"))
        await Task.yield()

        #expect(await recorder.ran.isEmpty)
        #expect(await runner.currentStatus().pending == 1)

        try await runner.start()
        await waitUntilRan(recorder)

        #expect(await recorder.ran == ["a"])
        await runner.stop()
    }

    @Test("A job enqueued while stopped survives the process ending before restart")
    func enqueueWhileStoppedSurvivesNewRunner() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnqueueWhileStopped-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = JobRunner(
            context: ExecutionRecorder(),
            store: try await FileSystemJobStore(directoryURL: directory),
            maxConcurrent: 1
        )
        try await first.register(RecordedJob.self)
        try await first.start()
        await first.stop()
        try await first.enqueue(RecordedJob(key: "a"))

        let recorder = ExecutionRecorder()
        let second = JobRunner(
            context: recorder,
            store: try await FileSystemJobStore(directoryURL: directory),
            maxConcurrent: 1
        )
        try await second.register(RecordedJob.self)
        try await second.start()
        await waitUntilRan(recorder)

        #expect(await recorder.ran == ["a"])
        await second.stop()
    }
}

