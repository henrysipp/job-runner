//
//  Persistence.swift
//  job-runner
//
//  Created by Henry on 5/5/26.
//

import Foundation

/// Whether a job survives process death. Interpreted by the store, not the runner. A job that
/// declares no `Persistence` is ephemeral.
public struct Persistence: JobTrait, Equatable {
    public static let key: TraitKey = "persistence"

    public enum Mode: String, Codable, Sendable, Equatable {
        case ephemeral
        case persisted
    }

    public let mode: Mode

    public init(mode: Mode) {
        self.mode = mode
    }

    public static let ephemeral = Persistence(mode: .ephemeral)
    public static let persisted = Persistence(mode: .persisted)
}
