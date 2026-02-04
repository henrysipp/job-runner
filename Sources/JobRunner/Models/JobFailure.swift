//
//  JobFailure.swift
//  job-runner
//
//  Created by Henry on 2/4/26.
//

import Foundation

public enum JobFailure: Error, Sendable {
    /// Indicates a transient failure that should be retried according to constraints
    case transient(any Error & Sendable)

    /// Indicates a permanent failure that should not be retried
    case permanent(any Error & Sendable)

    public var underlyingError: any Error & Sendable {
        switch self {
        case .transient(let error), .permanent(let error):
            return error
        }
    }
}
