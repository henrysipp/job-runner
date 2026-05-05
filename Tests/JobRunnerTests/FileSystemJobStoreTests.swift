//
//  FileSystemJobStoreTests.swift
//  job-runnerTests
//
//  Created by Henry on 5/5/26.
//

import Foundation
@testable import JobRunner
import Testing

@Suite("FileSystemJobStore")
struct FileSystemJobStoreTests {
    private static func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSystemJobStoreTests-\(UUID().uuidString)")
        return url
    }

    private static func makeJob(
        status: JobStatus = .pending,
        persistence: PersistenceConstraint = .persisted
    ) -> SerializedJob {
        SerializedJob(
            id: UUID(),
            typeName: "TestJob",
            priority: .medium,
            constraints: JobConstraints(persistence: persistence),
            originalCreatedAt: Date(),
            attempts: 0,
            status: status,
            jobData: Data("{}".utf8)
        )
    }

    @Test("Empty directory yields empty store")
    func emptyDirectoryYieldsEmptyStore() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try await FileSystemJobStore(directoryURL: dir)
        let all = try await store.loadAll()
        #expect(all.isEmpty)
    }

    @Test("Save creates directory if missing")
    func saveCreatesDirectoryIfMissing() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try await FileSystemJobStore(directoryURL: dir)
        let job = Self.makeJob()
        try await store.save(job)

        #expect(FileManager.default.fileExists(atPath: dir.path))
        let loaded = try await store.load(id: job.id)
        #expect(loaded?.id == job.id)
    }

    @Test("Persisted job survives reopen")
    func persistedJobSurvivesReopen() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let job = Self.makeJob()

        let first = try await FileSystemJobStore(directoryURL: dir)
        try await first.save(job)

        let second = try await FileSystemJobStore(directoryURL: dir)
        let loaded = try await second.load(id: job.id)
        #expect(loaded?.id == job.id)
    }

    @Test("Ephemeral job is not written to disk")
    func ephemeralJobIsNotWrittenToDisk() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let job = Self.makeJob(persistence: .ephemeral)

        let first = try await FileSystemJobStore(directoryURL: dir)
        try await first.save(job)

        let inMemory = try await first.load(id: job.id)
        #expect(inMemory?.id == job.id)

        let second = try await FileSystemJobStore(directoryURL: dir)
        let afterReopen = try await second.load(id: job.id)
        #expect(afterReopen == nil)
    }

    @Test("Mixed ephemeral and persisted jobs hydrate only persisted ones")
    func mixedJobsHydrateOnlyPersisted() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let persistedJob = Self.makeJob(persistence: .persisted)
        let ephemeralJob = Self.makeJob(persistence: .ephemeral)

        let first = try await FileSystemJobStore(directoryURL: dir)
        try await first.save(persistedJob)
        try await first.save(ephemeralJob)

        let second = try await FileSystemJobStore(directoryURL: dir)
        let all = try await second.loadAll()
        #expect(all.count == 1)
        #expect(all.first?.id == persistedJob.id)
    }

    @Test("Delete removes the file")
    func deleteRemovesTheFile() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try await FileSystemJobStore(directoryURL: dir)
        let job = Self.makeJob()
        try await store.save(job)
        try await store.delete(id: job.id)

        let loaded = try await store.load(id: job.id)
        #expect(loaded == nil)

        let reopened = try await FileSystemJobStore(directoryURL: dir)
        let afterReopen = try await reopened.load(id: job.id)
        #expect(afterReopen == nil)
    }

    @Test("Delete of unknown id is a no-op")
    func deleteOfUnknownIdIsNoOp() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try await FileSystemJobStore(directoryURL: dir)
        try await store.delete(id: UUID())
    }

    @Test("Corrupt file is skipped, others load")
    func corruptFileIsSkipped() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let goodJob = Self.makeJob()

        let first = try await FileSystemJobStore(directoryURL: dir)
        try await first.save(goodJob)

        let corruptURL = dir.appendingPathComponent("\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: corruptURL)

        let second = try await FileSystemJobStore(directoryURL: dir)
        let all = try await second.loadAll()
        #expect(all.count == 1)
        #expect(all.first?.id == goodJob.id)
    }

    @Test("count(status:) reflects mirror state")
    func countReflectsMirrorState() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try await FileSystemJobStore(directoryURL: dir)
        try await store.save(Self.makeJob(status: .pending))
        try await store.save(Self.makeJob(status: .pending))
        try await store.save(Self.makeJob(status: .running))

        let pending = try await store.count(status: .pending)
        let running = try await store.count(status: .running)
        #expect(pending == 2)
        #expect(running == 1)
    }

    @Test("loadAll(status:) filters in memory")
    func loadAllStatusFilters() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pendingJob = Self.makeJob(status: .pending)
        let runningJob = Self.makeJob(status: .running)

        let store = try await FileSystemJobStore(directoryURL: dir)
        try await store.save(pendingJob)
        try await store.save(runningJob)

        let pending = try await store.loadAll(status: .pending)
        #expect(pending.count == 1)
        #expect(pending.first?.id == pendingJob.id)
    }
}
