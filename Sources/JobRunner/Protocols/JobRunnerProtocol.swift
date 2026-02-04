//
//  JobRunnerProtocol.swift
//  job-runner
//
//  Created by Henry on 2/3/26.
//

import Foundation

public protocol JobRunnerProtocol<Context>: Actor {
  associatedtype Context: Sendable
  func register<J: Job>(_ type: J.Type) async throws where J.Context == Context
  func start() async throws
  func stop() async
  func enqueue<J: Job>(_ job: J, priority: Priority) async throws where J.Context == Context
}
