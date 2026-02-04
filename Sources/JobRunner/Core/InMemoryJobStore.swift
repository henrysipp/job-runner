//
//  InMemoryJobStore.swift
//  job-runner
//
//  Created by Henry on 2/3/26.
//

import Foundation

public actor InMemoryJobStore: JobStore {
    private var jobs: [UUID: SerializedJob] = [:]

    public init() {}

    public func save(_ job: SerializedJob) async throws {
        jobs[job.id] = job
    }

    public func load(id: UUID) async throws -> SerializedJob? {
        jobs[id]
    }

    public func loadAll() async throws -> [SerializedJob] {
        Array(jobs.values)
    }

    public func loadAll(status: JobStatus) async throws -> [SerializedJob] {
        jobs.values.filter { $0.status == status }
    }

    public func delete(id: UUID) async throws {
        jobs.removeValue(forKey: id)
    }
}
