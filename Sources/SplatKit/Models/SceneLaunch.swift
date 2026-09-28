import Foundation

// MARK: - SceneLaunch

/// The API's acknowledgement that processing was accepted, from
/// ``SplatClient/processScene(id:arkitPoses:lidarPoints:enableLOD:idempotencyKey:)``.
///
/// Once you have it, the scene is launched and charged. Follow its progress
/// with ``SplatClient/waitForScene(id:onProgress:)``.
public struct SceneLaunch: Sendable, Equatable {

    /// The scene being processed.
    public let sceneID: String

    /// Status reported with the launch, normally ``SceneStatus/processing``.
    public let status: SceneStatus

    /// The API's note about the launch, e.g. how long processing usually takes.
    public let message: String

    /// The `Idempotency-Key` the launch was sent with. Sending it again with
    /// the same inputs replays this launch instead of charging again.
    public let idempotencyKey: String
}
