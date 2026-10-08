//
//  JobTrait.swift
//  job-runner
//
//  Created by Henry on 10/8/26.
//

import Foundation

public struct TraitKey: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

/// A declared property of a job. Each trait has exactly one interpreter: the runner or store
/// for policies, a registered evaluator for constraints.
public protocol JobTrait: Codable, Sendable {
    static var key: TraitKey { get }
}

/// A trait that gates whether a pending job may be picked up. Advisory: the answer is a
/// snapshot, and state can change between evaluation and `run`.
public protocol Constraint: JobTrait {}
