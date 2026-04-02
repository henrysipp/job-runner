//
//  TestSupport.swift
//  job-runnerTests
//
//  Created by Henry on 4/2/26.
//

import Foundation

func waitForBackgroundJobs() async throws {
    try await Task.sleep(for: .milliseconds(100))
}
