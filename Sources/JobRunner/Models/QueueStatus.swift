//
//  QueueStatus.swift
//  job-runner
//
//  Created by Henry on 2/4/26.
//

import Foundation

public struct QueueStatus: Sendable, Equatable {
    public let pending: Int
    public let running: Int
    public let failed: Int

    public init(pending: Int, running: Int, failed: Int) {
        self.pending = pending
        self.running = running
        self.failed = failed
    }

    public static let empty = QueueStatus(pending: 0, running: 0, failed: 0)

    public var total: Int {
        pending + running + failed
    }

    public var isIdle: Bool {
        pending == 0 && running == 0
    }
}
