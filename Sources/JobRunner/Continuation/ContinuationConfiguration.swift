//
//  ContinuationConfiguration.swift
//  job-runner
//
//  Created by Henry on 9/21/26.
//

import Foundation

/// Everything about a background continuation that only the host application can know.
public struct ContinuationConfiguration: Sendable {
    /// The platform task identifier. On Apple platforms it must appear in the host's Info.plist.
    public var identifier: String

    /// Shown to the person while the work runs. Kept static; per-item detail belongs in `subtitle`.
    public var title: String

    /// Shown beneath the title, recomputed as work completes.
    public var subtitle: @Sendable (BackgroundWorkSnapshot) -> String

    /// Read at each submission attempt, so a host can gate this on a feature flag it flips at
    /// runtime. Registration is never gated by it.
    public var isEnabled: @Sendable () -> Bool

    /// How long one continuation may run. Work that hasn't finished by then is left for the next
    /// foreground launch rather than held open indefinitely.
    public var maxDuration: Duration

    /// How often progress is re-read from the runner.
    public var pollInterval: Duration

    /// How long to wait for in-flight jobs to unwind once the platform expires the continuation.
    public var shutdownTimeout: Duration

    public init(
        identifier: String,
        title: String,
        subtitle: @escaping @Sendable (BackgroundWorkSnapshot) -> String = {
            "\($0.succeeded) succeeded, \($0.failed) failed, \($0.remaining) remaining"
        },
        isEnabled: @escaping @Sendable () -> Bool = { true },
        maxDuration: Duration = .seconds(600),
        pollInterval: Duration = .seconds(1),
        shutdownTimeout: Duration = .seconds(3)
    ) {
        self.identifier = identifier
        self.title = title
        self.subtitle = subtitle
        self.isEnabled = isEnabled
        self.maxDuration = maxDuration
        self.pollInterval = pollInterval
        self.shutdownTimeout = shutdownTimeout
    }
}
