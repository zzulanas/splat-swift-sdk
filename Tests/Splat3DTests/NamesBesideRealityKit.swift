#if canImport(RealityKit)
import RealityKit
import Splat3D

// MARK: - Names beside RealityKit
//
// The same check as NamesBesideSwiftUI.swift, for apps that show a scene in
// RealityKit, which has its own `Scene`. This file only has to compile.

/// RealityKit's `Scene`, unqualified.
private typealias RealityKitScene = Scene

/// Every public Splat3D type, unqualified.
private typealias PublicTypes = (
    ARKitPose, CaptureResult, ModelFormat, SceneLaunch, ScenePage,
    SceneParams, ScenePreset, SceneSequence, SceneStatus, SceneUpdate,
    SplatClient, SplatError, SplatScene, Usage
)
#endif
