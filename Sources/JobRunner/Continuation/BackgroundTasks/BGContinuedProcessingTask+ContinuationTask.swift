//
//  BGContinuedProcessingTask+ContinuationTask.swift
//  job-runner
//
//  Created by Henry on 9/21/26.
//

#if os(iOS)
    import BackgroundTasks
    import Foundation

    /// Unchecked because `BGContinuedProcessingTask` predates Swift concurrency annotations, not because
    /// the usage is unsound: the framework hands the task to the launch handler on one queue and invokes
    /// its expiration handler on another, so cross-isolation use is the platform's own contract.
    extension BGContinuedProcessingTask: @retroactive @unchecked Sendable {}

    extension BGContinuedProcessingTask: ContinuationTask {
        public func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
            expirationHandler = handler
        }
    }
#endif
