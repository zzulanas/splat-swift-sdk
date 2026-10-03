#if canImport(SwiftUI)
import SwiftUI
import Splat3D

// MARK: - Names beside SwiftUI
//
// Apps import SwiftUI and Splat3D in the same file. A Splat3D type named
// like a SwiftUI one makes every unqualified use of that name ambiguous,
// down to `var body: some Scene` in the app's entry point. This file only
// has to compile.

private struct ViewerApp: App {

    var body: some Scene {
        WindowGroup {
            Text("Scenes")
        }
    }
}

/// Every public Splat3D type, unqualified.
private typealias PublicTypes = (
    ARKitPose, CaptureResult, ModelFormat, SceneLaunch, ScenePage,
    SceneParams, ScenePreset, SceneSequence, SceneStatus, SceneUpdate,
    SplatClient, SplatError, SplatScene, Usage
)
#endif
