# SplatKit

Swift SDK for the [Splat](https://splat-3d.com) 3D Gaussian Splatting API. Turn video into interactive 3D scenes with native ARKit camera pose capture.

## Requirements

- iOS 16.0+
- Swift 5.9+
- Xcode 15+

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
| `processScene(id:arkitPoses:enableLOD:)` | Trigger GPU processing |
| `getScene(id:)` | Get scene status and metadata |
| `listScenes()` | List all scenes |
| `deleteScene(id:)` | Delete a scene and all files |
| `createAndProcess(videoURL:title:preset:arkitPoses:onProgress:)` | Full flow in one call |

### ScenePreset

| Preset | Resolution | Iterations | Time |
|--------|-----------|------------|------|
| `.fast` | 800px | 3K | ~3 min |
| `.standard` | 1600px | 7K | ~13 min |
| `.quality` | 1600px | 15K | ~25 min |
| `.ultra` | full-res | 30K | ~45 min |

### Error Handling

All methods throw `SplatError`:

```swift
do {
    let scene = try await client.getScene(id: "abc123")
} catch SplatError.unauthorized {
    // Invalid API key
} catch SplatError.notFound(let message) {
    // Scene doesn't exist
} catch SplatError.rateLimited {
    // Back off and retry
} catch SplatError.timeout {
    // Processing took too long
} catch SplatError.processingFailed(let reason) {
    // Pipeline error
}
```

## Authentication

Get your API key from the [Splat dashboard](https://splat-3d.com/dashboard). Keys start with `s3d_`.

## License

MIT
