//
//  TraitSnapshotTests.swift
//  job-runnerTests
//
//  Created by Henry on 10/8/26.
//

import Foundation
@testable import JobRunner
import Testing

private struct InertTrait: JobTrait {
    static let key: TraitKey = "inert"
}

private struct RetryKeyedConstraint: Constraint {
    static let key: TraitKey = "retry"
}

private struct ChargingConstraint: Constraint {
    static let key: TraitKey = "charging"
    let minimumPercent: Int
}

@Suite("TraitSnapshot")
struct TraitSnapshotTests {
    @Test("Empty traits snapshot to no retry, ephemeral, foreground only")
    func defaults() throws {
        let snapshot = try TraitSnapshot([])
        #expect(snapshot.retry == .noRetry)
        #expect(snapshot.persistence == .ephemeral)
        #expect(snapshot.background == .foregroundOnly)
        #expect(snapshot.constraints.isEmpty)
    }

    @Test("Declared traits land in their slots")
    func declaredTraits() throws {
        let snapshot = try TraitSnapshot([
            RetryPolicy(maxAttempts: 4, strategy: .immediate),
            Persistence.persisted,
            BackgroundPolicy.continuesInBackground,
            Connectivity.wifi,
        ])
        #expect(snapshot.retry.maxAttempts == 4)
        #expect(snapshot.persistence == .persisted)
        #expect(snapshot.background == .continuesInBackground)
        #expect(snapshot.constraints.map(\.key) == [Connectivity.key])
        #expect(try snapshot.constraints[0].decode(as: Connectivity.self) == .wifi)
    }

    @Test("Custom constraints carry their payload")
    func customConstraintPayload() throws {
        let snapshot = try TraitSnapshot([ChargingConstraint(minimumPercent: 40), Connectivity.any])
        #expect(snapshot.constraints.map(\.key) == [ChargingConstraint.key, Connectivity.key])
        let decoded = try snapshot.constraints[0].decode(as: ChargingConstraint.self)
        #expect(decoded.minimumPercent == 40)
    }

    @Test("A trait with no interpreter is rejected")
    func uninterpretedTrait() {
        #expect(throws: JobError.uninterpretedTrait(InertTrait.key)) {
            try TraitSnapshot([InertTrait()])
        }
    }

    @Test("A constraint cannot claim a policy key")
    func constraintWithPolicyKey() {
        #expect(throws: JobError.uninterpretedTrait(RetryPolicy.key)) {
            try TraitSnapshot([RetryKeyedConstraint()])
        }
    }

    @Test("Encoded snapshots round-trip")
    func roundTrip() throws {
        let original = try TraitSnapshot([
            RetryPolicy(maxAttempts: 2, strategy: .exponential(base: 2, maxDelay: 60)),
            Persistence.persisted,
            Connectivity.notExpensive,
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TraitSnapshot.self, from: data)
        #expect(decoded == original)
    }

    @Test("Duplicate constraint keys on disk are a decode error")
    func duplicateConstraintKeys() throws {
        let one = try EncodedConstraint(Connectivity.any)
        let payload = one.payload.base64EncodedString()
        let json = """
        {"retry":{"maxAttempts":1,"strategy":{"immediate":{}}},
         "persistence":{"mode":"persisted"},
         "background":{"requirement":"foregroundOnly"},
         "constraints":[{"key":"connectivity","payload":"\(payload)"},{"key":"connectivity","payload":"\(payload)"}]}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TraitSnapshot.self, from: Data(json.utf8))
        }
    }

    @Test("Decoding is strict: an empty object is an error, not defaults")
    func emptyObjectIsAnError() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TraitSnapshot.self, from: Data("{}".utf8))
        }
    }

    @Test("Decoding is strict: a missing constraints list is an error")
    func missingConstraintsIsAnError() {
        let json = """
        {"retry":{"maxAttempts":1,"strategy":{"immediate":{}}},
         "persistence":{"mode":"persisted"},
         "background":{"requirement":"foregroundOnly"}}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TraitSnapshot.self, from: Data(json.utf8))
        }
    }
}
