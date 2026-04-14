# SplatCapture Example App

A minimal SwiftUI app demonstrating the SplatKit SDK. Records video with ARKit
LiDAR poses and uploads to the Splat API for 3D Gaussian Splat processing.

## Setup

1. Open `SplatCapture.xcodeproj` in Xcode
2. The project references the SplatKit SDK as a local package (two directories up).
   Xcode should resolve it automatically.
3. Open `ContentView.swift` and replace the placeholder API key:
   ```swift
   let apiKey = "s3d_REPLACE_ME"  // <- Put your real key here
   ```
4. Select your physical iPhone as the run destination and hit Run

## Device Requirements

- **iPhone 12 Pro or newer** (requires LiDAR scanner)
- iPad Pro with LiDAR also works
- iOS 16.0+
- Camera and motion permissions will be requested on first launch

## Usage

1. Tap **Start Scan** and slowly walk around the scene you want to capture
2. The pose counter shows how many camera poses have been sampled (~10fps)
3. Tap **Stop & Upload** when done (15-60 seconds of scanning is ideal)
4. The app uploads the video, triggers processing, and polls for completion
5. When done, tap **Open in Safari** to view your 3D splat

## Get an API Key

Sign up at [splat-3d.com/dashboard](https://splat-3d.com/dashboard) to generate
an API key (starts with `s3d_`).
