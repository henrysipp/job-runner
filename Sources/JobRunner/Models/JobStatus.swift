//
//  JobStatus.swift
//  job-runner
//
//  Created by Henry on 2/3/26.
//

import Foundation

public enum JobStatus: String, Codable, Sendable {
    case pending
    case running
    case permanentlyFailed
}
