//
//  JobWaiter.swift
//  job-runner
//

import Foundation

public struct JobWaiterError: Error, Sendable {
    public let errorType: String
    public let errorDescription: String
    public let attempts: Int
}

public struct JobWaiterTimeoutError: Error, Sendable {
    public let id: UUID
    public let timeout: Duration
}

public actor JobWaiter: JobRunnerDelegate {
    private struct PendingWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var pending: [UUID: [PendingWaiter]] = [:]
    private var finished: [UUID: Result<Void, Error>] = [:]

    public init() {}

    public func wait(for id: UUID, timeout: Duration = .seconds(5)) async throws {
        if let result = finished[id] {
            try result.get()
            return
        }

        let waiterID = UUID()
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.timeOut(waiterID: waiterID, id: id, timeout: timeout)
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { cont in
            if let result = finished[id] {
                cont.resume(with: result)
                return
            }

            pending[id, default: []].append(PendingWaiter(id: waiterID, continuation: cont))
        }
    }

    private func timeOut(waiterID: UUID, id: UUID, timeout: Duration) {
        guard var waiters = pending[id] else { return }
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }

        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            pending.removeValue(forKey: id)
        } else {
            pending[id] = waiters
        }

        waiter.continuation.resume(throwing: JobWaiterTimeoutError(id: id, timeout: timeout))
    }

    nonisolated public func jobCompleted(_ event: JobCompletedEvent) {
        let id = event.id
        Task { await self.record(id: id, result: .success(())) }
    }

    nonisolated public func jobFailed(_ event: JobFailedEvent) {
        guard !event.willRetry else { return }
        let id = event.id
        let error = JobWaiterError(
            errorType: event.errorType,
            errorDescription: event.errorDescription,
            attempts: event.attempt
        )
        Task { await self.record(id: id, result: .failure(error)) }
    }

    private func record(id: UUID, result: Result<Void, Error>) {
        finished[id] = result

        guard let waiters = pending.removeValue(forKey: id) else { return }
        for waiter in waiters {
            waiter.continuation.resume(with: result)
        }
    }
}
