#if canImport(SwiftUI)
import SwiftUI
import SplatKit

// MARK: - Names beside SwiftUI
//
// Apps import SwiftUI and SplatKit in the same file. A SplatKit type named
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

/// Every public SplatKit type, unqualified.
private typealias PublicTypes = (
    ARKitPose, CaptureResult, ModelFormat, ScenePage, SceneParams,
    ScenePreset, SceneSequence, SceneStatus, SceneUpdate, SplatClient,
    SplatError, SplatScene, Usage
)
#endif
