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

private enum AsyncTestError: Error { case timeout }

func waitForCondition(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(3)
    while !(await condition()) {
        guard clock.now < deadline else { throw AsyncTestError.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}
