# JobRunner

[![codecov](https://codecov.io/gh/henrysipp/job-runner/branch/main/graph/badge.svg)](https://codecov.io/gh/henrysipp/job-runner)

A simple Swift actor-based job queue with persistence, retry support, and priority scheduling.
Supports Swift Concurrency and the Swift 6 language mode.

## Usage


### Define a Context
Adding a context type will allow your job runner to pass non-codable properties to your jobs at runtime.
These can be things like network clients, model actors, or local Swift services.

```swift
struct AppContext: Sendable {
  let networkClient: NetworkClient
  let fileSystem: FileSystemClient
}
```

### Define a Job
Your job structs define an actual item of work to be done by your app in the background.
These inherit a context type and can only be run by a job runner conforming to that same context.

```swift
struct DownloadAssetJob: Job {
  typealias Context = AppContext

  let url: String

  func run(context: AppContext) async throws {
    let assetData: Data = try await context.networkClient.downloadAsset(url)
    try await context.fileSystem.saveData(assetData, for: url)
  }
}
```

### Create and Use the Runner

```swift
// Instantiate your context
let context = AppContext(networkClient: NetworkClient(), fileSystem: FileSystemClient())

// Alias your channel 
typealias AppJobRunner = JobRunner<AppContext>
let runner = AppJobRunner(context: context, store: InMemoryJobStore(), maxConcurrent: 4)

// Register the job types your runner will accept. 
// We use this to create a registry for automatic codable instantiation
try await runner.register(DownloadAssetJob.self)
try await runner.start()

try await runner.enqueue(
  DownloadAssetJob(url: "https://example.com/image.png"),
  priority: .high
)
```

### Traits

Each job declares its traits. A trait is a declared property of the job with exactly one
interpreter. Policies are interpreted by the runner or the store. Constraints gate pickup. Today
`Connectivity` is the only constraint; registering app-defined constraints and their evaluators
is the next step.

```swift
struct UploadPhotoJob: Job {
  typealias Context = AppContext

  let localId: String

  var traits: JobTraits {
    [RetryPolicy(maxAttempts: 10, strategy: .exponential(base: 2, maxDelay: 300)),
     Persistence.persisted,
     BackgroundPolicy.continuesInBackground,
     Connectivity.notExpensive]
  }

  func run(context: AppContext) async throws { /* ... */ }
}
```

| Trait | Kind | Default when absent |
|---|---|---|
| `RetryPolicy` | policy | `.noRetry`: the job runs once |
| `Persistence` | policy | `.ephemeral`: gone on relaunch |
| `BackgroundPolicy` | policy | `.foregroundOnly` |
| `Connectivity` | constraint | none: the job is not gated on the network |

A job declares at most one trait per key. Traits are snapshotted into the stored job at enqueue;
changing a job type's traits in a later build does not affect rows already on disk.

`Connectivity` and `BackgroundPolicy` gate eligibility: the runner compares them against live
state and defers jobs that don't qualify, leaving them `.pending` rather than failing them.

### Background

`BackgroundPolicy` declares whether a job may keep running once the host application is backgrounded:

| Requirement | Meaning |
|---|---|
| `.foregroundOnly` | Default. Deferred while backgrounded. |
| `.continuesInBackground` | Eligible while backgrounded, and worth keeping the process alive for. |

The runner cannot observe application lifecycle itself, so the host reports it:

```swift
// From your scene phase / lifecycle observer
await runner.setExecutionContext(.background)
await runner.setExecutionContext(.foreground)
```

Changing it re-drives the queue, so deferred jobs resume without being re-enqueued.
Background execution permits only a first attempt: after a failure, retries wait until foreground,
where the existing backoff and attempt limit still apply. Retryable failures do not trigger rollback. Note that this
is checked at dequeue, not enforced mid-flight: a `.foregroundOnly` job already running when the
host backgrounds is left alone to finish.

`.continuesInBackground` is a declaration of intent, not a mechanism. What the host does with it, such as
submitting a `BGContinuedProcessingTaskRequest` on iOS, is up to the host. The optional continuation
coordinator and iOS adapter below provide that integration.

### Stopping

Two options, with deliberately different semantics.

```swift
// Halts pickup. In-flight jobs run to completion. Does not wait.
await runner.stop()

// Halts pickup, cancels in-flight jobs, and waits for their teardown.
let allStopped = await runner.shutdown(timeout: .seconds(3))
```

`shutdown` is for when the caller has a deadline, such as an OS expiration handler. Cancellation is
cooperative: a job that neither awaits a cancellable operation nor checks `Task.isCancelled` will
not stop, which is what `timeout` is for. It returns `false` in that case and keeps tracking the live
execution. Restarting the same runner never requeues that job while it is still alive. A fresh
runner recovers orphaned `.running` rows left by a previous process.

Interruption is deferral, not failure. A cancelled job returns to `.pending` with its attempt count
untouched, `rollback(context:error:)` does **not** fire, and `jobInterrupted` is delivered to the
delegate instead of `jobFailed`. Jobs must be idempotent, which is already true of any job that has
to survive a process kill.

### Rollback

Implement `rollback(context:error:)` to compensate for a job that has failed terminally, such as
reverting optimistic local state. It fires on permanent failure, on an exhausted retry budget, and
on a job with no retry constraint. It does not fire on a retryable failure or on interruption.

```swift
func rollback(context: AppContext, error: any Error) async {
  try? await context.fileSystem.removeOptimisticRow(for: url)
}
```


### Background continuation

Jobs constrained `.continuesInBackground` can keep the process alive after the host backgrounds,
if the host asks the OS for time on their behalf. `BackgroundContinuationCoordinator` does the
asking: it permits one outstanding submission, reports successes and failures separately, and
handles expiration. Retryable failures count as failures for this continuation, and their retries
wait until foreground. A job contributes at most one outcome per continuation, so foreground
retries do not inflate its progress. New jobs increase the total without reducing the finished count.

The continuation ends when no background-eligible jobs remain and reports unsuccessful completion
if any job failed or was interrupted. Expiration and budget exhaustion stop background pickup and
cancel in-flight work. Foreground return waits for any teardown already in progress before
resuming; a late expiration does not stop resumed foreground work.

```swift
import JobRunner

enum UploadContinuation {
  // Constructing this registers the launch handler, so reach it before launch finishes and
  // reach it exactly once.
  static let coordinator = BackgroundContinuationCoordinator(
    scheduler: BGTaskContinuationScheduler(),          // iOS adapter over BGTaskScheduler
    runner: { AppJobRunner.shared },                    // lazy: the runner is built after launch
    configuration: .init(
      identifier: "com.example.app.continued-jobs",    // must appear in BGTaskSchedulerPermittedIdentifiers
      title: "Uploading",
      subtitle: { "\($0.succeeded) succeeded, \($0.failed) failed, \($0.remaining) remaining" },
      isEnabled: { FeatureFlags.backgroundUploads }
    ),
    observer: UploadContinuationLogger()               // BackgroundContinuationObserver, optional
  )
}

// At launch
_ = UploadContinuation.coordinator

// Add to the runner's delegates so enqueuing a `.continuesInBackground` job triggers submission
await runner.setDelegate(UploadContinuation.coordinator)

// From the scene phase / lifecycle observer
await UploadContinuation.coordinator.appDidEnterForeground()
await UploadContinuation.coordinator.appDidEnterBackground()
```

Use one fixed identifier. The SDK header suggests a wildcard with a per-submission UUID, but the
system fails to match the concrete id back to the wildcard handler, and only one continuation is
ever outstanding anyway.

The coordinator is written against `ContinuationScheduler` and `ContinuationTask`, so it builds and
tests everywhere the package does. `BGTaskContinuationScheduler` and the `BGContinuedProcessingTask`
conformance are the iOS adapter and compile only there.
