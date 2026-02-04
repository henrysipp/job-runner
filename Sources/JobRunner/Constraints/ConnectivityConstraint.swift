//
//  ConnectivityConstraint.swift
//  job-runner
//
//  Created by Henry on 2/4/26.
//

import Foundation

public struct ConnectivityConstraint: Codable, Sendable, Equatable {
    public enum Requirement: String, Codable, Sendable, Equatable {
        case any
        case wifi
        case cellular
        case notExpensive
    }

    public let requirement: Requirement

    public init(requirement: Requirement) {
        self.requirement = requirement
    }

    public static let any = ConnectivityConstraint(requirement: .any)
    public static let wifi = ConnectivityConstraint(requirement: .wifi)
    public static let cellular = ConnectivityConstraint(requirement: .cellular)
    public static let notExpensive = ConnectivityConstraint(requirement: .notExpensive)
}
