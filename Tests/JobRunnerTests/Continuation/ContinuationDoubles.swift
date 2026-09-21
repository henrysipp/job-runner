//
//  ContinuationDoubles.swift
//  job-runnerTests
//
//  Created by Henry on 9/21/26.
//

import Foundation
@testable import JobRunner

// MARK: - MockContinuationTask

/// Stands in for the platform task so the drain loop can be driven without an OS.
final class MockContinuationTask: ContinuationTask, @unchecked Sendable {
    let progress = Progress()

    private let lock = NSLock()
    private var _expirationHandler: (@Sendable () -> Void)?
    private var _titles: [(title: String, subtitle: String)] = []
    private var _completions: [Bool] = []

    /// Every `updateTitle` call, in order.
    var titles: [(title: String, subtitle: String)] {
        lock.withLock { _titles }
    }

    /// Every `setTaskCompleted` call. More than one means the double-completion guard failed.
    var completions: [Bool] {
        lock.withLock { _completions }
    }

    var hasExpirationHandler: Bool {
        lock.withLock { _expirationHandler != nil }
    }

    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { _expirationHandler = handler }
    }

    func updateTitle(_ title: String, subtitle: String) {
        lock.withLock { _titles.append((title: title, subtitle: subtitle)) }
    }

    func setTaskCompleted(success: Bool) {
        lock.withLock { _completions.append(success) }
    }

    /// Fires the handler the way the platform would when time runs out.
    func expire() {
        let handler = lock.withLock { _expirationHandler }
        handler?()
    }
}

// MARK: - MockContinuationScheduler

final class MockContinuationScheduler: ContinuationScheduler, @unchecked Sendable {
    struct Submission: Equatable {
        let identifier: String
        let title: String
        let subtitle: String
    }

    private let lock = NSLock()
    private var _registered: [String] = []
    private var _submissions: [Submission] = []

    var registrationSucceeds = true
    var submissionError: (any Error)?

    var registered: [String] {
        lock.withLock { _registered }
    }

    var submissions: [Submission] {
        lock.withLock { _submissions }
    }

    func register(
        identifier: String,
        launchHandler _: @escaping @Sendable (any ContinuationTask) -> Void
    ) -> Bool {
        lock.withLock { _registered.append(identifier) }
        return registrationSucceeds
    }

    func submit(identifier: String, title: String, subtitle: String) async throws {
        if let submissionError {
            throw submissionError
        }
        lock.withLock { _submissions.append(.init(identifier: identifier, title: title, subtitle: subtitle)) }
    }
}

// MARK: - StubContinuationRunner

/// A runner whose queue state the test sets directly.
actor StubContinuationRunner: BackgroundContinuationRunning {
    private(set) var snapshot: BackgroundWorkSnapshot
    private(set) var executionContexts: [ExecutionContext] = []
    private(set) var startCount = 0
    private(set) var shutdownCount = 0
    private(set) var lifecycleEvents: [String] = []
    private var blockShutdown = false
    private var shutdownGate: CheckedContinuation<Void, Never>?

    func holdShutdown() { blockShutdown = true }
    func releaseShutdown() {
        blockShutdown = false
        shutdownGate?.resume()
        shutdownGate = nil
    }

    func beginBackgroundContinuation() {}
    func endBackgroundContinuation() {}

    init(remaining: Int = 0, succeeded: Int = 0, failed: Int = 0, interrupted: Int = 0) {
        snapshot = BackgroundWorkSnapshot(remaining: remaining, succeeded: succeeded, failed: failed, interrupted: interrupted)
    }

    func setRemaining(_ remaining: Int, succeeded: Int = 0, failed: Int = 0, interrupted: Int = 0) {
        snapshot = BackgroundWorkSnapshot(remaining: remaining, succeeded: succeeded, failed: failed, interrupted: interrupted)
    }

    func setExecutionContext(_ newValue: ExecutionContext) async {
        executionContexts.append(newValue)
    }

    func start() async throws {
        startCount += 1
        lifecycleEvents.append("start")
    }

    @discardableResult
    func shutdown(timeout _: Duration?) async -> Bool {
        shutdownCount += 1
        lifecycleEvents.append("shutdown began")
        if blockShutdown {
            await withCheckedContinuation { shutdownGate = $0 }
        }
        lifecycleEvents.append("shutdown ended")
        return true
    }

    func backgroundWorkRemaining() async -> BackgroundWorkSnapshot {
        snapshot
    }
}

// MARK: - RecordingContinuationObserver

final class RecordingContinuationObserver: BackgroundContinuationObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var _skips: [ContinuationSkipReason] = []
    private var _outcomes: [ContinuationOutcome] = []
    private var _registrationFailures: [String] = []
    private var _submissionFailures: [String] = []

    var skips: [ContinuationSkipReason] {
        lock.withLock { _skips }
    }

    var outcomes: [ContinuationOutcome] {
        lock.withLock { _outcomes }
    }

    var registrationFailures: [String] {
        lock.withLock { _registrationFailures }
    }

    var submissionFailures: [String] {
        lock.withLock { _submissionFailures }
    }

    func continuationRegistrationFailed(identifier: String) {
        lock.withLock { _registrationFailures.append(identifier) }
    }

    func continuationSkipped(reason: ContinuationSkipReason) {
        lock.withLock { _skips.append(reason) }
    }

    func continuationSubmissionFailed(identifier: String, error _: any Error) {
        lock.withLock { _submissionFailures.append(identifier) }
    }

    func continuationCompleted(outcome: ContinuationOutcome) {
        lock.withLock { _outcomes.append(outcome) }
    }
}

struct ContinuationTestError: Error {}
