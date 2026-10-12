//
//  CustomConstraintTests.swift
//  job-runnerTests
//
//  Created by Henry on 10/12/26.
//

import Foundation
@testable import JobRunner
import Testing

private struct MountedConstraint: Constraint {
    static let key: TraitKey = "mounted"
}

private struct MountedJob: Job {
    typealias Context = Void
    var traits: JobTraits { [MountedConstraint()] }
    func run(context _: Void) async throws {}
}

private actor Mount {
    var isMounted = false
    func set(_ value: Bool) { isMounted = value }
}

@Suite(.serialized)
struct CustomConstraintTests {
    private func makeRunner(_ mount: Mount) async throws -> JobRunner<Void> {
        let runner = JobRunner(context: (), store: InMemoryJobStore(), maxConcurrent: 1)
        try await runner.register(MountedJob.self)
        try await runner.registerConstraint(MountedConstraint.self) { _ in await mount.isMounted }
        return runner
    }

    @Test("A registered constraint is accepted at enqueue")
    func enqueueAcceptsRegisteredConstraint() async throws {
        let runner = try await makeRunner(Mount())
        try await runner.start()

        _ = try await runner.enqueue(MountedJob())

        #expect(await runner.currentStatus().pending == 1)
        await runner.stop()
    }

    @Test("An unsatisfied constraint leaves the job pending")
    func unsatisfiedStaysPending() async throws {
        let runner = try await makeRunner(Mount())
        try await runner.start()

        _ = try await runner.enqueue(MountedJob())
        try await waitForBackgroundJobs()

        let status = await runner.currentStatus()
        #expect(status.pending == 1)
        #expect(status.running == 0)
        await runner.stop()
    }

    @Test("Signalling after the state flips runs the job")
    func signalRunsJobOnceSatisfied() async throws {
        let mount = Mount()
        let runner = try await makeRunner(mount)
        try await runner.start()
        _ = try await runner.enqueue(MountedJob())
        try await waitForBackgroundJobs()
        #expect(await runner.currentStatus().pending == 1)

        await mount.set(true)
        await runner.signalConstraintsChanged()

        try await waitForCondition { await runner.currentStatus().isIdle }
        await runner.stop()
    }

    @Test("A host type that reuses a registered key is rejected")
    func impostorRejected() async throws {
        struct Impostor: Constraint {
            static let key: TraitKey = "mounted"
        }
        struct ImpostorJob: Job {
            typealias Context = Void
            var traits: JobTraits { [Impostor()] }
            func run(context _: Void) async throws {}
        }
        let runner = try await makeRunner(Mount())
        try await runner.register(ImpostorJob.self)
        try await runner.start()

        await #expect(throws: JobError.unregisteredConstraint(Impostor.key)) {
            try await runner.enqueue(ImpostorJob())
        }
        await runner.stop()
    }

    @Test("Registering a constraint after start throws")
    func registerAfterStartThrows() async throws {
        let runner = JobRunner(context: (), store: InMemoryJobStore(), maxConcurrent: 1)
        try await runner.start()

        await #expect(throws: JobError.registrationAfterStart) {
            try await runner.registerConstraint(MountedConstraint.self) { _ in true }
        }
        await runner.stop()
    }
}
