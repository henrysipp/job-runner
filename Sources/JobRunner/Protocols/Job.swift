//
//  Job.swift
//  job-runner
//
//  Created by Henry on 2/3/26.
//

import Foundation

public protocol Job<Context>: Codable, Sendable {
    associatedtype Context: Sendable
    var constraints: JobConstraints { get }
    nonisolated func run(context: Context) async throws
}

public extension Job {
    var constraints: JobConstraints { .default }
}
