import Foundation
@testable import JobRunner
import Testing

/// Holds a running job until the test releases it, so progress can be observed mid-flight.
private actor Gate {
    private var reporter: JobProgressReporter?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var plainRuns = 0

    var hasReporter: Bool { reporter != nil }

    func park(_ reporter: JobProgressReporter) async {
        self.reporter = reporter
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }

    func report(_ progress: JobProgress) {
        reporter?.report(progress)
    }

    func didRunPlain() { plainRuns += 1 }
}

private struct ReportingJob: ProgressReportingJob {
    var traits: JobTraits { [BackgroundPolicy.continuesInBackground] }

    func run(context: Gate, progress: JobProgressReporter) async throws {
        progress.report(completed: 0, total: 100, description: "Starting")
        await context.park(progress)
    }
}

private struct PlainJob: Job {
    func run(context: Gate) async throws {
        await context.didRunPlain()
    }
}

private final class ProgressRecordingDelegate: JobRunnerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _progressed: [JobProgressedEvent] = []
    private var _completed: [UUID] = []

    var progressed: [JobProgressedEvent] { lock.withLock { _progressed } }
    var completed: [UUID] { lock.withLock { _completed } }

    func jobProgressed(_ event: JobProgressedEvent) {
        lock.withLock { _progressed.append(event) }
    }

    func jobCompleted(_ event: JobCompletedEvent) {
        lock.withLock { _completed.append(event.id) }
    }
}

struct JobProgressTests {
    private func makeRunner() async throws -> (JobRunner<Gate>, Gate, ProgressRecordingDelegate) {
        let gate = Gate()
        let delegate = ProgressRecordingDelegate()
        let runner = JobRunner(context: gate, maxConcurrent: 2)
        try await runner.register(ReportingJob.self)
        try await runner.register(PlainJob.self)
        await runner.setDelegate(delegate)
        try await runner.start()
        return (runner, gate, delegate)
    }

    @Test("Reported progress reaches the delegate and the background snapshot")
    func report_reachesDelegateAndSnapshot() async throws {
        // Given a progress-reporting job running inside a continuation
        let (runner, gate, delegate) = try await makeRunner()
        await runner.beginBackgroundContinuation()
        let id = try await runner.enqueue(ReportingJob())
        try await waitForCondition { await gate.hasReporter }

        // When it reports a new stage
        await gate.report(JobProgress(completed: 40, total: 100, description: "Uploading"))

        // Then the delegate sees it by job id, and the snapshot counts its fraction
        try await waitForCondition { delegate.progressed.last?.progress.description == "Uploading" }
        #expect(delegate.progressed.map(\.id).allSatisfy { $0 == id })
        let snapshot = await runner.backgroundWorkRemaining()
        #expect(snapshot.running == [RunningJobProgress(id: id, progress: JobProgress(completed: 40, total: 100, description: "Uploading"))])
        #expect(snapshot.completedWork == 0.4)

        await gate.release()
        try await waitForCondition { delegate.completed == [id] }
        #expect(await runner.backgroundWorkRemaining().running.isEmpty)
    }

    @Test("Reports after the job finishes are dropped")
    func report_afterFinish_isDropped() async throws {
        // Given a progress-reporting job that has finished
        let (runner, gate, delegate) = try await makeRunner()
        let id = try await runner.enqueue(ReportingJob())
        try await waitForCondition { await gate.hasReporter }
        await gate.release()
        try await waitForCondition { delegate.completed == [id] }
        let eventsBefore = delegate.progressed.count

        // When its escaped reporter is called again
        await gate.report(JobProgress(completed: 99, total: 100, description: "Late"))

        // Then nothing is delivered
        #expect(delegate.progressed.count == eventsBefore)
    }

    @Test("A job that doesn't report progress runs through run(context:)")
    func plainJob_runsUnchanged() async throws {
        let (runner, gate, delegate) = try await makeRunner()

        try await runner.enqueue(PlainJob())

        try await waitForCondition { await gate.plainRuns == 1 }
        #expect(delegate.progressed.isEmpty)
    }

    @Test("Calling run(context:) on a reporting job runs it with a discarding reporter")
    func reportingJob_runContext_discardsProgress() async throws {
        let gate = Gate()
        let run = Task { try await ReportingJob().run(context: gate) }
        try await waitForCondition { await gate.hasReporter }

        await gate.report(JobProgress(completed: 1, total: 2))
        await gate.release()

        try await run.value
    }

    @Test("A callback reporter delivers every report")
    func callbackReporter_deliversEveryReport() {
        let events = EventLog()
        let reporter = JobProgressReporter { events.append($0) }

        reporter.report(completed: 1, total: 2, description: "a")
        reporter.report(completed: 2, total: 2, description: "a")

        #expect(events.all.map(\.completed) == [1, 2])
    }

    @Test("Events are rate-limited, except when the description changes")
    func box_throttlesRepeatsButNotNewStages() {
        let events = EventLog()
        let box = ProgressBox(minimumEventInterval: .seconds(60)) { events.append($0) }

        box.report(JobProgress(completed: 1, total: 10, description: "Uploading"))
        box.report(JobProgress(completed: 2, total: 10, description: "Uploading"))
        box.report(JobProgress(completed: 10, total: 10, description: "Saving"))

        #expect(events.all.map(\.completed) == [1, 10])
        #expect(box.latest?.description == "Saving")
    }

    @Test("Fraction is nil without a usable total and clamps to 0...1")
    func fraction_handlesEdges() {
        #expect(JobProgress(completed: 5, total: nil).fraction == nil)
        #expect(JobProgress(completed: 5, total: 0).fraction == nil)
        #expect(JobProgress(completed: 15, total: 10).fraction == 1)
        #expect(JobProgress(completed: 5, total: 10).fraction == 0.5)
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [JobProgress] = []
    var all: [JobProgress] { lock.withLock { events } }
    func append(_ progress: JobProgress) { lock.withLock { events.append(progress) } }
}
