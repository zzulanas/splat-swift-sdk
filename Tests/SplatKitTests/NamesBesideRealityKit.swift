#if canImport(RealityKit)
import RealityKit
import SplatKit

// MARK: - Names beside RealityKit
//
// The same check as NamesBesideSwiftUI.swift, for apps that show a scene in
// RealityKit, which has its own `Scene`. This file only has to compile.

/// RealityKit's `Scene`, unqualified.
private typealias RealityKitScene = Scene

/// Every public SplatKit type, unqualified.
private typealias PublicTypes = (
    SplatClient, SplatError, SplatScene, SceneStatus,
    ScenePreset, SceneParams, ARKitPose, CaptureResult
)
#endif
