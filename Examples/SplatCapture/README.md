# SplatCapture Example App

A minimal SwiftUI app demonstrating the [SplatKit](../../) SDK. Records video
with ARKit LiDAR poses and uploads to the Splat API for 3D Gaussian Splat
processing.

## Setup

1. Open `SplatCapture.xcodeproj` in Xcode
2. The project references the SplatKit SDK as a local SPM package (two
   directories up). Xcode resolves it automatically.
3. Open `ContentView.swift` and replace the placeholder API key:
   ```swift
   let apiKey = "s3d_REPLACE_ME"  // <- your key here
   ```
4. Select your physical iPhone as the run destination and hit **Run**

### Getting an API Key

1. Sign up at [splat-3d.com/dashboard](https://splat-3d.com/dashboard)
2. Create a new API key — it starts with `s3d_`
3. Copy it into `ContentView.swift` as shown above

## Device Requirements

- **iPhone 12 Pro or newer** (requires LiDAR scanner)
- iPad Pro with LiDAR also works
- iOS 16.0+
- Camera and motion permissions are requested on first launch

The app will show an error if you try to run on a device without LiDAR.

## Usage

1. Tap **Start Scan** — the camera view opens with a gold mesh overlay showing
   surfaces detected by the LiDAR scanner
2. Slowly walk around the scene you want to capture (15–60 seconds is ideal)
3. Watch the **pose counter** and **frame counter** in the top-right, and the
   **tracking quality** indicator above the stop button
4. Tap **Stop & Upload** when done
5. The app uploads the video + ARKit poses, triggers processing, and polls for
   completion with a progress bar
6. When done, tap **Open in Safari** to view and interact with your 3D splat —
   rotate, zoom, and pan around the reconstructed scene

## How It Works

This app demonstrates three key SplatKit APIs:

- **`SplatScanner`** — wraps ARKit + AVAssetWriter to capture video and camera
  poses simultaneously. Exposes the `ARSession` so you can show a live camera
  preview.
- **`SplatClient.createAndProcess()`** — the high-level convenience method that
  creates a scene, uploads the video, triggers processing, and polls until
  complete.
- **`ARKitPose`** — the pose format sent to the API. Each pose includes the 4x4
  camera transform, 3x3 intrinsics, image dimensions, and a filename.

See `ContentView.swift` for the full integration — key sections are marked with
`// MARK: - SplatKit Integration` comments.
