//
//  PersistenceConstraint.swift
//  job-runner
//
//  Created by Henry on 5/5/26.
//

import Foundation

public struct PersistenceConstraint: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, Equatable {
        case ephemeral
        case persisted
    }

    public let mode: Mode

    public init(mode: Mode) {
        self.mode = mode
    }

    public static let ephemeral = PersistenceConstraint(mode: .ephemeral)
    public static let persisted = PersistenceConstraint(mode: .persisted)
}
