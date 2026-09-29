import Foundation
import SplatKit

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
            print("Cancelled; scene \(interruption.sceneID) continues on the server")
        } catch SplatError.interrupted(let interruption) {
            _ = try await client.resume(interruption) { status, _ in
                self.status = status.rawValue
            }
        }
    }

    /// The README's restart recipe, with both trailing closures.
    func surviveRestart(videoFileURL: URL, poses: [ARKitPose], pendingID: String) async throws {
        var scene = try await client.createAndProcess(videoURL: videoFileURL, arkitPoses: poses) { status, pct in
            self.progress = pct ?? 0
        } onSceneCreated: { id in
            UserDefaults.standard.set(id, forKey: "pendingScene")
        }

        do {
            scene = try await client.waitForScene(id: pendingID)
        } catch SplatError.notStarted {
            _ = try await client.processScene(id: pendingID, arkitPoses: poses)
            scene = try await client.waitForScene(id: pendingID)
        }
        print(scene.id)
    }
}
