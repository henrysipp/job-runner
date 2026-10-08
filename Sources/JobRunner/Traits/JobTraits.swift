//
//  JobTraits.swift
//  job-runner
//
//  Created by Henry on 10/8/26.
//

import Foundation

/// The traits a job declares. Authoring only; `TraitSnapshot` is what gets stored.
///
/// At most one trait per key. A duplicate key is a programmer error.
public struct JobTraits: Sendable, ExpressibleByArrayLiteral {
    private var storage: [TraitKey: any JobTrait] = [:]

    public init(_ traits: [any JobTrait]) {
        for trait in traits {
            insert(trait)
        }
    }

    public init(arrayLiteral elements: any JobTrait...) {
        self.init(elements)
    }

    public subscript<T: JobTrait>(_ type: T.Type) -> T? {
        storage[T.key] as? T
    }

    public mutating func insert(_ trait: any JobTrait) {
        let key = type(of: trait).key
        precondition(storage[key] == nil, "Duplicate trait key '\(key.rawValue)'")
        storage[key] = trait
    }

    var all: [any JobTrait] {
        Array(storage.values)
    }
}
