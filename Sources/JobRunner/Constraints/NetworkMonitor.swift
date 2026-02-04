//
//  NetworkMonitor.swift
//  job-runner
//
//  Created by Henry on 2/4/26.
//

import Foundation
import Network

public actor NetworkMonitor {
    public static let shared = NetworkMonitor()

    private var monitor: NWPathMonitor?
    private var currentPath: NWPath?
    private var callbacks: [UUID: @Sendable () -> Void] = [:]
    private let queue = DispatchQueue(label: "job-runner.network-monitor")

    private init() {}

    public func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { [weak self] in
                await self?.handlePathUpdate(path)
            }
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor?.cancel()
        monitor = nil
        currentPath = nil
    }

    private func handlePathUpdate(_ path: NWPath) {
        let previousPath = currentPath
        currentPath = path

        guard previousPath?.status != path.status else { return }

        for callback in callbacks.values {
            callback()
        }
    }

    public func addCallback(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        callbacks[id] = callback
        return id
    }

    public func removeCallback(_ id: UUID) {
        callbacks.removeValue(forKey: id)
    }

    public func satisfies(_ constraint: ConnectivityConstraint) -> Bool {
        guard let path = currentPath else {
            return false
        }

        guard path.status == .satisfied else {
            return false
        }

        switch constraint.requirement {
        case .any:
            return true
        case .wifi:
            return path.usesInterfaceType(.wifi)
        case .cellular:
            return path.usesInterfaceType(.cellular)
        case .notExpensive:
            return !path.isExpensive
        }
    }

    public var isConnected: Bool {
        currentPath?.status == .satisfied
    }
}
