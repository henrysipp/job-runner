//
//  JobRunner.swift
//  job-runner
//
//  Created by Henry on 2/3/26.
//

import Foundation

public actor JobRunner<Context: Sendable>: JobRunnerProtocol {
  public let context: Context
  private let store: JobStore
  private let registry: JobRegistry<Context>
  private let maxConcurrent: Int
  private let maxAttempts: Int

  private var isStarted = false
  private var isStopped = false
  private var isProcessing = false

  public init(context: Context, store: JobStore = InMemoryJobStore(), maxConcurrent: Int = 4, maxAttempts: Int = 3) {
    self.context = context
    self.store = store
    self.registry = JobRegistry()
    self.maxConcurrent = maxConcurrent
    self.maxAttempts = maxAttempts
  }
  
  public func register<J: Job>(_ type: J.Type) async throws where J.Context == Context {
    guard !isStarted else {
      throw JobError.registrationAfterStart
    }
    registry.register(type)
  }
  
  public func start() async throws {
    guard !isStarted else { return }
    isStarted = true
    isStopped = false

    // Reset any jobs that were running when we last stopped back to pending
    let runningJobs = try await store.loadAll(status: .running)
    for var job in runningJobs {
      job.status = .pending
      try await store.save(job)
    }

    Task { await processQueue() }
  }

  public func stop() async {
    isStopped = true
  }

  public func enqueue<J: Job>(_ job: J, priority: Priority = .medium) async throws where J.Context == Context {
    guard isStarted else {
      throw JobError.notStarted
    }

    let (typeName, jobData) = try registry.encode(job)

    let serialized = SerializedJob(
      id: UUID(),
      typeName: typeName,
      priority: priority,
      originalCreatedAt: Date.now,
      lastAttemptedAt: nil,
      attempts: 0,
      status: .pending,
      jobData: jobData
    )

    try await store.save(serialized)

    Task { await processQueue() }
  }
  
  private func processQueue() async {
    guard !isStopped else { return }
    guard !isProcessing else { return }

    isProcessing = true
    defer { isProcessing = false }

    while !isStopped {
      let runningCount = (try? await store.loadAll(status: .running).count) ?? 0
      guard runningCount < maxConcurrent else { break }

      let pendingJobs = (try? await store.loadAll(status: .pending)) ?? []
      let sorted = sortedByPriority(pendingJobs)
      guard let next = sorted.first else { break }

      var running = next
      running.status = .running
      try? await store.save(running)

      Task {
        await executeJob(running)
      }
    }
  }
  
  private func executeJob(_ serialized: SerializedJob) async {
    do {
      let job = try registry.decode(serialized)
      try await job.run(context: context)

      try? await store.delete(id: serialized.id)
      await jobCompleted()

    } catch {
      await jobFailed(serialized, error: error)
    }
  }
  
  private func jobCompleted() async {
    Task { await processQueue() }
  }

  private func jobFailed(_ serialized: SerializedJob, error: Error) async {
    var updated = serialized
    updated.attempts += 1
    updated.lastAttemptedAt = Date.now

    if updated.attempts >= maxAttempts {
      updated.status = .permanentlyFailed
    } else {
      updated.status = .pending
    }

    try? await store.save(updated)
    Task { await processQueue() }
  }

  private func sortedByPriority(_ jobs: [SerializedJob]) -> [SerializedJob] {
    jobs.sorted { lhs, rhs in
      if lhs.priority != rhs.priority {
        return lhs.priority > rhs.priority
      }
      return lhs.originalCreatedAt < rhs.originalCreatedAt
    }
  }
}
