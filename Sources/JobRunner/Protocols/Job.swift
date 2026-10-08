//
//  Job.swift
//  job-runner
//
//  Created by Henry on 2/3/26.
//

import Foundation

public protocol Job<Context>: Codable, Sendable {
    associatedtype Context: Sendable
    var traits: JobTraits { get }
    nonisolated func run(context: Context) async throws
    nonisolated func rollback(context: Context, error: any Error) async
}

public extension Job {
    var traits: JobTraits {
        []
    }

    nonisolated func rollback(context: Context, error: any Error) async { }
}
