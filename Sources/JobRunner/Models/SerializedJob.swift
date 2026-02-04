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
  public let originalCreatedAt: Date
  public var lastAttemptedAt: Date?
  public var attempts: Int
  public var status: JobStatus
  public let jobData: Data
  
  public init(
    id: UUID,
    typeName: String,
    priority: Priority,
    originalCreatedAt: Date,
    lastAttemptedAt: Date? = nil,
    attempts: Int,
    status: JobStatus,
    jobData: Data
  ) {
    self.id = id
    self.typeName = typeName
    self.priority = priority
    self.originalCreatedAt = originalCreatedAt
    self.lastAttemptedAt = lastAttemptedAt
    self.attempts = attempts
    self.status = status
    self.jobData = jobData
  }
}
