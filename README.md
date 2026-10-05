# Splat3D

Swift SDK for the [Splat](https://splat-3d.com) 3D Gaussian Splatting API. Turn video into interactive 3D scenes with native ARKit camera pose capture.

## Requirements

- iOS 16.0+
- Swift 5.10+
- Xcode 15.3+

## Installation

Add Splat3D to your project using Swift Package Manager:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/zzulanas/splat-swift-sdk", branch: "main")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [.product(name: "Splat3D", package: "splat-swift-sdk")]
    )
]
```

Or in Xcode: **File > Add Package Dependencies**, enter the repository URL, and pick the `main` branch.

1.0.0 isn't tagged yet, so use `branch: "main"` until it is.

## Quick Start

```swift
import Splat3D

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
import Splat3D

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

## View scenes in 3D

Pass `.spz` to `downloadScene` to get Niantic's compressed splat format, which native renderers such as [SplatKit](https://github.com/Xget7/splatkit-ios) load:

```swift
let file = try await client.downloadScene(id: scene.id, format: .spz)
```

Older scenes, and scenes whose SPZ conversion failed, have no SPZ, so the call throws `SplatError.notFound` for them. The API never sends another format in its place.

The [SplatCapture](Examples/SplatCapture) example app draws the file with [SplatKit](https://github.com/Xget7/splatkit-ios), an MIT-licensed Metal renderer for iOS. The Splat3D package doesn't depend on SplatKit. Only the example app does.

To draw a scene in your own app, hand the downloaded file to SplatKit's `SplatMetalView`, as [SceneViewer.swift](Examples/SplatCapture/SplatCapture/SceneViewer.swift) and [SplatWorldView.swift](Examples/SplatCapture/SplatCapture/SplatWorldView.swift) do.

SplatKit assumes the World Labs layout, +Y down, and rotates every SPZ 180 degrees about the X axis. The Splat3D pipeline makes scenes +Y up, so they show upside down. The example turns the picture back with its Flip switch, which starts on and rotates the view 180 degrees on screen, and an app of your own needs the same half turn. The pipeline doesn't get every scene upright yet. Older ARKit scenes can be turned about 90 degrees, and Flip can't correct that. At least one video uploaded without ARKit poses still shows upside down with Flip on.

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
| `downloadScene(id:format:)` | Download the 3D model (SOG, PLY or SPZ) to a temporary file |
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

Progress callbacks run on the main actor, so a view model can update its state from them directly. Don't block the main thread waiting for a call that takes one, with a semaphore for example: the callback can't run, so the call never returns.

**Continuing after a failure.** The API launches a scene at most once. If `createAndProcess` stops after creating the scene, before the outcome is known, it throws `SplatError.interrupted`. `resume` continues it without paying again, with exactly the request `createAndProcess` sent. If the upload or the launch stopped, it launches: the API replays a launch that went through, and refuses one whose upload never arrived before charging anything, in which case `resume` uploads the file again first. If the wait stopped, it waits.

```swift
do {
    scene = try await client.createAndProcess(videoURL: videoURL, arkitPoses: poses)
} catch SplatError.interrupted(let interruption) where interruption.underlying is CancellationError {
    // The task was cancelled (e.g. a SwiftUI view went away). Keep
    // interruption.sceneID and resume later: a launched job keeps running,
    // and resume finishes an upload or launch that was cut short.
} catch SplatError.interrupted(let interruption) {
    scene = try await client.resume(interruption)
}
```

Any other error after the scene exists ends the run, and no resume can continue it:

| Error | What happened |
|---|---|
| `SplatError.processingFailed` | The server failed the scene, including a launch it failed, and refunds it. Rarely, a job the stale-job sweep failed still completes, so check `getScene` before starting over. |
| `SplatError.cancelled` | The scene was cancelled. The server doesn't refund a job that had started. |
| `SplatError.notFound` | The scene was deleted. A 404 while waiting counts only once a replay of the launch also finds no scene, since the API answers a failed read with 404 too. |
| `SplatError.uploadFailed` with `.fileDoesNotExist` or `.zeroByteResource` | The capture is missing or empty, so nothing was sent. It's checked before the scene is created too. |
| `SplatError.requestFailed` with a 4xx | Storage refused the upload URL (403 once it expires, after an hour), or the API refused the launch request itself (400). |

**Surviving an app restart.** Save the ID `onSceneCreated` passes, which fires as soon as the scene exists, before anything is charged. Save the capture the launch is built from too. On relaunch, resume that scene with the same preset and capture. `resume` rebuilds the launch `createAndProcess` sent, so a launch that went through is replayed, not charged again, and then it waits:

```swift
scene = try await client.createAndProcess(videoURL: videoURL, preset: .ultra, arkitPoses: poses, lidarPoints: points) { status, pct in
    progress = pct ?? 0
} onSceneCreated: { id in
    // Keep the ID and what the launch is built from.
    UserDefaults.standard.set(id, forKey: "pendingScene")
    try? JSONEncoder().encode(Capture(poses: poses, points: points)).write(to: captureFile)
}

// After a relaunch, with the saved capture:
let saved = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: captureFile))
scene = try await client.resume(sceneID: pendingID, preset: .ultra, arkitPoses: saved.poses, lidarPoints: saved.points)
```

`Capture` is your own `Codable` struct holding the poses and points (`ARKitPose` is `Codable`). `resume(sceneID:…)` requires every argument that shapes the launch, `nil` included, so a restart can't launch a different job by leaving one out.

The upload URL isn't kept, so if the app was killed before its upload finished, the API refuses the launch (400) before charging anything: start over.

`processScene` sends `Idempotency-Key: process-<scene ID>` unless you pass your own, so repeating it for a scene with the same inputs replays the original launch.

**Waiting.** `waitForScene` keeps polling through network failures, 5xx and rate limits until its deadline, because they say nothing about the job. Once it has read the scene, it also rides out 401 and 404 for five minutes, which the API returns when its database blips. After the deadline it looks once more, and again if that look fails, then throws `SplatError.timeout` (the job may still finish). It throws `SplatError.notStarted` for a scene still `uploading` on two polls in a row.

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

[MIT](LICENSE)
