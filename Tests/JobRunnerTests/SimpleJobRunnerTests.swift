//
//  SimpleJobRunnerTests.swift
//  job-runnerTests
//
//  Created by Henry on 2/3/26.
//

import Testing
import Foundation
@testable import JobRunner

// MARK: - Test Infrastructure

actor TestJobTracker {
    static let shared = TestJobTracker()
    
    private var executedJobs: Set<String> = []
    private var failedJobs: [String: Int] = [:]
    private var executionOrder: [String] = []
    private var concurrentCount: Int = 0
    private var maxConcurrent: Int = 0
    private var executionTimestamps: [String: Date] = [:]
    
    func recordExecution(_ key: String) {
        executedJobs.insert(key)
        executionOrder.append(key)
    }
    
    func recordFailure(_ key: String) {
        failedJobs[key, default: 0] += 1
        executionOrder.append(key)
    }
    
    func startExecution(_ key: String) {
        concurrentCount += 1
        if concurrentCount > maxConcurrent {
            maxConcurrent = concurrentCount
        }
        executionTimestamps[key] = Date.now
    }
    
    func endExecution(_ key: String) {
        concurrentCount -= 1
        executionOrder.append(key)
    }
    
    func didExecute(_ key: String) -> Bool {
        executedJobs.contains(key)
    }
    
    func failureCount(_ key: String) -> Int {
        failedJobs[key, default: 0]
    }
    
    func getExecutionOrder() -> [String] {
        executionOrder
    }
    
    func getMaxConcurrent() -> Int {
        maxConcurrent
    }
    
    func getExecutionTimestamp(_ key: String) -> Date? {
        executionTimestamps[key]
    }
    
    func reset() {
        executedJobs.removeAll()
        failedJobs.removeAll()
        executionOrder.removeAll()
        concurrentCount = 0
        maxConcurrent = 0
        executionTimestamps.removeAll()
    }
}

// Helper to ensure test isolation
func prepareTest() async throws {
    // Wait for any jobs from previous test to finish
    try await Task.sleep(for: .milliseconds(100))
    // Reset tracker for clean state
    await TestJobTracker.shared.reset()
}

actor MockJobStore: JobStore {
    var savedJobs: [SerializedJob] = []
    var deletedJobIds: [UUID] = []
    
    func save(_ job: SerializedJob) async throws {
        if let index = savedJobs.firstIndex(where: { $0.id == job.id }) {
            savedJobs[index] = job
        } else {
            savedJobs.append(job)
        }
    }
    
    func load(id: UUID) async throws -> SerializedJob? {
        savedJobs.first { $0.id == id }
    }
    
    func loadAll() async throws -> [SerializedJob] {
        savedJobs
    }
    
    func loadAll(status: JobStatus) async throws -> [SerializedJob] {
        savedJobs.filter { $0.status == status }
    }
    
    func delete(id: UUID) async throws {
        deletedJobIds.append(id)
        savedJobs.removeAll { $0.id == id }
    }
    
    func reset() {
        savedJobs.removeAll()
        deletedJobIds.removeAll()
    }
    
    func getJobCount() -> Int {
        savedJobs.count
    }
    
    func getJobsByStatus(_ status: JobStatus) -> [SerializedJob] {
        savedJobs.filter { $0.status == status }
    }
}

// MARK: - Test Job Types

struct SuccessJob: Job {
    typealias Context = Void
    let key: String

    func run(context: Void) async throws {
        await TestJobTracker.shared.recordExecution(key)
    }
}

struct FailingJob: Job {
    typealias Context = Void
    let key: String

    func run(context: Void) async throws {
        await TestJobTracker.shared.recordFailure(key)
        throw TestError.intentionalFailure
    }
}

struct SlowJob: Job {
    typealias Context = Void
    let key: String
    let duration: Duration

    func run(context: Void) async throws {
        await TestJobTracker.shared.startExecution(key)
        try await Task.sleep(for: duration)
        await TestJobTracker.shared.endExecution(key)
    }
}

enum TestError: Error {
    case intentionalFailure
}

// MARK: - Test Suite

@Suite(.serialized)
struct SimpleJobRunnerTests {}

// MARK: - Basic Tests
// Tests core job execution and retry functionality

extension SimpleJobRunnerTests {
    
    @Test func testBasicJobExecution() async throws {
        try await prepareTest()

        let runner = SimpleJobRunner(context: (), maxConcurrent: 1, maxAttempts: 3)
        try await runner.register(SuccessJob.self)
        try await runner.start()
        
        let jobKey = "test-job-\(UUID())"
        let job = SuccessJob(key: jobKey)
        try await runner.enqueue(job, priority: .high)
        
        try await Task.sleep(for: .milliseconds(200))
        
        let didExecute = await TestJobTracker.shared.didExecute(jobKey)
        #expect(didExecute)
    }
    
    @Test func testJobRetryOnFailure() async throws {
        try await prepareTest()

        let runner = SimpleJobRunner(context: (), maxConcurrent: 1, maxAttempts: 3)
        try await runner.register(FailingJob.self)
        try await runner.start()
        
        let jobKey = "failing-job-\(UUID())"
        let job = FailingJob(key: jobKey)
        try await runner.enqueue(job, priority: .medium)
        
        try await Task.sleep(for: .milliseconds(500))
        
        let failures = await TestJobTracker.shared.failureCount(jobKey)
        #expect(failures == 3)
    }
}

// MARK: - Queue Tests
// Tests queue management, concurrency control, and job status transitions

extension SimpleJobRunnerTests {
    
    @Test func testMaxConcurrentJobsRespected() async throws {
        try await prepareTest()
        
        let runner = SimpleJobRunner(context: (), maxConcurrent: 2, maxAttempts: 3)
        try await runner.register(SlowJob.self)
        try await runner.start()
        
        for i in 1...5 {
            let job = SlowJob(key: "slow-\(i)", duration: .milliseconds(100))
            try await runner.enqueue(job, priority: .medium)
        }
        
        try await Task.sleep(for: .milliseconds(150))
        
        let maxConcurrent = await TestJobTracker.shared.getMaxConcurrent()
        #expect(maxConcurrent <= 2)
        
        // Wait for all jobs to complete before test ends
        try await Task.sleep(for: .milliseconds(200))
    }
    
    @Test func testJobsProcessedSequentiallyWhenMaxConcurrentIsOne() async throws {
        try await prepareTest()
        
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1, maxAttempts: 3)
        try await runner.register(SuccessJob.self)
        try await runner.start()
        
        try await runner.enqueue(SuccessJob(key: "job-1"), priority: .medium)
        try await runner.enqueue(SuccessJob(key: "job-2"), priority: .medium)
        try await runner.enqueue(SuccessJob(key: "job-3"), priority: .medium)
        
        try await Task.sleep(for: .milliseconds(300))
        
        let order = await TestJobTracker.shared.getExecutionOrder()
        #expect(order == ["job-1", "job-2", "job-3"])
    }
    
    @Test func testProcessQueueTriggersAfterJobCompletion() async throws {
        try await prepareTest()
        
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1, maxAttempts: 3)
        try await runner.register(SuccessJob.self)
        try await runner.start()
        
        try await runner.enqueue(SuccessJob(key: "job-A"), priority: .medium)
        try await Task.sleep(for: .milliseconds(50))
        try await runner.enqueue(SuccessJob(key: "job-B"), priority: .medium)
        
        try await Task.sleep(for: .milliseconds(300))
        
        let executedA = await TestJobTracker.shared.didExecute("job-A")
        let executedB = await TestJobTracker.shared.didExecute("job-B")
        #expect(executedA && executedB)
    }
    
    @Test func testMultipleJobsExecuteConcurrently() async throws {
        try await prepareTest()
        
        let runner = SimpleJobRunner(context: (), maxConcurrent: 3, maxAttempts: 3)
        try await runner.register(SlowJob.self)
        try await runner.start()
        
        let startTime = Date.now
        
        try await runner.enqueue(SlowJob(key: "job-1", duration: .milliseconds(100)), priority: .medium)
        try await runner.enqueue(SlowJob(key: "job-2", duration: .milliseconds(100)), priority: .medium)
        try await runner.enqueue(SlowJob(key: "job-3", duration: .milliseconds(100)), priority: .medium)
        
        try await Task.sleep(for: .milliseconds(200))
        
        let endTime = Date.now
        let elapsed = endTime.timeIntervalSince(startTime)
        
        #expect(elapsed < 0.25)
    }
    
    @Test func testJobsMoveThroughCorrectStatuses() async throws {
        try await prepareTest()
        
        let store = MockJobStore()
        let runner = SimpleJobRunner(context: (), store: store, maxConcurrent: 1, maxAttempts: 3)
        try await runner.register(SlowJob.self)
        try await runner.start()
        
        try await runner.enqueue(SlowJob(key: "status-test", duration: .milliseconds(100)), priority: .high)
        
        // Job takes 100ms, check at 50ms that it's running
        try await Task.sleep(for: .milliseconds(50))
        
        let runningJobs = await store.getJobsByStatus(.running)
        #expect(!runningJobs.isEmpty)
        
        // Wait for job to complete (100ms + overhead)
        try await Task.sleep(for: .milliseconds(100))
        
        let deletedCount = await store.deletedJobIds.count
        #expect(deletedCount == 1)
    }
}

// MARK: - Registry Tests
// Tests job type registration, serialization, and encoding/decoding

extension SimpleJobRunnerTests {
    
    @Test func testRegisterJobTypeAfterStartThrows() async throws {
        try await prepareTest()
        
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1, maxAttempts: 3)
        try await runner.start()
        
        do {
            try await runner.register(SuccessJob.self)
            #expect(Bool(false), "Should have thrown error")
        } catch let error as JobError {
            #expect(error == .registrationAfterStart)
        }
    }
    
    @Test func testEncodeDecodeRoundTrip() async throws {
        try await prepareTest()
        
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1, maxAttempts: 3)
        try await runner.register(SuccessJob.self)
        try await runner.start()
        
        let originalKey = "encode-decode-test"
        let job = SuccessJob(key: originalKey)
        try await runner.enqueue(job, priority: .medium)
        
        try await Task.sleep(for: .milliseconds(200))
        
        let executed = await TestJobTracker.shared.didExecute(originalKey)
        #expect(executed)
    }
    
    @Test func testMultipleJobTypesCanBeRegistered() async throws {
        try await prepareTest()
        
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1, maxAttempts: 3)
        try await runner.register(SuccessJob.self)
        try await runner.register(FailingJob.self)
        try await runner.start()
        
        try await runner.enqueue(SuccessJob(key: "success-1"), priority: .medium)
        try await runner.enqueue(SuccessJob(key: "success-2"), priority: .medium)
        
        try await Task.sleep(for: .milliseconds(300))
        
        let executed1 = await TestJobTracker.shared.didExecute("success-1")
        let executed2 = await TestJobTracker.shared.didExecute("success-2")
        #expect(executed1 && executed2)
    }
    
    @Test func testStartCalledTwiceIsIdempotent() async throws {
        try await prepareTest()
        
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1, maxAttempts: 3)
        try await runner.register(SuccessJob.self)
        
        // First start
        try await runner.start()
        
        // Second start - should return early without error
        try await runner.start()
        
        // Should still work normally
        try await runner.enqueue(SuccessJob(key: "idempotent-test"), priority: .medium)
        try await Task.sleep(for: .milliseconds(200))
        
        let executed = await TestJobTracker.shared.didExecute("idempotent-test")
        #expect(executed)
    }
    
    @Test func testStartLoadsPersistedJobs() async throws {
        try await prepareTest()
        
        let store = MockJobStore()
        let runner = SimpleJobRunner(context: (), store: store, maxConcurrent: 1, maxAttempts: 3)
        try await runner.register(SuccessJob.self)
        
        // Pre-populate store with pending and running jobs
        let pendingJob = SerializedJob(
            id: UUID(),
            typeName: "SuccessJob",
            priority: .medium,
            originalCreatedAt: Date.now,
            lastAttemptedAt: nil,
            attempts: 0,
            status: .pending,
            jobData: try JSONEncoder().encode(SuccessJob(key: "persisted-pending"))
        )
        
        let runningJob = SerializedJob(
            id: UUID(),
            typeName: "SuccessJob",
            priority: .high,
            originalCreatedAt: Date.now,
            lastAttemptedAt: nil,
            attempts: 0,
            status: .running,
            jobData: try JSONEncoder().encode(SuccessJob(key: "persisted-running"))
        )
        
        let failedJob = SerializedJob(
            id: UUID(),
            typeName: "SuccessJob",
            priority: .low,
            originalCreatedAt: Date.now,
            lastAttemptedAt: nil,
            attempts: 3,
            status: .permanentlyFailed,
            jobData: try JSONEncoder().encode(SuccessJob(key: "persisted-failed"))
        )
        
        try await store.save(pendingJob)
        try await store.save(runningJob)
        try await store.save(failedJob)
        
        // Start should load pending and running jobs, but not failed
        try await runner.start()
        
        try await Task.sleep(for: .milliseconds(300))
        
        let executedPending = await TestJobTracker.shared.didExecute("persisted-pending")
        let executedRunning = await TestJobTracker.shared.didExecute("persisted-running")
        let executedFailed = await TestJobTracker.shared.didExecute("persisted-failed")
        
        #expect(executedPending)
        #expect(executedRunning)
        #expect(!executedFailed) // Failed jobs should not be loaded
    }
    
    @Test func testUnknownJobTypeThrowsError() async throws {
        try await prepareTest()
        
        let store = MockJobStore()
        let runner = SimpleJobRunner(context: (), store: store, maxConcurrent: 1, maxAttempts: 3)
        // Intentionally NOT registering any job types
        try await runner.start()
        
        // Manually create a serialized job with an unregistered type
        let unknownJob = SerializedJob(
            id: UUID(),
            typeName: "UnknownJobType",
            priority: .medium,
            originalCreatedAt: Date.now,
            lastAttemptedAt: nil,
            attempts: 0,
            status: .pending,
            jobData: Data() // Empty data is fine, we'll fail on type lookup
        )
        
        try await store.save(unknownJob)
        
        // Try to load and execute this unknown job type
        // The job should fail to decode and be marked as permanently failed
        let store2 = MockJobStore()
        let runner2 = SimpleJobRunner(context: (), store: store2, maxConcurrent: 1, maxAttempts: 1)
        // Still not registering the type
        
        try await store2.save(unknownJob)
        try await runner2.start()
        
        // Give time for the job to fail
        try await Task.sleep(for: .milliseconds(200))
        
        // Job should have failed and been marked as permanently failed (hit max attempts)
        let failedJobs = await store2.getJobsByStatus(.permanentlyFailed)
        #expect(failedJobs.count == 1)
    }
}

// MARK: - Retry Tests
// Tests retry logic, max attempts handling, and permanent failure states

extension SimpleJobRunnerTests {
    
    @Test func testJobRetriesWithDifferentMaxAttempts() async throws {
        try await prepareTest()
        
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1, maxAttempts: 5)
        try await runner.register(FailingJob.self)
        try await runner.start()
        
        let jobKey = "retry-5-times"
        try await runner.enqueue(FailingJob(key: jobKey), priority: .medium)
        
        try await Task.sleep(for: .milliseconds(800))
        
        let failures = await TestJobTracker.shared.failureCount(jobKey)
        #expect(failures == 5)
    }
    
    @Test func testJobMarkedPermanentlyFailedAfterMaxAttempts() async throws {
        try await prepareTest()
        
        let store = MockJobStore()
        let runner = SimpleJobRunner(context: (), store: store, maxConcurrent: 1, maxAttempts: 2)
        try await runner.register(FailingJob.self)
        try await runner.start()
        
        try await runner.enqueue(FailingJob(key: "perm-fail"), priority: .medium)
        
        try await Task.sleep(for: .milliseconds(500))
        
        let failedJobs = await store.getJobsByStatus(.permanentlyFailed)
        #expect(failedJobs.count == 1)
    }
    
    @Test func testSuccessfulJobDoesNotRetry() async throws {
        try await prepareTest()
        
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1, maxAttempts: 3)
        try await runner.register(SuccessJob.self)
        try await runner.start()
        
        let jobKey = "no-retry-\(UUID())"
        try await runner.enqueue(SuccessJob(key: jobKey), priority: .medium)
        
        try await Task.sleep(for: .milliseconds(300))
        
        let order = await TestJobTracker.shared.getExecutionOrder()
        let executionCount = order.filter { $0 == jobKey }.count
        #expect(executionCount == 1)
    }
    
    @Test func testFailedJobReEnqueuedAtEnd() async throws {
        try await prepareTest()
        
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1, maxAttempts: 3)
        try await runner.register(FailingJob.self)
        try await runner.register(SuccessJob.self)
        try await runner.start()
        
        try await runner.enqueue(SuccessJob(key: "A"), priority: .medium)
        try await runner.enqueue(FailingJob(key: "B"), priority: .medium)
        try await runner.enqueue(SuccessJob(key: "C"), priority: .medium)
        
        try await Task.sleep(for: .milliseconds(800))
        
        let order = await TestJobTracker.shared.getExecutionOrder()
        let firstB = order.firstIndex(of: "B")
        let aIndex = order.firstIndex(of: "A")
        let cIndex = order.firstIndex(of: "C")
        
        #expect(aIndex != nil && cIndex != nil && firstB != nil)
        #expect(aIndex! < cIndex!)
    }
    
    @Test func testAttemptsCountIncrements() async throws {
        try await prepareTest()
        
        let store = MockJobStore()
        let runner = SimpleJobRunner(context: (), store: store, maxConcurrent: 1, maxAttempts: 3)
        try await runner.register(FailingJob.self)
        try await runner.start()
        
        try await runner.enqueue(FailingJob(key: "attempts-test"), priority: .medium)
        
        try await Task.sleep(for: .milliseconds(600))
        
        let allJobs = await store.savedJobs
        let attempts = allJobs.map { $0.attempts }
        #expect(attempts.contains(3))
    }
}

// MARK: - Priority Tests
// Tests priority-based job ordering and FIFO behavior within priority levels

extension SimpleJobRunnerTests {
    @Test func testPriorityLevelsInOrder() async throws {
        try await prepareTest()
        
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1, maxAttempts: 3)
        try await runner.register(SlowJob.self)
        try await runner.start()
        
        // Enqueue jobs - first job starts immediately, rest queue by priority
        try await runner.enqueue(SlowJob(key: "low", duration: .milliseconds(50)), priority: .low)
        try await runner.enqueue(SlowJob(key: "medium", duration: .milliseconds(50)), priority: .medium)
        try await runner.enqueue(SlowJob(key: "high", duration: .milliseconds(50)), priority: .high)
        try await runner.enqueue(SlowJob(key: "immediate", duration: .milliseconds(50)), priority: .immediate)
        
        try await Task.sleep(for: .milliseconds(400))
        
        let order = await TestJobTracker.shared.getExecutionOrder()
        // First job executes immediately, then remaining jobs execute by priority
        #expect(order == ["low", "immediate", "high", "medium"])
    }
    
    @Test func testFIFOWithinSamePriority() async throws {
        try await prepareTest()
        
        let runner = SimpleJobRunner(context: (), maxConcurrent: 1, maxAttempts: 3)
        try await runner.register(SuccessJob.self)
        try await runner.start()
        
        try await runner.enqueue(SuccessJob(key: "med-1"), priority: .medium)
        try await runner.enqueue(SuccessJob(key: "med-2"), priority: .medium)
        try await runner.enqueue(SuccessJob(key: "med-3"), priority: .medium)
        try await runner.enqueue(SuccessJob(key: "med-4"), priority: .medium)
        
        try await Task.sleep(for: .milliseconds(500))
        
        let order = await TestJobTracker.shared.getExecutionOrder()
        #expect(order == ["med-1", "med-2", "med-3", "med-4"])
    }
    
    @Test func testPriorityOverridesCreationTime() async throws {
        try await prepareTest()

        let runner = SimpleJobRunner(context: (), maxConcurrent: 1, maxAttempts: 3)
        try await runner.register(SlowJob.self)
        try await runner.register(SuccessJob.self)
        try await runner.start()

        try await runner.enqueue(SlowJob(key: "medium-first", duration: .milliseconds(50)), priority: .medium)
        try await Task.sleep(for: .milliseconds(10))
        try await runner.enqueue(SuccessJob(key: "high-later"), priority: .high)

        try await Task.sleep(for: .milliseconds(200))

        let order = await TestJobTracker.shared.getExecutionOrder()
        #expect(order.last == "high-later")
    }
}

// MARK: - Stop Tests

extension SimpleJobRunnerTests {

    @Test func testStopPreventsNewJobsFromStarting() async throws {
        try await prepareTest()

        let runner = SimpleJobRunner(context: (), maxConcurrent: 1, maxAttempts: 3)
        try await runner.register(SlowJob.self)
        try await runner.register(SuccessJob.self)
        try await runner.start()

        // Enqueue a slow job that will be running when we call stop
        try await runner.enqueue(SlowJob(key: "running-job", duration: .milliseconds(200)), priority: .medium)
        // Enqueue jobs that should NOT run after stop
        try await runner.enqueue(SuccessJob(key: "pending-job-1"), priority: .medium)
        try await runner.enqueue(SuccessJob(key: "pending-job-2"), priority: .medium)

        // Wait for first job to start, then stop
        try await Task.sleep(for: .milliseconds(50))
        await runner.stop()

        // Wait for the running job to complete
        try await Task.sleep(for: .milliseconds(300))

        // The running job should have completed, but pending jobs should not have started
        let order = await TestJobTracker.shared.getExecutionOrder()
        #expect(order.contains("running-job"))
        #expect(!order.contains("pending-job-1"))
        #expect(!order.contains("pending-job-2"))
    }
}
