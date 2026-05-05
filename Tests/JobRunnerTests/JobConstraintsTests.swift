//
//  JobConstraintsTests.swift
//  job-runnerTests
//
//  Created by Henry on 5/5/26.
//

import Foundation
@testable import JobRunner
import Testing

@Suite("JobConstraints")
struct JobConstraintsTests {
    @Test("Default construction is ephemeral")
    func defaultConstructionIsEphemeral() {
        let constraints = JobConstraints()
        #expect(constraints.persistence == .ephemeral)
    }

    @Test("Encoded constraints round-trip")
    func encodedConstraintsRoundTrip() throws {
        let original = JobConstraints(persistence: .persisted)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JobConstraints.self, from: data)
        #expect(decoded.persistence == .persisted)
    }

    @Test("Legacy JSON without persistence key decodes as persisted")
    func legacyJSONDecodesAsPersisted() throws {
        let legacyJSON = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(JobConstraints.self, from: legacyJSON)
        #expect(decoded.persistence == .persisted)
    }
}
