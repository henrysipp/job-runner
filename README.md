# JobRunner

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
let runner = AppJobRunner(context: context, store: InMemoryJobStore(), maxConcurrent: 4, maxAttempts: 3)

// Register the job types your runner will accept. 
// We use this to create a registry for automatic codable instantiation
try await runner.register(DownloadAssetJob.self)
try await runner.start()

try await runner.enqueue(
  DownloadAssetJob(url: "https://example.com/image.png"),
  priority: .high
)
```
