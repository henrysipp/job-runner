//
//  ConstraintValidationTests.swift
//  job-runnerTests
//
//  Created by Henry on 10/8/26.
//

import Foundation
@testable import JobRunner
import Testing

private struct ChargingConstraint: Constraint {
    static let key: TraitKey = "charging"
}

/// A host type that squats on the built-in connectivity key.
private struct ConnectivityImpostor: Constraint {
    static let key: TraitKey = "connectivity"
    let requirement = "any"
}

private struct ChargingJob: Job {
    typealias Context = Void
    var traits: JobTraits { [ChargingConstraint()] }
    func run(context _: Void) async throws {}
}

private struct ImpostorJob: Job {
    typealias Context = Void
    var traits: JobTraits { [ConnectivityImpostor()] }
    func run(context _: Void) async throws {}
}

@Suite(.serialized)
struct ConstraintValidationTests {
    @Test("Enqueue rejects a constraint the runner cannot evaluate")
    func enqueueRejectsUnknownConstraint() async throws {
        let runner = JobRunner(context: (), store: InMemoryJobStore(), maxConcurrent: 1)
        try await runner.register(ChargingJob.self)
        try await runner.start()

        await #expect(throws: JobError.unregisteredConstraint(ChargingConstraint.key)) {
            try await runner.enqueue(ChargingJob())
        }
        #expect(await runner.currentStatus().pending == 0)
        await runner.stop()
    }

    @Test("Enqueue rejects a host type that reuses the connectivity key")
    func enqueueRejectsImpostorByType() async throws {
        let runner = JobRunner(context: (), store: InMemoryJobStore(), maxConcurrent: 1)
        try await runner.register(ImpostorJob.self)
        try await runner.start()

        await #expect(throws: JobError.unregisteredConstraint(Connectivity.key)) {
            try await runner.enqueue(ImpostorJob())
        }
        await runner.stop()
    }

    @Test("A recovered row with an unknown constraint is never picked up")
    func recoveredUnknownConstraintStaysPending() async throws {
        let store = InMemoryJobStore()
        let stranded = SerializedJob(
            id: UUID(),
            typeName: String(describing: ChargingJob.self),
            priority: .high,
            traits: TraitSnapshot(constraints: [try EncodedConstraint(ChargingConstraint())]),
            originalCreatedAt: .now,
            attempts: 0,
            status: .pending,
            jobData: Data("{}".utf8)
        )
        try await store.save(stranded)

        let runner = JobRunner(context: (), store: store, maxConcurrent: 1)
        try await runner.register(ChargingJob.self)
        try await runner.start()
        try await waitForBackgroundJobs()

        let status = await runner.currentStatus()
        #expect(status.pending == 1)
        #expect(status.running == 0)
        #expect(try await store.load(id: stranded.id)?.status == .pending)
        await runner.stop()
    }
}
