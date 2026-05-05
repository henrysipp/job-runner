//
//  FileSystemJobStore.swift
//  job-runner
//
//  Created by Henry on 5/5/26.
//

import Foundation
import os

/// A `JobStore` that persists each `SerializedJob` as a JSON file on disk, one file per job.
///
/// **Durability contract**
/// - Per-job atomic writes via `Data.write(options: .atomic)`. A crash mid-write leaves the
///   prior file intact, never a half-written one.
/// - No fsync, no cross-job transactions. Two saves are independently atomic but not jointly.
/// - Single-process. Multiple `FileSystemJobStore` instances pointing at the same directory
///   will clobber each other's writes.
///
/// **Hydration**
/// The async initializer reads every job file off disk before returning. A corrupt file is
/// logged and skipped so one bad payload does not take down the whole queue. Construction
/// time scales linearly with queue size — for very large queues, consider a different store.
///
/// **Persistence constraint**
/// Jobs whose `constraints.persistence` is `.ephemeral` are kept in the in-memory mirror but
/// never written to disk. They vanish on process restart — appropriate for queries and other
/// idempotent work that need not survive relaunch.
public actor FileSystemJobStore: JobStore {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger: Logger

    private var jobs: [UUID: SerializedJob] = [:]

    public init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        logger: Logger = Logger(subsystem: "JobRunner", category: "FileSystemJobStore")
    ) async throws {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.logger = logger

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        try hydrate()
    }

    public func save(_ job: SerializedJob) async throws {
        jobs[job.id] = job
        guard job.constraints.persistence == .persisted else { return }
        try ensureDirectoryExists()
        let data = try encoder.encode(job)
        try data.write(to: fileURL(for: job.id), options: .atomic)
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
        let url = fileURL(for: id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func count(status: JobStatus) async throws -> Int {
        jobs.values.filter { $0.status == status }.count
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func ensureDirectoryExists() throws {
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    private func hydrate() throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }

        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for url in urls where url.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: url)
                let job = try decoder.decode(SerializedJob.self, from: data)
                jobs[job.id] = job
            } catch {
                logger.error(
                    "Failed to decode job at \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }
}
