//
//  JobConstraints.swift
//  job-runner
//
//  Created by Henry on 2/4/26.
//

import Foundation

public struct JobConstraints: Codable, Sendable, Equatable {
    public var retry: RetryConstraint?
    public var connectivity: ConnectivityConstraint?

    public init(
        retry: RetryConstraint? = .default,
        connectivity: ConnectivityConstraint? = nil
    ) {
        self.retry = retry
        self.connectivity = connectivity
    }

    public static let `default` = JobConstraints()

    public static let noRetry = JobConstraints(retry: .noRetry, connectivity: nil)
}
