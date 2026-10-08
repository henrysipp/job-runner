//
//  BackgroundContinuationCoordinatorTests.swift
//  job-runnerTests
//
//  Created by Henry on 9/21/26.
//

import Foundation
@testable import JobRunner
import Testing

struct BackgroundContinuationCoordinatorTests {
    private let identifier = "com.example.app.continued-jobs"

    private func makeCoordinator(
        scheduler: MockContinuationScheduler = MockContinuationScheduler(),
        runner: StubContinuationRunner? = StubContinuationRunner(),
        observer: RecordingContinuationObserver = RecordingContinuationObserver(),
        enabled: Bool = true,
        pollInterval: Duration = .milliseconds(5),
        maxDuration: Duration = .seconds(30)
    ) -> BackgroundContinuationCoordinator {
        BackgroundContinuationCoordinator(
            scheduler: scheduler,
            runner: { runner },
            configuration: .init(
                identifier: identifier,
                title: "Uploading",
                isEnabled: { enabled },
                maxDuration: maxDuration,
                pollInterval: pollInterval
            ),
            observer: observer
        )
    }

    // MARK: - Registration

    @Test("Constructing the coordinator registers the launch handler")
    func init_registersIdentifier() {
        let scheduler = MockContinuationScheduler()
        _ = makeCoordinator(scheduler: scheduler)
        #expect(scheduler.registered == [identifier])
    }

    @Test("A refused registration is reported")
    func init_registrationRefused_reportsIt() {
        let scheduler = MockContinuationScheduler()
        scheduler.registrationSucceeds = false
        let observer = RecordingContinuationObserver()
        _ = makeCoordinator(scheduler: scheduler, observer: observer)
        #expect(observer.registrationFailures == [identifier])
    }

    // MARK: - Submission gating

    @Test("Disabled configuration does not submit")
    func requestContinuation_disabled_skips() async {
        let scheduler = MockContinuationScheduler()
        let observer = RecordingContinuationObserver()
        let coordinator = makeCoordinator(scheduler: scheduler, observer: observer, enabled: false)

        await coordinator.requestContinuation()

        #expect(scheduler.submissions.isEmpty)
        #expect(observer.skips == [.disabled])
    }

    @Test("A backgrounded host does not submit")
    func requestContinuation_backgrounded_skips() async {
        let scheduler = MockContinuationScheduler()
        let observer = RecordingContinuationObserver()
        let coordinator = makeCoordinator(scheduler: scheduler, observer: observer)
        await coordinator.appDidEnterBackground()

        await coordinator.requestContinuation()

        #expect(scheduler.submissions.isEmpty)
        #expect(observer.skips == [.backgrounded])
    }

    @Test("Submission is single-flighted")
    func requestContinuation_calledTwice_submitsOnce() async {
        let scheduler = MockContinuationScheduler()
        let observer = RecordingContinuationObserver()
        let coordinator = makeCoordinator(scheduler: scheduler, observer: observer)

        await coordinator.requestContinuation()
        await coordinator.requestContinuation()

        #expect(scheduler.submissions.count == 1)
        #expect(observer.skips == [.alreadyActive])
    }

    @Test("No runner means no submission")
    func requestContinuation_noRunner_skips() async {
        let scheduler = MockContinuationScheduler()
        let observer = RecordingContinuationObserver()
        let coordinator = makeCoordinator(scheduler: scheduler, runner: nil, observer: observer)

        await coordinator.requestContinuation()

        #expect(scheduler.submissions.isEmpty)
        #expect(observer.skips == [.runnerUnavailable])
    }

    @Test("The submission carries the configured identifier and strings")
    func requestContinuation_buildsRequestFromConfiguration() async throws {
        let scheduler = MockContinuationScheduler()
        let coordinator = makeCoordinator(scheduler: scheduler)

        await coordinator.requestContinuation()

        let submission = try #require(scheduler.submissions.first)
        // Same string that was registered: the platform doesn't match wildcards back to handlers.
        #expect(submission.identifier == identifier)
        #expect(submission.title == "Uploading")
        #expect(submission.subtitle == "0 succeeded, 0 failed, 0 remaining")
    }

    @Test("A failed submission releases the single-flight guard")
    func requestContinuation_submissionFails_allowsRetry() async {
        let scheduler = MockContinuationScheduler()
        scheduler.submissionError = ContinuationTestError()
        let observer = RecordingContinuationObserver()
        let coordinator = makeCoordinator(scheduler: scheduler, observer: observer)
        await coordinator.requestContinuation()

        scheduler.submissionError = nil
        await coordinator.requestContinuation()

        #expect(scheduler.submissions.count == 1)
        #expect(observer.submissionFailures == [identifier])
    }

    // MARK: - Delegate routing

    @Test("Enqueuing a continues-in-background job submits; a foreground-only one does not")
    func jobEnqueued_routesOnBackgroundPolicy() async throws {
        let scheduler = MockContinuationScheduler()
        let coordinator = makeCoordinator(scheduler: scheduler)

        coordinator.jobEnqueued(event(background: .foregroundOnly))
        try await waitForBackgroundJobs()
        #expect(scheduler.submissions.isEmpty)

        coordinator.jobEnqueued(event(background: .continuesInBackground))
        for _ in 0 ..< 50 where scheduler.submissions.isEmpty {
            await Task.yield()
        }
        #expect(scheduler.submissions.count == 1)
    }

    private func event(background: BackgroundPolicy) -> JobEnqueuedEvent {
        JobEnqueuedEvent(
            id: UUID(),
            jobType: Never.self,
            priority: .high,
            traits: .init(background: background),
            jobData: "{}"
        )
    }

    // MARK: - Lifecycle

    @Test("Lifecycle calls switch the runner's execution context")
    func lifecycle_switchesRunnerContext() async {
        let runner = StubContinuationRunner()
        let coordinator = makeCoordinator(runner: runner)

        await coordinator.appDidEnterBackground()
        await coordinator.appDidEnterForeground()

        #expect(await runner.executionContexts == [.background, .foreground])
        #expect(await runner.startCount == 1)
    }

    // MARK: - Drain

    @Test("An already-drained queue completes successfully, exactly once")
    func drain_emptyQueue_completesOnce() async {
        let observer = RecordingContinuationObserver()
        let coordinator = makeCoordinator(runner: StubContinuationRunner(remaining: 0), observer: observer)
        let task = MockContinuationTask()

        await coordinator.drain(task: task)

        #expect(task.completions == [true])
        #expect(observer.outcomes == [.drained])
    }

    @Test("Progress ratchets as the queue drains")
    func drain_reportsMonotonicProgress() async {
        let runner = StubContinuationRunner(remaining: 2)
        let coordinator = makeCoordinator(runner: runner)
        let task = MockContinuationTask()

        let drain = Task { await coordinator.drain(task: task) }
        try? await Task.sleep(for: .milliseconds(30))
        await runner.setRemaining(1, succeeded: 1)
        try? await Task.sleep(for: .milliseconds(30))
        await runner.setRemaining(0, succeeded: 2)
        await drain.value

        #expect(task.progress.totalUnitCount == 2)
        #expect(task.completions == [true])
        #expect(task.titles.map(\.subtitle).contains("0 succeeded, 0 failed, 2 remaining"))
        #expect(task.titles.map(\.subtitle).contains("1 succeeded, 0 failed, 1 remaining"))
    }

    @Test("Work added mid-drain grows the total instead of overflowing it")
    func drain_workAddedMidDrain_growsDenominator() async {
        let runner = StubContinuationRunner(remaining: 2)
        let coordinator = makeCoordinator(runner: runner)
        let task = MockContinuationTask()

        let drain = Task { await coordinator.drain(task: task) }
        try? await Task.sleep(for: .milliseconds(30))
        await runner.setRemaining(1, succeeded: 1)
        try? await Task.sleep(for: .milliseconds(30))
        await runner.setRemaining(3, succeeded: 1)
        try? await Task.sleep(for: .milliseconds(30))
        await runner.setRemaining(0, succeeded: 3, failed: 1)
        await drain.value

        #expect(task.progress.totalUnitCount == 4)
        #expect(task.progress.completedUnitCount == 4)
        #expect(task.titles.map(\.subtitle).contains("1 succeeded, 0 failed, 3 remaining"))
        #expect(task.titles.last?.subtitle == "3 succeeded, 1 failed, 0 remaining")
    }

    @Test("A drained continuation with failures reports unsuccessful completion")
    func drain_failuresAreReported() async {
        let observer = RecordingContinuationObserver()
        let coordinator = makeCoordinator(runner: StubContinuationRunner(succeeded: 8, failed: 2), observer: observer)
        let task = MockContinuationTask()
        await coordinator.drain(task: task)
        #expect(task.completions == [false])
        #expect(task.progress.completedUnitCount == 10)
        #expect(task.progress.totalUnitCount == 10)
        #expect(task.titles.last?.subtitle == "8 succeeded, 2 failed, 0 remaining")
        #expect(observer.outcomes == [.failed])
    }

    @Test("Interruptions are not counted as failures or completed work")
    func drain_interruptionsAreSeparate() async {
        let observer = RecordingContinuationObserver()
        let coordinator = makeCoordinator(runner: StubContinuationRunner(succeeded: 1, interrupted: 1), observer: observer)
        let task = MockContinuationTask()
        await coordinator.drain(task: task)
        #expect(task.completions == [false])
        #expect(task.progress.completedUnitCount == 1)
        #expect(task.progress.totalUnitCount == 2)
        #expect(observer.outcomes == [.interrupted])
    }

    @Test("Exceeding the time budget completes unsuccessfully")
    func drain_exceedsBudget_completesUnsuccessfully() async {
        let observer = RecordingContinuationObserver()
        let runner = StubContinuationRunner(remaining: 1)
        let coordinator = makeCoordinator(
            runner: runner,
            observer: observer,
            pollInterval: .milliseconds(5),
            maxDuration: .milliseconds(20)
        )
        let task = MockContinuationTask()

        await coordinator.appDidEnterBackground()
        await coordinator.drain(task: task)

        #expect(task.completions == [false])
        #expect(observer.outcomes == [.budgetExceeded])
        #expect(await runner.shutdownCount == 1)
    }

    // MARK: - Expiration

    @Test("Expiration completes synchronously, once, and shuts the runner down")
    func drain_expires_completesImmediatelyAndOnce() async {
        let runner = StubContinuationRunner(remaining: 1)
        let observer = RecordingContinuationObserver()
        let coordinator = makeCoordinator(runner: runner, observer: observer)
        let task = MockContinuationTask()
        await coordinator.appDidEnterBackground()
        let drain = Task { await coordinator.drain(task: task) }

        try? await Task.sleep(for: .milliseconds(20))
        #expect(task.hasExpirationHandler)
        task.expire()

        // Completed from inside the handler, before anything is awaited.
        #expect(task.completions == [false])

        await drain.value
        #expect(task.completions == [false])
        #expect(observer.outcomes == [.expired])

        for _ in 0 ..< 50 where await runner.shutdownCount == 0 {
            await Task.yield()
        }
        #expect(await runner.shutdownCount == 1)
    }
}


extension BackgroundContinuationCoordinatorTests {
    @Test("Foreground resumption waits for expiration teardown")
    func foregroundWaitsForShutdown() async throws {
        let runner = StubContinuationRunner(remaining: 1)
        await runner.holdShutdown()
        let coordinator = makeCoordinator(runner: runner)
        await coordinator.appDidEnterBackground()
        let task = MockContinuationTask()
        let drain = Task { await coordinator.drain(task: task) }
        try await waitForCondition { task.hasExpirationHandler }
        task.expire()
        try await waitForCondition { await runner.shutdownCount == 1 }
        let foreground = Task { await coordinator.appDidEnterForeground() }
        #expect(await runner.startCount == 0)
        await runner.releaseShutdown()
        await foreground.value
        await drain.value
        #expect(await runner.lifecycleEvents == ["shutdown began", "shutdown ended", "start"])
    }

    @Test("A late expiration does not shut down resumed foreground work")
    func lateExpirationLeavesForegroundRunning() async throws {
        let runner = StubContinuationRunner(remaining: 1)
        let coordinator = makeCoordinator(runner: runner)
        await coordinator.appDidEnterBackground()
        let task = MockContinuationTask()
        let drain = Task { await coordinator.drain(task: task) }
        try await waitForCondition { task.hasExpirationHandler }
        await coordinator.appDidEnterForeground()
        task.expire()
        await drain.value
        #expect(task.completions == [false])
        #expect(await runner.shutdownCount == 0)
        #expect(await runner.startCount == 1)
    }
}
