//
//  Job.swift
//  job-runner
//
//  Created by Henry on 2/3/26.
//

import Foundation

public protocol Job<Context>: Codable, Sendable {
  associatedtype Context: Sendable
  func run(context: Context) async throws
}
