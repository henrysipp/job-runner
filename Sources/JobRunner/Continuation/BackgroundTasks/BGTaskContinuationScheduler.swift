//
//  BGTaskContinuationScheduler.swift
//  job-runner
//
//  Created by Henry on 9/21/26.
//

#if os(iOS)
    import BackgroundTasks
    import Foundation

    /// `BGTaskScheduler` is a thread-safe process singleton the framework expects to be called from launch
    /// and from arbitrary contexts alike; it simply predates the annotation.
    extension BGTaskScheduler: @retroactive @unchecked Sendable {}

    /// `ContinuationScheduler` over `BGTaskScheduler`, for `BGContinuedProcessingTask`.
    ///
    /// The identifier the host registers must appear literally in its `BGTaskSchedulerPermittedIdentifiers`.
    /// The SDK header recommends wildcard notation with a per-submission UUID, but as of iOS 26 the
    /// system fails to match a concrete id back to a wildcard handler ("No launch handler registered"),
    /// so use one fixed identifier. The coordinator only ever has one continuation outstanding, so
    /// nothing needs per-submission uniqueness.
    public struct BGTaskContinuationScheduler: ContinuationScheduler {
        private let scheduler: BGTaskScheduler

        public init(scheduler: BGTaskScheduler = .shared) {
            self.scheduler = scheduler
        }

        public func register(
            identifier: String,
            launchHandler: @escaping @Sendable (any ContinuationTask) -> Void
        ) -> Bool {
            scheduler.register(forTaskWithIdentifier: identifier, using: nil) { task in
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                launchHandler(task)
            }
        }

        public func submit(identifier: String, title: String, subtitle: String) async throws {
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
            // `.queue` waits for a slot. `.fail` would throw `immediateRunIneligible` under load and
            // leave the work with no background time at all.
            request.strategy = .queue

            // `submit(_:)` is deprecated in iOS 27 for `submitTaskRequest(_:)`, which reports error
            // conditions the old one swallowed.
            if #available(iOS 27.0, *) {
                try await scheduler.submitTaskRequest(request)
            } else {
                try scheduler.submit(request)
            }
        }
    }
#endif
