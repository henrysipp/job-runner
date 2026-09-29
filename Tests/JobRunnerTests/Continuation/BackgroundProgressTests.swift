import Foundation
@testable import JobRunner
import Testing

private actor ProgressRecorder {
    var attempts = 0
    var rollbacks = 0
    func didRun() { attempts += 1 }
    func didRollback() { rollbacks += 1 }
}

private struct ProgressJob: Job {
    enum Outcome: String, Codable { case success, permanentFailure, exhaustedRetries, retry, interrupted }
    let outcome: Outcome
    var background: BackgroundConstraint = .continuesInBackground

    var constraints: JobConstraints {
        .init(
            retry: .init(maxAttempts: 2, strategy: outcome == .retry ? .fixed(delay: 600) : .immediate),
            background: background
        )
    }

    func run(context: ProgressRecorder) async throws {
        await context.didRun()
        switch outcome {
        case .success: return
        case .permanentFailure: throw JobFailure.permanent(ContinuationTestError())
        case .exhaustedRetries, .retry: throw ContinuationTestError()
        case .interrupted: try await Task.sleep(for: .seconds(60))
        }
    }

    func rollback(context: ProgressRecorder, error: any Error) async {
        await context.didRollback()
    }
}

struct BackgroundProgressTests {
    @Test("Progress counts each job's first outcome, including retryable failures, and excludes foreground jobs")
    func countsActualOutcomes() async throws {
        let runner = JobRunner(context: ProgressRecorder(), maxConcurrent: 1)
        try await runner.register(ProgressJob.self)
        try await runner.start()
        await runner.beginBackgroundContinuation()
        try await runner.enqueue(ProgressJob(outcome: .success))
        try await runner.enqueue(ProgressJob(outcome: .permanentFailure))
        try await runner.enqueue(ProgressJob(outcome: .exhaustedRetries))
        try await runner.enqueue(ProgressJob(outcome: .retry))
        try await runner.enqueue(ProgressJob(outcome: .success, background: .foregroundOnly))
        try await runner.enqueue(ProgressJob(outcome: .permanentFailure, background: .foregroundOnly))
        try await waitForCondition {
            let status = await runner.currentStatus()
            return status.failed == 3 && status.running == 0 && status.pending == 1
        }
        await runner.shutdown(timeout: nil)
        let snapshot = await runner.backgroundWorkRemaining()
        #expect(snapshot == BackgroundWorkSnapshot(remaining: 0, succeeded: 1, failed: 3))
        await runner.endBackgroundContinuation()
        await runner.beginBackgroundContinuation()
        #expect(await runner.backgroundWorkRemaining() == .empty)
    }

    @Test("Immediate retries wait for foreground and roll back only when attempts are exhausted")
    func retriesWaitForForeground() async throws {
        let recorder = ProgressRecorder()
        let store = InMemoryJobStore()
        let runner = JobRunner(context: recorder, store: store, maxConcurrent: 1)
        try await runner.register(ProgressJob.self)
        try await runner.start()
        await runner.setExecutionContext(.background)
        await runner.beginBackgroundContinuation()
        let id = try await runner.enqueue(ProgressJob(outcome: .exhaustedRetries))
        try await waitForCondition { await runner.backgroundWorkRemaining().failed == 1 }
        // Adding fresh work drives another queue pass; the failed job must still not retry.
        try await runner.enqueue(ProgressJob(outcome: .success))
        try await waitForCondition { await runner.backgroundWorkRemaining().succeeded == 1 }
        #expect(try await store.load(id: id)?.attempts == 1)
        #expect(try await store.load(id: id)?.status == .pending)
        #expect(await recorder.rollbacks == 0)
        #expect(await runner.backgroundWorkRemaining().remaining == 0)

        await runner.setExecutionContext(.foreground)
        try await waitForCondition { await runner.currentStatus().failed == 1 }
        #expect(try await store.load(id: id)?.attempts == 2)
        #expect(await recorder.rollbacks == 1)
        #expect(await runner.backgroundWorkRemaining().failed == 1)
        await runner.shutdown(timeout: nil)
    }

    @Test("Foreground return preserves scheduled retry backoff")
    func foregroundRespectsBackoff() async throws {
        let recorder = ProgressRecorder()
        let store = InMemoryJobStore()
        let runner = JobRunner(context: recorder, store: store, maxConcurrent: 1)
        try await runner.register(ProgressJob.self)
        try await runner.start()
        await runner.setExecutionContext(.background)
        await runner.beginBackgroundContinuation()
        let id = try await runner.enqueue(ProgressJob(outcome: .retry))
        try await waitForCondition { await runner.backgroundWorkRemaining().failed == 1 }
        let scheduledAt = try #require(try await store.load(id: id)?.scheduledAt)
        await runner.setExecutionContext(.foreground)
        try await runner.enqueue(ProgressJob(outcome: .success))
        try await waitForCondition { await runner.backgroundWorkRemaining().succeeded == 1 }
        #expect(try await store.load(id: id)?.attempts == 1)
        #expect(try await store.load(id: id)?.scheduledAt == scheduledAt)
        #expect(await recorder.rollbacks == 0)
        await runner.shutdown(timeout: nil)
    }

    @Test("Interrupted jobs have no failure outcome or consumed attempt")
    func interruptionIsSeparate() async throws {
        let recorder = ProgressRecorder()
        let store = InMemoryJobStore()
        let runner = JobRunner(context: recorder, store: store, maxConcurrent: 1)
        try await runner.register(ProgressJob.self)
        try await runner.start()
        await runner.beginBackgroundContinuation()
        let id = try await runner.enqueue(ProgressJob(outcome: .interrupted))
        try await waitForCondition { await recorder.attempts == 1 }
        await runner.shutdown(timeout: nil)
        #expect(await runner.backgroundWorkRemaining() == BackgroundWorkSnapshot(remaining: 0, interrupted: 1))
        #expect(try await store.load(id: id)?.attempts == 0)
        #expect(await recorder.rollbacks == 0)
    }
}
