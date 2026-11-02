import Foundation
@testable import JobRunner
import Testing

private struct StorageMounted: Constraint {
    static let key: TraitKey = "storage-mounted"
}

private struct BackgroundUpload: Job {
    typealias Context = Void
    var needsStorage = false

    var traits: JobTraits {
        var traits: [any JobTrait] = [RetryPolicy.noRetry, BackgroundPolicy.continuesInBackground]
        if needsStorage { traits.append(StorageMounted()) }
        return JobTraits(traits)
    }

    func run(context _: Void) async throws {}
}

private actor Storage {
    var isMounted = false
    func mount() { isMounted = true }
}

struct BlockedBackgroundWorkTests {
    /// Not started, so nothing runs and the snapshot reflects only what's queued.
    private func makeRunner(_ storage: Storage) async throws -> JobRunner<Void> {
        let runner = JobRunner(context: (), store: InMemoryJobStore(), maxConcurrent: 1)
        try await runner.register(BackgroundUpload.self)
        try await runner.registerConstraint(StorageMounted.self) { _ in await storage.isMounted }
        return runner
    }

    @Test("A job blocked by a constraint isn't counted as remaining background work")
    func blockedJobIsNotRemaining() async throws {
        let runner = try await makeRunner(Storage())
        await runner.beginBackgroundContinuation()

        try await runner.enqueue(BackgroundUpload())
        try await runner.enqueue(BackgroundUpload(needsStorage: true))
        try await runner.enqueue(BackgroundUpload(needsStorage: true))

        #expect(await runner.backgroundWorkRemaining() == BackgroundWorkSnapshot(remaining: 1))
    }

    @Test("Only blocked jobs left means the continuation has nothing remaining")
    func onlyBlockedJobsDrains() async throws {
        let runner = try await makeRunner(Storage())
        await runner.beginBackgroundContinuation()

        try await runner.enqueue(BackgroundUpload(needsStorage: true))

        #expect(await runner.backgroundWorkRemaining() == .empty)
    }

    @Test("A blocked job counts once its constraint is satisfied")
    func unblockedJobBecomesRemaining() async throws {
        let storage = Storage()
        let runner = try await makeRunner(storage)
        await runner.beginBackgroundContinuation()
        try await runner.enqueue(BackgroundUpload(needsStorage: true))

        await storage.mount()

        #expect(await runner.backgroundWorkRemaining() == BackgroundWorkSnapshot(remaining: 1))
    }
}
