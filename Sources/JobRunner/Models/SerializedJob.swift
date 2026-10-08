//
//  SerializedJob.swift
//  job-runner
//
//  Created by Henry on 2/3/26.
//

import Foundation

public nonisolated struct SerializedJob: Codable, Sendable {
    public let id: UUID
    public let typeName: String
    public let priority: Priority
    public let traits: TraitSnapshot
    public let originalCreatedAt: Date
    public var lastAttemptedAt: Date?
    public var scheduledAt: Date?
    public var attempts: Int
    public var status: JobStatus
    public let jobData: Data

    public init(
        id: UUID,
        typeName: String,
        priority: Priority,
        traits: TraitSnapshot = TraitSnapshot(),
        originalCreatedAt: Date,
        lastAttemptedAt: Date? = nil,
        scheduledAt: Date? = nil,
        attempts: Int,
        status: JobStatus,
        jobData: Data
    ) {
        self.id = id
        self.typeName = typeName
        self.priority = priority
        self.traits = traits
        self.originalCreatedAt = originalCreatedAt
        self.lastAttemptedAt = lastAttemptedAt
        self.scheduledAt = scheduledAt
        self.attempts = attempts
        self.status = status
        self.jobData = jobData
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case typeName
        case priority
        case traits
        case originalCreatedAt
        case lastAttemptedAt
        case scheduledAt
        case attempts
        case status
        case jobData
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case constraints
    }

    /// Rows written before traits carry a `constraints` object instead. `traits` wins when both
    /// are present, and an invalid `traits` value is an error, never a fallback. A row with neither
    /// is an error too: the old decoder required `constraints`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        typeName = try container.decode(String.self, forKey: .typeName)
        priority = try container.decode(Priority.self, forKey: .priority)
        if container.contains(.traits) {
            traits = try container.decode(TraitSnapshot.self, forKey: .traits)
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            traits = try legacy.decode(LegacyJobConstraints.self, forKey: .constraints).snapshot()
        }
        originalCreatedAt = try container.decode(Date.self, forKey: .originalCreatedAt)
        lastAttemptedAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptedAt)
        scheduledAt = try container.decodeIfPresent(Date.self, forKey: .scheduledAt)
        attempts = try container.decode(Int.self, forKey: .attempts)
        status = try container.decode(JobStatus.self, forKey: .status)
        jobData = try container.decode(Data.self, forKey: .jobData)
    }
}
