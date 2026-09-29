import Foundation
import SplatKit
import SwiftUI

/// A main-actor view model, as a SwiftUI app would have.
@MainActor
final class ScanModel {

    private let client = SplatClient(apiKey: "s3d_example")
    private(set) var status = ""
    private(set) var progress = 0.0

    /// The README quick start, verbatim.
    func quickStart(videoFileURL: URL) async throws {
        let scene = try await client.createAndProcess(
            videoURL: videoFileURL,
            title: "Living Room Tour",
            preset: .standard
        ) { status, progress in
            print("\(status.rawValue): \(progress ?? 0)%")
        }

        print("View your scene: \(scene.viewerURL!)")
    }

    /// Updating main-actor state straight from the callback.
    func track(videoFileURL: URL) async throws {
        _ = try await client.createAndProcess(videoURL: videoFileURL) { status, pct in
            self.status = status.rawValue
            self.progress = pct ?? 0
        }
    }

    /// Examples/SplatCapture's closure shape.
    func exampleApp(videoFileURL: URL) async throws {
        _ = try await client.createAndProcess(videoURL: videoFileURL) { [weak self] status, pct in
            Task { @MainActor in
                self?.status = status.rawValue
                self?.progress = pct ?? 0
            }
        }
    }

    /// Picking a scene back up after an app restart.
    func resumeAfterRestart(sceneID: String) async throws {
        _ = try await client.waitForScene(id: sceneID) { status, _ in
            self.status = status.rawValue
        }
    }

    /// Saving the scene ID before the charge, to recover after being killed.
    func saveSceneID(videoFileURL: URL) async throws {
        _ = try await client.createAndProcess(videoURL: videoFileURL, onProgress: { status, pct in
            self.status = status.rawValue
            self.progress = pct ?? 0
        }, onSceneCreated: { id in
            UserDefaults.standard.set(id, forKey: "pendingScene")
        })
    }

    /// Continuing an interrupted createAndProcess.
    func resume(videoFileURL: URL) async throws {
        do {
            _ = try await client.createAndProcess(videoURL: videoFileURL)
        } catch SplatError.interrupted(let interruption) where interruption.underlying is CancellationError {
            print("Cancelled; resume scene \(interruption.sceneID) later")
        } catch SplatError.interrupted(let interruption) {
            _ = try await client.resume(interruption) { status, _ in
                self.status = status.rawValue
            }
        }
    }

    /// The README's restart recipe, with both trailing closures.
    func surviveRestart(videoFileURL: URL, poses: [ARKitPose], points: [[Float]], pendingID: String) async throws {
        var scene: SplatScene = try await client.createAndProcess(
            videoURL: videoFileURL,
            preset: .ultra,
            arkitPoses: poses,
            lidarPoints: points
        ) { status, pct in
            self.progress = pct ?? 0
        } onSceneCreated: { id in
            UserDefaults.standard.set(id, forKey: "pendingScene")
        }

        // After a relaunch:
        scene = try await client.resume(sceneID: pendingID, preset: .ultra, arkitPoses: poses, lidarPoints: points) { status, _ in
            self.status = status.rawValue
        }
        print(scene.id)
    }
}

/// A view holding a scene in SwiftUI state, beside SwiftUI's own `Scene`.
struct SceneView: View {

    let client: SplatClient
    let videoFileURL: URL
    @State private var scene: SplatScene?

    var body: some View {
        Text(scene?.id ?? "Processing")
            .task {
                scene = try? await client.createAndProcess(videoURL: videoFileURL)
            }
    }
}
