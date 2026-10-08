//
//  LegacyRowMigrationTests.swift
//  job-runnerTests
//
//  Created by Henry on 10/8/26.
//

import Foundation
@testable import JobRunner
import Testing

/// Rows written by job-runner 1.0.10 and earlier carry a `constraints` object. These fixtures are
/// byte-for-byte what `FileSystemJobStore` wrote: ISO 8601 dates, sorted keys, base64 `jobData`.
@Suite("Legacy row migration")
struct LegacyRowMigrationTests {
    private static let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    private static func row(constraints: String) -> String {
        """
        {"attempts":1,"constraints":\(constraints),"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","jobData":"e30=","lastAttemptedAt":"2026-10-01T12:00:05Z","originalCreatedAt":"2026-10-01T12:00:00Z","priority":1,"scheduledAt":"2026-10-01T12:00:07Z","status":"pending","typeName":"UploadJobLogJob"}
        """
    }

    private static let fullRetry = #"{"maxAttempts":10,"strategy":{"exponential":{"base":2,"maxDelay":300}}}"#

    struct Fixture: CustomTestStringConvertible, Sendable {
        let name: String
        let file: String
        let retry: RetryPolicy
        let persistence: Persistence
        let background: BackgroundPolicy
        let connectivity: Connectivity?
        var testDescription: String { name }
    }

    static let fixtures: [Fixture] = [
        Fixture(
            name: "1.0.10 row: every field present",
            file: row(constraints: #"{"background":{"requirement":"continuesInBackground"},"connectivity":{"requirement":"any"},"persistence":{"mode":"persisted"},"retry":\#(fullRetry)}"#),
            retry: RetryPolicy(maxAttempts: 10, strategy: .exponential(base: 2, maxDelay: 300)),
            persistence: .persisted,
            background: .continuesInBackground,
            connectivity: .any
        ),
        Fixture(
            name: "1.0.9 row: no background key",
            file: row(constraints: #"{"connectivity":{"requirement":"any"},"persistence":{"mode":"persisted"},"retry":\#(fullRetry)}"#),
            retry: RetryPolicy(maxAttempts: 10, strategy: .exponential(base: 2, maxDelay: 300)),
            persistence: .persisted,
            background: .foregroundOnly,
            connectivity: .any
        ),
        Fixture(
            name: "retry absent: never retried",
            file: row(constraints: #"{"connectivity":{"requirement":"wifi"},"persistence":{"mode":"persisted"}}"#),
            retry: .noRetry,
            persistence: .persisted,
            background: .foregroundOnly,
            connectivity: .wifi
        ),
        Fixture(
            name: "retry null: never retried",
            file: row(constraints: #"{"persistence":{"mode":"persisted"},"retry":null}"#),
            retry: .noRetry,
            persistence: .persisted,
            background: .foregroundOnly,
            connectivity: nil
        ),
        Fixture(
            name: "persistence absent: a row on disk is persisted",
            file: row(constraints: #"{"retry":\#(fullRetry)}"#),
            retry: RetryPolicy(maxAttempts: 10, strategy: .exponential(base: 2, maxDelay: 300)),
            persistence: .persisted,
            background: .foregroundOnly,
            connectivity: nil
        ),
        Fixture(
            name: "empty constraints object",
            file: row(constraints: "{}"),
            retry: .noRetry,
            persistence: .persisted,
            background: .foregroundOnly,
            connectivity: nil
        ),
    ]

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func connectivity(of job: SerializedJob) throws -> Connectivity? {
        try job.traits.constraints.first.map { try $0.decode(as: Connectivity.self) }
    }

    @Test("A legacy file decodes with its traits mapped and its state intact", arguments: fixtures)
    func legacyFileDecodes(_ fixture: Fixture) throws {
        let job = try Self.makeDecoder().decode(SerializedJob.self, from: Data(fixture.file.utf8))
        #expect(job.id == Self.id)
        #expect(job.typeName == "UploadJobLogJob")
        #expect(job.priority == .medium)
        #expect(job.attempts == 1)
        #expect(job.status == .pending)
        #expect(job.scheduledAt != nil)
        #expect(job.traits.retry == fixture.retry)
        #expect(job.traits.persistence == fixture.persistence)
        #expect(job.traits.background == fixture.background)
        #expect(try Self.connectivity(of: job) == fixture.connectivity)
    }

    @Test("Re-encoding writes traits, not constraints", arguments: fixtures)
    func reencodesAsTraits(_ fixture: Fixture) throws {
        let job = try Self.makeDecoder().decode(SerializedJob.self, from: Data(fixture.file.utf8))
        let data = try Self.makeEncoder().encode(job)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""traits":{"#))
        #expect(!json.contains(#""constraints":{"#))
        let again = try Self.makeDecoder().decode(SerializedJob.self, from: data)
        #expect(again.traits == job.traits)
        #expect(again.attempts == job.attempts)
    }

    @Test("FileSystemJobStore hydrates a legacy file, saves an update, and reopens it", arguments: fixtures)
    func storeHydratesUpdatesAndReopens(_ fixture: Fixture) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyRowMigrationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(fixture.file.utf8).write(to: dir.appendingPathComponent("\(Self.id.uuidString).json"))

        let store = try await FileSystemJobStore(directoryURL: dir)
        var job = try #require(await store.load(id: Self.id))
        #expect(job.traits.persistence == .persisted)

        job.attempts += 1
        job.status = .permanentlyFailed
        try await store.save(job)

        let reopened = try await FileSystemJobStore(directoryURL: dir)
        let loaded = try #require(await reopened.load(id: Self.id))
        #expect(loaded.attempts == 2)
        #expect(loaded.status == .permanentlyFailed)
        #expect(loaded.traits == job.traits)
        #expect(try Self.connectivity(of: loaded) == fixture.connectivity)
    }

    @Test("traits wins when both keys are present")
    func traitsWinsOverConstraints() throws {
        let both = Self.fixtures[0].file.replacingOccurrences(
            of: #""id":"#,
            with: #""traits":{"retry":{"maxAttempts":1,"strategy":{"immediate":{}}},"persistence":{"mode":"persisted"},"background":{"requirement":"foregroundOnly"},"constraints":[]},"id":"#
        )
        let job = try Self.makeDecoder().decode(SerializedJob.self, from: Data(both.utf8))
        #expect(job.traits.retry == .noRetry)
        #expect(job.traits.background == .foregroundOnly)
        #expect(job.traits.constraints.isEmpty)
    }

    @Test("An invalid traits value is an error, not a fallback to constraints", arguments: [
        #""traits":{"retry":"nope"},"#,
        #""traits":{},"#,
        #""traits":{"retry":{"maxAttempts":1,"strategy":{"immediate":{}}},"persistence":{"mode":"persisted"},"background":{"requirement":"foregroundOnly"}},"#,
        #""traits":null,"#,
    ])
    func invalidTraitsDoesNotFallBack(_ traits: String) {
        let broken = Self.fixtures[0].file.replacingOccurrences(of: #""id":"#, with: traits + #""id":"#)
        #expect(throws: DecodingError.self) {
            try Self.makeDecoder().decode(SerializedJob.self, from: Data(broken.utf8))
        }
    }

    @Test("A row with neither traits nor constraints is an error")
    func missingEnvelopeIsAnError() {
        let bare = Self.fixtures[0].file.replacingOccurrences(
            of: #""constraints":{"background":{"requirement":"continuesInBackground"},"connectivity":{"requirement":"any"},"persistence":{"mode":"persisted"},"retry":\#(Self.fullRetry)},"#,
            with: ""
        )
        #expect(!bare.contains("constraints"))
        #expect(throws: DecodingError.self) {
            try Self.makeDecoder().decode(SerializedJob.self, from: Data(bare.utf8))
        }
    }
}
