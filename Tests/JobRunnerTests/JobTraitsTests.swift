//
//  JobTraitsTests.swift
//  job-runnerTests
//
//  Created by Henry on 10/8/26.
//

import Foundation
@testable import JobRunner
import Testing

@Suite("JobTraits")
struct JobTraitsTests {
    @Test("Subscript returns the declared trait by type")
    func subscriptByType() {
        let traits: JobTraits = [Persistence.persisted, Connectivity.wifi]
        #expect(traits[Persistence.self] == .persisted)
        #expect(traits[Connectivity.self] == .wifi)
        #expect(traits[RetryPolicy.self] == nil)
    }

    @Test("Insert adds a trait under its key")
    func insert() {
        var traits: JobTraits = []
        traits.insert(BackgroundPolicy.continuesInBackground)
        #expect(traits[BackgroundPolicy.self] == .continuesInBackground)
    }

    @Test("Jobs default to no traits")
    func jobDefault() throws {
        struct Bare: Job {
            typealias Context = Void
            func run(context _: Void) async throws {}
        }
        let snapshot = try TraitSnapshot(Bare().traits)
        #expect(snapshot == TraitSnapshot())
    }
}
