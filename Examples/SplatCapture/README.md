# SplatCapture Example App

A minimal SwiftUI app demonstrating the [Splat3D](../../) SDK. Records video
with ARKit LiDAR poses and uploads to the Splat API for 3D Gaussian Splat
processing, then shows the result natively with
[SplatKit](https://github.com/Xget7/splatkit-ios).

## Setup

1. Open `SplatCapture.xcodeproj` in Xcode
2. The project references the Splat3D SDK as a local SPM package (two
   directories up), and SplatKit `0.1.0-beta.1` from GitHub, which downloads a
   prebuilt XCFramework. Xcode resolves both automatically; the first build
   needs a network connection.
3. Give the app your API key. It is read at runtime from the `SPLAT_API_KEY`
   build setting, which comes from `Secrets.xcconfig`. Git ignores that file:
   ```sh
   cd Examples/SplatCapture
   cp Secrets.example.xcconfig Secrets.xcconfig
   # then set SPLAT_API_KEY = s3d_... in Secrets.xcconfig
   ```
   Never put a key in source files: this repository is public, and CI fails on
   anything that looks like one. Without a key, the app says so when you tap
   **Start Scan** or open **Recent Scenes**.
4. Select your physical iPhone as the run destination and hit **Run**

### Getting an API Key

1. Sign up at [splat-3d.com/dashboard](https://splat-3d.com/dashboard)
2. Create a new API key — it starts with `s3d_`
3. Put it in `Secrets.xcconfig` as shown above

## Device Requirements

- **iPhone 12 Pro or newer** (requires LiDAR scanner)
- iPad Pro with LiDAR also works for capture; viewing in 3D needs an M1 iPad Pro
  or newer (see below)
- iOS 17.0+. SplatKit requires it; the Splat3D SDK itself still supports iOS 16
- Camera and motion permissions are requested on first launch

The app will show an error if you try to run on a device without LiDAR.

**View in 3D** draws with Metal on Apple GPU family 7: A14, M1 or newer, on a
physical device. The app goes by SplatKit's `SplatMetalView.isAvailable`,
which is also false when SplatKit's Metal setup fails (shader compile, command
queue or buffers). Where it's false, as in the Simulator, the app downloads
the scene and says it can't draw it.

## Usage

1. Pick a preset. **Fast** is the default: the quickest and cheapest, good for
   testing. The choice is remembered.
2. Tap **Start Scan** — the camera view opens with a gold mesh overlay showing
   surfaces detected by the LiDAR scanner
3. Slowly walk around the scene you want to capture (15–60 seconds is ideal)
4. Watch the **pose counter** and **frame counter** in the top-right, and the
   **tracking quality** indicator above the stop button
5. Tap **Stop & Upload** when done
6. The app uploads the video + ARKit poses, triggers processing, and polls for
   completion with a progress bar
7. When done, tap **View in 3D** to explore it in the app, or **Open in
   Safari** for the web viewer

To skip capturing, tap **Recent Scenes** on the start screen: it lists the
account's latest completed scenes, each with **View in 3D**.

## Viewing in 3D

The viewer downloads the scene's SPZ, the compressed format SplatKit reads,
showing the bytes as they arrive, then hands the file to SplatKit.

- **Orbit** (default): drag to circle the scene, pinch to move in or out
- **Look**: drag to turn on the spot; hold the arrows to move forward or back
- **Flip**: turns the picture upside down, see below
- **Reset** (the target icon): back to the starting view
- The line at the top is SplatKit's frame rate and splats drawn

What can go wrong, and what the app says:

- **This scene has no SPZ**: the API answers 404 for a scene without one.
  Scenes processed before SPZ export, or whose SPZ conversion failed, have none.
- **SPZ download not available on this server yet**: the API rejects
  `format=spz` (a 400 naming `format`) until it serves SPZ downloads.
- **SplatKit couldn't load this scene**: SplatKit refused the file. Its
  message follows.

### Which way is up

Splat3D's pipeline turns every scene so +Y is up, the convention of
PlayCanvas, three.js and SuperSplat, and writes the SPZ with those coordinates
as they are. SplatKit has no orientation setting: it reads every SPZ as World
Labs files are laid out, +Y down, and turns it half a turn about X. Splat3D
scenes would come out upside down, so the viewer starts with **Flip** on,
which rotates the picture half a turn on screen. Touches turn with it, so
dragging still follows the picture. Turn **Flip** off to see SplatKit's own
orientation.

## How It Works

This app demonstrates these Splat3D APIs:

- **`SplatScanner`** — wraps ARKit + AVAssetWriter to capture video and camera
  poses simultaneously. Exposes the `ARSession` so you can show a live camera
  preview.
- **`SplatClient.createAndProcess()`** — the high-level convenience method that
  creates a scene, uploads the video, triggers processing, and polls until
  complete.
- **`ARKitPose`** — the pose format sent to the API. Each pose includes the 4x4
  camera transform, 3x3 intrinsics, image dimensions, and a filename.
- **`SplatClient.listScenePage()`** — the Recent Scenes list.
- **`SplatClient.downloadScene(id:format:)`** — fetches the SPZ. The SDK
  doesn't name SPZ yet, so the app passes `ModelFormat(rawValue: "spz")`. It
  gives the client a `URLSession` whose delegate watches the download's bytes.

See `ContentView.swift` for the full integration — key sections are marked with
`// MARK: - Splat3D Integration` comments. The viewer is in `SceneViewer.swift`
and `SplatWorldView.swift`.

## Credits

3D viewing uses [SplatKit](https://github.com/Xget7/splatkit-ios), copyright
(c) 2026 Juan Ignacio Andrade, under the MIT License. Its XCFramework carries
the notices of what it bundles (SPZ, Zstandard, JSON for Modern C++ and
splat-transform) in `SplatKitCore.xcframework/Notices`.
