# SplatKit

Swift SDK for the [Splat](https://splat-3d.com) 3D Gaussian Splatting API. Turn video into interactive 3D scenes with native ARKit camera pose capture.

## Requirements

- iOS 16.0+
- Swift 5.10+
- Xcode 15.3+

## Installation

Add SplatKit to your project using Swift Package Manager:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/zzulanas/splat-swift-sdk.git", from: "1.0.0")
]
```

Or in Xcode: **File > Add Package Dependencies** and enter the repository URL.

## Quick Start

```swift
import SplatKit

let client = SplatClient(apiKey: "s3d_your_api_key")

// Create a scene from a video file
let scene = try await client.createAndProcess(
    videoURL: videoFileURL,
    title: "Living Room Tour",
    preset: .standard
) { status, progress in
    print("\(status.rawValue): \(progress ?? 0)%")
}

print("View your scene: \(scene.viewerURL!)")
```

## ARKit Capture

Use `SplatScanner` to capture video with camera poses simultaneously. ARKit poses let the pipeline skip Structure from Motion, cutting processing time significantly.

```swift
import SplatKit

let scanner = SplatScanner()

// Start ARKit session + video recording
try await scanner.start()

// Update UI with frame count
scanner.onFrameCountUpdated = { count in
    frameCountLabel.text = "\(count) poses captured"
}

// ... user walks around the scene ...

// Stop and get results
let capture = try await scanner.stop()

// Upload with poses
let scene = try await client.createAndProcess(
    videoURL: capture.videoURL,
    title: "My Scene",
    preset: .standard,
    arkitPoses: capture.poses
)
```

## API Reference

### SplatClient

| Method | Description |
|--------|-------------|
| `createScene(title:preset:)` | Create a scene and get a presigned upload URL |
| `uploadVideo(from:to:)` | Upload a video file to the presigned URL |
| `processScene(id:arkitPoses:lidarPoints:enableLOD:idempotencyKey:)` | Trigger GPU processing |
| `waitForScene(id:onProgress:)` | Poll a scene until processing finishes |
| `resume(_:onProgress:)` | Continue an interrupted `createAndProcess` without paying again |
| `resume(sceneID:preset:arkitPoses:lidarPoints:onProgress:)` | Continue a scene after an app restart, from its saved ID |
| `getScene(id:)` | Get scene status and metadata |
| `listScenePage(cursor:limit:)` | One page of scenes, newest first, with the next page's cursor |
| `allScenes(pageSize:)` | Every scene, fetched a page at a time as you iterate |
| `updateScene(id:_:)` | Change title, address, description, or visibility |
| `retrainScene(id:preset:)` | Process the source again at another preset, as a new scene |
| `cancelScene(id:)` | Cancel an uploading or processing scene |
| `downloadScene(id:format:)` | Download the 3D model (SOG or PLY) to a temporary file |
| `getSceneThumbnail(id:)` | Thumbnail image data |
| `getUsage()` | Usage this billing period and plan limits |
| `deleteScene(id:)` | Delete a scene and all files |
| `createAndProcess(videoURL:title:preset:arkitPoses:lidarPoints:onProgress:onSceneCreated:)` | Full flow in one call |

`listScenes()` is deprecated: it returns only the first page.

### Pagination

```swift
for try await scene in client.allScenes() {
    print(scene.id, scene.status.rawValue)
}
```

For page-level control, pass each page's `nextCursor` back until it is `nil`. Treat the cursor as opaque.

### ScenePreset

| Preset | Resolution | Iterations | Time |
|--------|-----------|------------|------|
| `.fast` | 800px | 3K | ~3 min |
| `.standard` | 1600px | 7K | ~13 min |
| `.quality` | 1600px | 15K | ~25 min |
| `.ultra` | full-res | 30K | ~45 min |

### Retries, Timeouts, and Resuming

Reads and `processScene` retry network failures, 5xx responses and rate limits up to three times with exponential backoff and jitter, waiting out a `Retry-After` of up to 60 seconds. A used-up monthly quota (`quota_exceeded`) and a launch the API failed for good (`upstream_error`) are not retried. Creating, retraining, updating, deleting and cancelling are never retried, because the API cannot deduplicate them yet.

Progress callbacks run on the main actor, so a view model can update its state from them directly.

**Continuing after a failure.** The API launches a scene at most once. If `createAndProcess` stops after creating the scene, before the outcome is known, it throws `SplatError.interrupted`. `resume` continues it without paying again. It reads the scene first, uploads again only if the upload failed, and launches only if nothing was launched, with exactly the request `createAndProcess` sent:

```swift
do {
    scene = try await client.createAndProcess(videoURL: videoURL, arkitPoses: poses)
} catch SplatError.interrupted(let interruption) where interruption.underlying is CancellationError {
    // The task was cancelled (e.g. a SwiftUI view went away). Keep
    // interruption.sceneID: a launched job keeps running.
} catch SplatError.interrupted(let interruption) {
    scene = try await client.resume(interruption)
}
```

Outcomes the server has settled are thrown as themselves and can't be resumed: `SplatError.processingFailed`, `SplatError.cancelled`, and the error of a launch the API failed and refunded. Start over with a new scene.

**Surviving an app restart.** Save the ID `onSceneCreated` passes. It fires as soon as the scene exists, before anything is charged. On relaunch, resume that scene with the same preset and capture. `resume` rebuilds the launch `createAndProcess` sent, so a launch that went through is replayed, not charged again, and then it waits:

```swift
scene = try await client.createAndProcess(videoURL: videoURL, preset: .ultra, arkitPoses: poses, lidarPoints: points) { status, pct in
    progress = pct ?? 0
} onSceneCreated: { id in
    UserDefaults.standard.set(id, forKey: "pendingScene")
}

// After a relaunch:
scene = try await client.resume(sceneID: pendingID, preset: .ultra, arkitPoses: poses, lidarPoints: points)
```

The upload URL isn't kept, so if the app was killed before its upload finished, the API refuses the launch (400) before charging anything: start over.

`processScene` sends `Idempotency-Key: process-<scene ID>` unless you pass your own, so repeating it for a scene with the same inputs replays the original launch.

**Waiting.** `waitForScene` keeps polling through network failures, 5xx and rate limits until its deadline, because they say nothing about the job. Once it has read the scene, it also rides out a short run of 401 or 404, which the API returns when its database blips. After the deadline it looks once more, then throws `SplatError.timeout` (the job may still finish). It throws `SplatError.notStarted` for a scene still `uploading` on two polls in a row.

The polling timeout defaults to 165 minutes, just past the point where the API fails a job that is still running. Tune it with `SplatClient.Configuration`:

```swift
var configuration = SplatClient.Configuration()
configuration.pollingTimeout = 4 * 60 * 60
configuration.maxRetries = 5
let client = SplatClient(apiKey: "s3d_your_api_key", configuration: configuration)
```

### Error Handling

API failures throw `SplatError`; network failures throw `URLError`. Every HTTP error carries a `SplatError.APIError` with the status, the API's error `code` (such as `conflict` or `insufficient_credits`), the `message`, and the `requestID` to quote to support:

```swift
do {
    let scene = try await client.getScene(id: "abc123")
} catch SplatError.unauthorized {
    // Invalid API key
} catch SplatError.notFound(let error) {
    // Scene doesn't exist: error.message
} catch SplatError.rateLimited(let error) where error.code == "quota_exceeded" {
    // Monthly plan limit used up: error.message says how to raise it
} catch SplatError.rateLimited(let error) {
    // Back off; error.retryAfter is the server's requested delay, if sent
} catch SplatError.requestFailed(let error) {
    // Any other status: branch on error.code, log error.requestID
} catch SplatError.timeout {
    // Stopped waiting for processing; the job may still finish
} catch SplatError.processingFailed(let reason) {
    // Pipeline error
} catch SplatError.interrupted(let interruption) {
    // createAndProcess stopped before its outcome was known: client.resume(interruption)
}
```

See [CHANGELOG.md](CHANGELOG.md) for changes since 0.1.0.

## Authentication

Get your API key from the [Splat dashboard](https://splat-3d.com/dashboard). Keys start with `s3d_`.

## License

MIT
