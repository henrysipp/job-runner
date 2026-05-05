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
    public var persistence: PersistenceConstraint

    public init(
        retry: RetryConstraint? = .default,
        connectivity: ConnectivityConstraint? = nil,
        persistence: PersistenceConstraint = .ephemeral
    ) {
        self.retry = retry
        self.connectivity = connectivity
        self.persistence = persistence
    }

    public static let `default` = JobConstraints()

    public static let noRetry = JobConstraints(retry: .noRetry, connectivity: nil)

    private enum CodingKeys: String, CodingKey {
        case retry
        case connectivity
        case persistence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        retry = try container.decodeIfPresent(RetryConstraint.self, forKey: .retry)
        connectivity = try container.decodeIfPresent(ConnectivityConstraint.self, forKey: .connectivity)
        persistence = try container.decodeIfPresent(PersistenceConstraint.self, forKey: .persistence) ?? .persisted
    }
}
