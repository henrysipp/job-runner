//
//  ShutdownTests.swift
//  job-runnerTests
//
//  Created by Henry on 9/18/26.
//

import Foundation
@testable import JobRunner
import Testing

// MARK: - Recorder

actor ShutdownRecorder {
    private(set) var started: [String] = []
    private(set) var finished: [String] = []
    private(set) var rolledBack: [String] = []
    private(set) var observedCancellation: [String] = []

    private var gate: CheckedContinuation<Void, Never>?
    var isParked: Bool { gate != nil }

    func didStart(_ key: String) {
        started.append(key)
    }

    func didFinish(_ key: String) {
        finished.append(key)
    }

    func didRollBack(_ key: String) {
        rolledBack.append(key)
    }

    func didObserveCancellation(_ key: String) {
        observedCancellation.append(key)
    }

    /// Parks until `openGate()`. Used by jobs that ignore cancellation.
    func park() async {
        await withCheckedContinuation { cont in
            gate = cont
        }
    }

    func openGate() {
        gate?.resume()
        gate = nil
    }

    func waitFor(_ condition: @Sendable (ShutdownRecorder) async -> Bool) async {
        for _ in 0 ..< 200 {
            if await condition(self) { return }
            await Task.yield()
        }
    }
}

// MARK: - Delegate

final class RecordingShutdownDelegate: JobRunnerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _interrupted: [UUID] = []
    private var _failed: [UUID] = []
    private var _completed: [UUID] = []

    var interrupted: [UUID] {
        lock.withLock { _interrupted }
    }

    var failed: [UUID] {
        lock.withLock { _failed }
    }

    var completed: [UUID] {
        lock.withLock { _completed }
    }

    func jobInterrupted(_ event: JobInterruptedEvent) {
        lock.withLock { _interrupted.append(event.id) }
    }

    func jobFailed(_ event: JobFailedEvent) {
        lock.withLock { _failed.append(event.id) }
    }

    func jobCompleted(_ event: JobCompletedEvent) {
        lock.withLock { _completed.append(event.id) }
    }
}

// MARK: - Jobs

/// Cooperative: suspends on a cancellable sleep and unwinds when cancelled.
private struct CooperativeJob: Job {
    typealias Context = ShutdownRecorder
    let key: String

    var constraints: JobConstraints {
        .init(retry: .init(maxAttempts: 3, strategy: .fixed(delay: 600)))
    }

    func run(context: ShutdownRecorder) async throws {
        await context.didStart(key)
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            await context.didObserveCancellation(key)
            throw error
        }
        await context.didFinish(key)
    }

    func rollback(context: ShutdownRecorder, error _: any Error) async {
        await context.didRollBack(key)
    }
}

/// Ignores cancellation entirely and still succeeds.
private struct UncooperativeSucceedingJob: Job {
    typealias Context = ShutdownRecorder
    let key: String

    var constraints: JobConstraints {
        .init(retry: .noRetry)
    }

    func run(context: ShutdownRecorder) async {
        await context.didStart(key)
        await withTaskCancellationHandler {
            await context.park()
        } onCancel: {
            Task { await context.didObserveCancellation(key) }
        }
        await context.didFinish(key)
    }

    func rollback(context: ShutdownRecorder, error _: any Error) async {
        await context.didRollBack(key)
    }
}

/// Fails transiently with a long backoff, to leave a scheduled wake-up behind.
private struct BackoffJob: Job {
    typealias Context = ShutdownRecorder
    let key: String

    var constraints: JobConstraints {
        .init(retry: .init(maxAttempts: 5, strategy: .fixed(delay: 600)))
    }

    func run(context: ShutdownRecorder) async throws {
        await context.didStart(key)
        throw JobFailure.transient(ShutdownTestError())
    }
}

struct ShutdownTestError: Error {}

// MARK: - Tests

@Suite(.serialized)
struct ShutdownTests {
    private func makeRunner(
        _ recorder: ShutdownRecorder,
        store: JobStore = InMemoryJobStore()
    ) -> JobRunner<ShutdownRecorder> {
        JobRunner(context: recorder, store: store, maxConcurrent: 1)
    }

    @Test("Shutdown cancels an in-flight job and waits for its teardown")
    func shutdownCancelsAndAwaits() async throws {
        let recorder = ShutdownRecorder()
        let store = InMemoryJobStore()
        let runner = makeRunner(recorder, store: store)
        try await runner.register(CooperativeJob.self)
        try await runner.start()

        let id = try await runner.enqueue(CooperativeJob(key: "a"))
        await recorder.waitFor { await !$0.started.isEmpty }

        let finished = await runner.shutdown(timeout: nil)

        #expect(finished)
        #expect(await recorder.observedCancellation == ["a"])
        #expect(await recorder.finished.isEmpty)

        let job = try await store.load(id: id)
        #expect(job?.status == .pending)
        #expect(job?.attempts == 0)
        #expect(job?.scheduledAt == nil)
    }

    @Test("Interruption does not roll back")
    func interruptionDoesNotRollBack() async throws {
        let recorder = ShutdownRecorder()
        let runner = makeRunner(recorder)
        try await runner.register(CooperativeJob.self)
        try await runner.start()

        try await runner.enqueue(CooperativeJob(key: "a"))
        await recorder.waitFor { await !$0.started.isEmpty }
        await runner.shutdown(timeout: nil)

        // An interrupted job runs again, so compensating for it now would double-apply.
        #expect(await recorder.rolledBack.isEmpty)
    }

    @Test("Interruption emits jobInterrupted and not jobFailed")
    func interruptionEmitsInterruptedEvent() async throws {
        let recorder = ShutdownRecorder()
        let delegate = RecordingShutdownDelegate()
        let runner = makeRunner(recorder)
        await runner.setDelegate(delegate)
        try await runner.register(CooperativeJob.self)
        try await runner.start()

        let id = try await runner.enqueue(CooperativeJob(key: "a"))
        await recorder.waitFor { await !$0.started.isEmpty }
        await runner.shutdown(timeout: nil)

        #expect(delegate.interrupted == [id])
        #expect(delegate.failed.isEmpty)
        #expect(delegate.completed.isEmpty)
    }

    @Test("Shutdown leaves no job stuck in running")
    func shutdownLeavesNoRunningRows() async throws {
        let recorder = ShutdownRecorder()
        let store = InMemoryJobStore()
        let runner = makeRunner(recorder, store: store)
        try await runner.register(CooperativeJob.self)
        try await runner.start()

        try await runner.enqueue(CooperativeJob(key: "a"))
        await recorder.waitFor { await !$0.started.isEmpty }
        await runner.shutdown(timeout: nil)

        #expect(try await store.loadAll(status: .running).isEmpty)
    }

    @Test("A job that ignores cancellation but succeeds is treated as a success")
    func uncooperativeSuccessIsStillASuccess() async throws {
        let recorder = ShutdownRecorder()
        let store = InMemoryJobStore()
        let runner = makeRunner(recorder, store: store)
        try await runner.register(UncooperativeSucceedingJob.self)
        try await runner.start()

        let id = try await runner.enqueue(UncooperativeSucceedingJob(key: "a"))
        await recorder.waitFor { await !$0.started.isEmpty }

        // Shut down while the job is parked, then let it complete. The work happened, so it counts.
        async let shutdownResult = runner.shutdown(timeout: nil)
        await recorder.openGate()
        let finished = await shutdownResult

        #expect(finished)
        #expect(await recorder.finished == ["a"])
        #expect(await recorder.rolledBack.isEmpty)
        #expect(try await store.load(id: id) == nil)
    }

    @Test("Shutdown returns false and returns promptly when a job will not stop")
    func shutdownTimesOutOnBlockedJob() async throws {
        let recorder = ShutdownRecorder()
        let runner = makeRunner(recorder)
        try await runner.register(UncooperativeSucceedingJob.self)
        try await runner.start()

        try await runner.enqueue(UncooperativeSucceedingJob(key: "a"))
        await recorder.waitFor { await !$0.started.isEmpty }

        let clock = ContinuousClock()
        let start = clock.now
        let finished = await runner.shutdown(timeout: .milliseconds(50))
        let elapsed = clock.now - start

        #expect(!finished)
        #expect(elapsed < .seconds(5))

        // Release it so the suite doesn't leak a parked continuation.
        await recorder.openGate()
    }

    @Test("The runner restarts after a shutdown and finishes the interrupted job")
    func runnerRestartsAfterShutdown() async throws {
        let recorder = ShutdownRecorder()
        let store = InMemoryJobStore()
        let runner = makeRunner(recorder, store: store)
        try await runner.register(CooperativeJob.self)
        try await runner.register(UncooperativeSucceedingJob.self)
        try await runner.start()

        try await runner.enqueue(CooperativeJob(key: "a"))
        await recorder.waitFor { await !$0.started.isEmpty }
        await runner.shutdown(timeout: nil)

        // On restart the interrupted job is eligible again, with its attempt budget intact.
        try await runner.start()
        await recorder.waitFor { await $0.started.count == 2 }

        #expect(await recorder.started == ["a", "a"])
        await runner.shutdown(timeout: nil)
    }

    @Test("Shutdown cancels a pending scheduled wake-up")
    func shutdownCancelsScheduledWakeUp() async throws {
        let recorder = ShutdownRecorder()
        let runner = makeRunner(recorder)
        try await runner.register(BackoffJob.self)
        try await runner.start()

        try await runner.enqueue(BackoffJob(key: "a"))
        await recorder.waitFor { await !$0.started.isEmpty }
        try await waitForBackgroundJobs()

        await runner.shutdown(timeout: nil)
        try await waitForBackgroundJobs()

        // The 600s backoff means a second run could only come from a stray sleeper.
        #expect(await recorder.started == ["a"])
    }

    @Test("Shutdown on an idle runner succeeds")
    func shutdownWithNothingInFlight() async throws {
        let recorder = ShutdownRecorder()
        let runner = makeRunner(recorder)
        try await runner.start()

        #expect(await runner.shutdown(timeout: nil))
    }

    @Test("stop() still lets an in-flight job run to completion")
    func stopDoesNotCancelInFlightWork() async throws {
        let recorder = ShutdownRecorder()
        let store = InMemoryJobStore()
        let runner = makeRunner(recorder, store: store)
        try await runner.register(UncooperativeSucceedingJob.self)
        try await runner.start()

        let id = try await runner.enqueue(UncooperativeSucceedingJob(key: "a"))
        await recorder.waitFor { await !$0.started.isEmpty }

        // This pins the existing contract. Consumers call stop() on backgrounding and in ~30 test
        // teardowns; it must never start cancelling in-flight work.
        await runner.stop()
        await recorder.openGate()
        await recorder.waitFor { await !$0.finished.isEmpty }

        #expect(await recorder.finished == ["a"])
        #expect(await recorder.observedCancellation.isEmpty)
        #expect(try await store.load(id: id) == nil)
    }

    @Test("Completed jobs do not leak task handles")
    func completedJobsClearTheirHandles() async throws {
        let recorder = ShutdownRecorder()
        let runner = makeRunner(recorder)
        try await runner.register(UncooperativeSucceedingJob.self)
        try await runner.start()

        for index in 0 ..< 3 {
            try await runner.enqueue(UncooperativeSucceedingJob(key: "job-\(index)"))
            await recorder.waitFor { await $0.started.count == index + 1 }
            await recorder.openGate()
            await recorder.waitFor { await $0.finished.count == index + 1 }
        }

        try await waitForBackgroundJobs()
        #expect(await runner.inFlightTaskCount == 0)
        await runner.stop()
    }
}


extension ShutdownTests {
    @Test("Restart after timeout retains the live job and its concurrency slot")
    func restartAfterTimeoutDoesNotDuplicateJob() async throws {
        let recorder = ShutdownRecorder()
        let store = InMemoryJobStore()
        let runner = makeRunner(recorder, store: store)
        try await runner.register(UncooperativeSucceedingJob.self)
        try await runner.register(BackoffJob.self)
        try await runner.start()
        let id = try await runner.enqueue(UncooperativeSucceedingJob(key: "original"))
        try await waitForCondition { await recorder.isParked }
        #expect(await runner.shutdown(timeout: .milliseconds(10)) == false)

        try await runner.start()
        try await runner.enqueue(BackoffJob(key: "next"))
        #expect(try await store.load(id: id)?.status == .running)
        #expect(await runner.inFlightTaskCount == 1)
        #expect(await recorder.started == ["original"])
        await recorder.openGate()
        try await waitForCondition { await recorder.started.contains("next") }
        #expect(await recorder.started == ["original", "next"])
        await runner.shutdown(timeout: nil)
        #expect(try await store.load(id: id) == nil)
    }

    @Test("An earlier shutdown does not cancel or await executions from a later start")
    func oldShutdownOnlyWaitsForItsSnapshot() async throws {
        let recorder = ShutdownRecorder()
        let runner = makeRunner(recorder)
        try await runner.register(UncooperativeSucceedingJob.self)
        try await runner.start()
        try await runner.enqueue(UncooperativeSucceedingJob(key: "old"))
        try await waitForCondition { await recorder.isParked }
        let shutdown = Task { await runner.shutdown(timeout: .seconds(2)) }
        try await waitForCondition { await recorder.observedCancellation.contains("old") }

        try await runner.start()
        try await runner.enqueue(UncooperativeSucceedingJob(key: "new"))
        await recorder.openGate()
        try await waitForCondition {
            let started = await recorder.started.contains("new")
            let parked = await recorder.isParked
            return started && parked
        }
        #expect(await shutdown.value)
        #expect(await recorder.observedCancellation == ["old"])
        #expect(await runner.inFlightTaskCount == 1)
        await recorder.openGate()
        await runner.shutdown(timeout: nil)
    }
}
