//
//  MockJobRunner.swift
//  job-runner
//
//  Created by Henry on 2/3/26.
//

import Foundation

public actor MockJobRunner<Context: Sendable>: JobRunnerProtocol {
  public let context: Context
  public var registeredTypes: [String] = []
  private var enqueuedJobsInternal: [(job: Any, priority: Priority)] = []
  public var startCallCount: Int = 0
  public var isStarted: Bool = false
  
  private var shouldThrowOnRegister: Error?
  private var shouldThrowOnStart: Error?
  private var shouldThrowOnEnqueue: Error?
  
  public init(context: Context) {
    self.context = context
  }
  
  public func register<J: Job>(_ type: J.Type) async throws where J.Context == Context {
    if let error = shouldThrowOnRegister {
      throw error
    }
    let typeName = String(describing: type)
    registeredTypes.append(typeName)
  }
  
  public func start() async throws {
    if let error = shouldThrowOnStart {
      throw error
    }
    startCallCount += 1
    isStarted = true
  }

  public func stop() async {
    isStarted = false
  }

  public func enqueue<J: Job>(_ job: J, priority: Priority = .medium) async throws where J.Context == Context {
    if let error = shouldThrowOnEnqueue {
      throw error
    }
    enqueuedJobsInternal.append((job: job, priority: priority))
  }
  
  public func setErrorOnRegister(_ error: Error?) {
    shouldThrowOnRegister = error
  }
  
  public func setErrorOnStart(_ error: Error?) {
    shouldThrowOnStart = error
  }
  
  public func setErrorOnEnqueue(_ error: Error?) {
    shouldThrowOnEnqueue = error
  }
  
  public func reset() {
    registeredTypes.removeAll()
    enqueuedJobsInternal.removeAll()
    startCallCount = 0
    isStarted = false
    shouldThrowOnRegister = nil
    shouldThrowOnStart = nil
    shouldThrowOnEnqueue = nil
  }
  
  public func getEnqueuedJobCount() -> Int {
    enqueuedJobsInternal.count
  }
  
  public func getEnqueuedJobs<J: Job>(ofType type: J.Type) -> [J] where J.Context == Context {
    enqueuedJobsInternal.compactMap { $0.job as? J }
  }
  
  public func getAllEnqueuedJobs() -> [(priority: Priority, typeName: String)] {
    enqueuedJobsInternal.map { (priority: $0.priority, typeName: String(describing: type(of: $0.job))) }
  }
}
