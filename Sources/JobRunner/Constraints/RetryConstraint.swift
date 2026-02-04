//
//  RetryConstraint.swift
//  job-runner
//
//  Created by Henry on 2/4/26.
//

import Foundation

public struct RetryConstraint: Codable, Sendable, Equatable {
    public let maxAttempts: Int
    public let strategy: RetryStrategy

    public init(maxAttempts: Int, strategy: RetryStrategy) {
        self.maxAttempts = maxAttempts
        self.strategy = strategy
    }

    public static let `default` = RetryConstraint(
        maxAttempts: 3,
        strategy: .exponential(base: 2, maxDelay: 300)
    )

    public static let noRetry = RetryConstraint(
        maxAttempts: 1,
        strategy: .immediate
    )

    public func delay(forAttempt attempt: Int) -> TimeInterval? {
        strategy.delay(forAttempt: attempt)
    }
}

public enum RetryStrategy: Sendable, Codable, Equatable {
    case immediate
    case fixed(delay: TimeInterval)
    case exponential(base: TimeInterval, maxDelay: TimeInterval)
    case linear(step: TimeInterval)

    public func delay(forAttempt attempt: Int) -> TimeInterval? {
        switch self {
        case .immediate:
            return nil
        case let .fixed(delay):
            return delay
        case let .exponential(base, maxDelay):
            let delay = pow(base, Double(attempt))
            return min(delay, maxDelay)
        case let .linear(step):
            return step * Double(attempt)
        }
    }
}
