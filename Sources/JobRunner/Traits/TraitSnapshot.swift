//
//  TraitSnapshot.swift
//  job-runner
//
//  Created by Henry on 10/8/26.
//

import Foundation

/// A constraint as stored: its key and its JSON-encoded value. Decoded by the evaluator
/// registered for the key.
public struct EncodedConstraint: Codable, Sendable, Equatable {
    public let key: TraitKey
    public let payload: Data

    public init(_ constraint: any Constraint) throws {
        key = type(of: constraint).key
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        payload = try encoder.encode(constraint)
    }

    public func decode<C: Constraint>(as type: C.Type) throws -> C {
        try JSONDecoder().decode(type, from: payload)
    }
}

/// A job's traits as persisted. Built once at enqueue from `JobTraits`; policies are
/// materialized to their defaults so a snapshot is always complete.
public struct TraitSnapshot: Codable, Sendable, Equatable {
    public let retry: RetryPolicy
    public let persistence: Persistence
    public let background: BackgroundPolicy
    public let constraints: [EncodedConstraint]

    /// - Precondition: `constraints` holds at most one entry per key.
    public init(
        retry: RetryPolicy = .noRetry,
        persistence: Persistence = .ephemeral,
        background: BackgroundPolicy = .foregroundOnly,
        constraints: [EncodedConstraint] = []
    ) {
        precondition(!Self.hasDuplicateKeys(constraints), "Duplicate constraint keys")
        self.retry = retry
        self.persistence = persistence
        self.background = background
        self.constraints = constraints
    }

    public init(_ traits: JobTraits) throws {
        var retry = RetryPolicy.noRetry
        var persistence = Persistence.ephemeral
        var background = BackgroundPolicy.foregroundOnly
        var constraints: [EncodedConstraint] = []

        for trait in traits.all {
            switch trait {
            case let policy as RetryPolicy:
                retry = policy
            case let policy as Persistence:
                persistence = policy
            case let policy as BackgroundPolicy:
                background = policy
            case let constraint as any Constraint:
                let key = type(of: constraint).key
                guard !Self.policyKeys.contains(key) else {
                    throw JobError.uninterpretedTrait(key)
                }
                constraints.append(try EncodedConstraint(constraint))
            default:
                throw JobError.uninterpretedTrait(type(of: trait).key)
            }
        }

        self.init(
            retry: retry,
            persistence: persistence,
            background: background,
            constraints: constraints.sorted { $0.key.rawValue < $1.key.rawValue }
        )
    }

    static let policyKeys: Set<TraitKey> = [RetryPolicy.key, Persistence.key, BackgroundPolicy.key]

    static func hasDuplicateKeys(_ constraints: [EncodedConstraint]) -> Bool {
        Set(constraints.map(\.key)).count != constraints.count
    }

    private enum CodingKeys: String, CodingKey {
        case retry
        case persistence
        case background
        case constraints
    }

    /// Strict: every field is required. Rows written before traits are mapped by `SerializedJob`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        retry = try container.decode(RetryPolicy.self, forKey: .retry)
        persistence = try container.decode(Persistence.self, forKey: .persistence)
        background = try container.decode(BackgroundPolicy.self, forKey: .background)
        let constraints = try container.decode([EncodedConstraint].self, forKey: .constraints)
        guard !Self.hasDuplicateKeys(constraints) else {
            throw DecodingError.dataCorruptedError(
                forKey: .constraints,
                in: container,
                debugDescription: "Duplicate constraint keys"
            )
        }
        self.constraints = constraints
    }
}

/// The `JobConstraints` object that job-runner 1.0.10 and earlier wrote. Absent fields resolve to
/// what the old decoder did: no retry, persisted (every row on disk is), foreground only.
struct LegacyJobConstraints: Decodable {
    let retry: RetryPolicy?
    let connectivity: Connectivity?
    let persistence: Persistence?
    let background: BackgroundPolicy?

    func snapshot() throws -> TraitSnapshot {
        TraitSnapshot(
            retry: retry ?? .noRetry,
            persistence: persistence ?? .persisted,
            background: background ?? .foregroundOnly,
            constraints: try connectivity.map { [try EncodedConstraint($0)] } ?? []
        )
    }
}
