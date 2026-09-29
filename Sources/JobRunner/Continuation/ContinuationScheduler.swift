//
//  ContinuationScheduler.swift
//  job-runner
//
//  Created by Henry on 9/21/26.
//

import Foundation

/// The two calls the coordinator makes into the platform's background task scheduler.
public protocol ContinuationScheduler: Sendable {
    /// Registers the handler the platform invokes once it grants background time.
    ///
    /// Must complete before the host finishes launching, and must be called once per identifier
    /// for the life of the process.
    /// - Returns: `false` if the platform refuses the identifier, typically because it is not
    ///   declared in the host's permitted-identifier list.
    func register(
        identifier: String,
        launchHandler: @escaping @Sendable (any ContinuationTask) -> Void
    ) -> Bool

    /// Asks the platform for background time. Must be called while the host is foregrounded, as a
    /// consequence of something the person did.
    func submit(identifier: String, title: String, subtitle: String) async throws
}
