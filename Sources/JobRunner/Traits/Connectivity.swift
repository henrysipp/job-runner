//
//  Connectivity.swift
//  job-runner
//
//  Created by Henry on 2/4/26.
//

import Foundation

/// The network path a job needs before it may run. Evaluated by `NetworkMonitor`.
public struct Connectivity: Constraint, Equatable {
    public static let key: TraitKey = "connectivity"

    public enum Requirement: String, Codable, Sendable, Equatable {
        case any
        case wifi
        case cellular
        case notExpensive
    }

    public let requirement: Requirement

    public init(_ requirement: Requirement) {
        self.requirement = requirement
    }

    public static let any = Connectivity(.any)
    public static let wifi = Connectivity(.wifi)
    public static let cellular = Connectivity(.cellular)
    public static let notExpensive = Connectivity(.notExpensive)
}
