//
//  ContinuationTask.swift
//  job-runner
//
//  Created by Henry on 9/21/26.
//

import Foundation

/// What the OS hands the launch handler once it has granted background time, abstracted so the
/// coordinator can be driven by a double and built on platforms without the framework.
///
/// `Sendable` because the platform contract is cross-queue: the task arrives on one queue and its
/// expiration handler fires on another, so the drain loop and that handler necessarily hold the same
/// object from different isolation domains.
public protocol ContinuationTask: AnyObject, Sendable {
    var progress: Progress { get }
    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void)
    func updateTitle(_ title: String, subtitle: String)
    func setTaskCompleted(success: Bool)
}
