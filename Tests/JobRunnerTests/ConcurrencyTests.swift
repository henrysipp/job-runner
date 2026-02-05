//
//  ConcurrencyTests.swift
//  job-runnerTests
//
//  Created by Henry on 2/5/26.
//

import Foundation
@testable import JobRunner
import Testing

// MARK: - Mock Adaptive Policy

actor MockAdaptiveConcurrencyPolicy: ConcurrencyPolicy {
    private var _limit: Int

    init(limit: Int) {
        _limit = limit
    }

    func maxConcurrent() async -> Int {
        _limit
    }

    func setLimit(_ newLimit: Int) {
        _limit = newLimit
    }
}

// MARK: - Test Barrier

actor TestBarrier {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrivedCount = 0

    func arrive() async {
        arrivedCount += 1
        await withCheckedContinuation { cont in
            waiting.append(cont)
        }
    }

    func getArrivedCount() -> Int {
        arrivedCount
    }

    func release(_ count: Int = 1) {
        for _ in 0..<count {
            guard !waiting.isEmpty else { return }
            let cont = waiting.removeFirst()
            cont.resume()
        }
    }

    func releaseAll() {
        while !waiting.isEmpty {
            waiting.removeFirst().resume()
        }
    }

    func reset() {
        arrivedCount = 0
    }
}

// MARK: - Test Job

struct BarrierJob: Job {
    typealias Context = TestBarrier
    let key: String

    func run(context: TestBarrier) async throws {
        await context.arrive()
    }
}

// MARK: - Test Suite

@Suite(.serialized)
struct ConcurrencyTests {

    @Test func respectsLimit() async throws {
        let barrier = TestBarrier()
        let policy = MockAdaptiveConcurrencyPolicy(limit: 2)
        let runner = JobRunner(context: barrier, concurrencyPolicy: policy)
        try await runner.register(BarrierJob.self)
        try await runner.start()

        // Enqueue 4 jobs
        for i in 1...4 {
            try await runner.enqueue(BarrierJob(key: "job-\(i)"), priority: .medium)
        }

        // Wait for jobs to arrive at barrier
        try await Task.sleep(for: .milliseconds(50))

        // Only 2 should be running (waiting at barrier)
        let arrived = await barrier.getArrivedCount()
        #expect(arrived == 2)

        // Release them and let next batch run
        await barrier.releaseAll()
        try await Task.sleep(for: .milliseconds(50))

        // Now 2 more should have arrived
        let arrivedAfter = await barrier.getArrivedCount()
        #expect(arrivedAfter == 4)

        await barrier.releaseAll()
    }

    @Test func scaleDownAffectsNextBatch() async throws {
        let barrier = TestBarrier()
        let policy = MockAdaptiveConcurrencyPolicy(limit: 3)
        let runner = JobRunner(context: barrier, concurrencyPolicy: policy)
        try await runner.register(BarrierJob.self)
        try await runner.start()

        // Enqueue 6 jobs
        for i in 1...6 {
            try await runner.enqueue(BarrierJob(key: "job-\(i)"), priority: .medium)
        }

        // Wait for first batch to arrive
        try await Task.sleep(for: .milliseconds(50))
        let firstBatch = await barrier.getArrivedCount()
        #expect(firstBatch == 3)

        // Scale down before releasing
        await policy.setLimit(1)

        // Release first batch
        await barrier.releaseAll()
        await barrier.reset()
        try await Task.sleep(for: .milliseconds(50))

        // Only 1 should start now
        let secondBatch = await barrier.getArrivedCount()
        #expect(secondBatch == 1)

        // Clean up
        await barrier.releaseAll()
        try await Task.sleep(for: .milliseconds(100))
        await barrier.releaseAll()
    }

    @Test func scaleUpAffectsNextBatch() async throws {
        let barrier = TestBarrier()
        let policy = MockAdaptiveConcurrencyPolicy(limit: 1)
        let runner = JobRunner(context: barrier, concurrencyPolicy: policy)
        try await runner.register(BarrierJob.self)
        try await runner.start()

        // Enqueue 4 jobs
        for i in 1...4 {
            try await runner.enqueue(BarrierJob(key: "job-\(i)"), priority: .medium)
        }

        // Wait for first job to arrive
        try await Task.sleep(for: .milliseconds(50))
        let firstBatch = await barrier.getArrivedCount()
        #expect(firstBatch == 1)

        // Scale up before releasing
        await policy.setLimit(3)

        // Release first job
        await barrier.releaseAll()
        await barrier.reset()
        try await Task.sleep(for: .milliseconds(50))

        // Now 3 should start
        let secondBatch = await barrier.getArrivedCount()
        #expect(secondBatch == 3)

        await barrier.releaseAll()
    }

    @Test func zeroLimitBlocksAll() async throws {
        let barrier = TestBarrier()
        let policy = MockAdaptiveConcurrencyPolicy(limit: 0)
        let runner = JobRunner(context: barrier, concurrencyPolicy: policy)
        try await runner.register(BarrierJob.self)
        try await runner.start()

        try await runner.enqueue(BarrierJob(key: "blocked"), priority: .medium)

        try await Task.sleep(for: .milliseconds(50))

        let arrived = await barrier.getArrivedCount()
        #expect(arrived == 0)

        // Scale up
        await policy.setLimit(1)
        // Need to trigger processQueue - enqueue another
        try await runner.enqueue(BarrierJob(key: "trigger"), priority: .medium)

        try await Task.sleep(for: .milliseconds(50))

        let arrivedAfter = await barrier.getArrivedCount()
        #expect(arrivedAfter == 1)

        await barrier.releaseAll()
        try await Task.sleep(for: .milliseconds(50))
        await barrier.releaseAll()
    }
}
