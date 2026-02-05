//
//  ConcurrencyPolicy.swift
//  job-runner
//
//  Created by Henry on 2/5/26.
//

public protocol ConcurrencyPolicy: Sendable {
    func maxConcurrent() async -> Int
}

public struct FixedConcurrencyPolicy: ConcurrencyPolicy {
    public let limit: Int

    public init(limit: Int) {
        self.limit = limit
    }

    public func maxConcurrent() async -> Int {
        limit
    }
}
