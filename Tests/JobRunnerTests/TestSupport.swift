//
//  TestSupport.swift
//  job-runnerTests
//
//  Created by Henry on 4/2/26.
//

import Foundation
@testable import JobRunner

func waitForBackgroundJobs() async throws {
    for _ in 0 ..< 50 {
        await Task.yield()
    }
}

func waitUntilIdle<Context: Sendable>(_ runner: JobRunner<Context>) async {
    let statuses = await runner.statusStream
    if await runner.currentStatus().isIdle {
        return
    }

    for await status in statuses {
        if status.isIdle {
            break
        }
    }
}
