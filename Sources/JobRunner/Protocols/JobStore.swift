//
//  JobStore.swift
//  job-runner
//
//  Created by Henry on 2/3/26.
//

import Foundation

public protocol JobStore: Sendable {
    func save(_ job: SerializedJob) async throws
    func load(id: UUID) async throws -> SerializedJob?
    func loadAll() async throws -> [SerializedJob]
    func loadAll(status: JobStatus) async throws -> [SerializedJob]
    func delete(id: UUID) async throws
    func count(status: JobStatus) async throws -> Int
}
