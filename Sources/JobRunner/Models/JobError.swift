//
//  JobError.swift
//  job-runner
//
//  Created by Henry on 2/3/26.
//

import Foundation

public enum JobError: Error, Equatable, Sendable {
  case unknownJobType(String)
  case jobNotFound(UUID)
  case notStarted
  case registrationAfterStart
}
