import Foundation

// MARK: - PollingTask

/// Polls a scene's status at regular intervals until it reaches a terminal state.
///
/// Used internally by ``SplatClient/createAndProcess(videoURL:title:preset:arkitPoses:onProgress:)``
/// to wait for processing to complete.
///
/// - Polls every 10 seconds by default.
/// - Times out after 20 minutes (configurable).
/// - Respects Swift Concurrency cancellation.
final class PollingTask: Sendable {

    /// How often to poll for status updates (in seconds).
    let interval: TimeInterval

    /// Maximum time to wait before throwing ``SplatError/timeout`` (in seconds).
    let timeout: TimeInterval

    /// Creates a polling task with the given interval and timeout.
    ///
    /// - Parameters:
    ///   - interval: Seconds between polls. Default is 10.
    ///   - timeout: Maximum wait time in seconds. Default is 1200 (20 minutes).
    init(interval: TimeInterval = 10, timeout: TimeInterval = 1200) {
        self.interval = interval
        self.timeout = timeout
    }

    /// Poll the scene until it reaches a terminal state.
    ///
    /// - Parameters:
    ///   - sceneId: The scene ID to poll.
    ///   - client: The API client to use for requests.
    ///   - onProgress: Optional callback invoked after each poll with the current status and progress percentage.
    /// - Returns: The final ``Scene`` in a terminal state (`complete` or `failed`).
    /// - Throws: ``SplatError/timeout`` if the scene doesn't complete within the timeout.
    ///           ``SplatError/processingFailed(_:)`` if the scene enters the `failed` state.
    ///           ``SplatError/cancelled`` if the task is cancelled.
    func poll(
        sceneId: String,
        using client: APIClient,
        onProgress: ((SceneStatus, Double?) -> Void)? = nil
    ) async throws -> Scene {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            // Check for task cancellation
            try Task.checkCancellation()

            let scene: Scene = try await client.request(
                Scene.self,
                path: "/v1/scenes/\(sceneId)",
                method: "GET"
            )

            // Report progress
            onProgress?(scene.status, scene.processingPct)

            // Check for terminal states
            switch scene.status {
            case .complete:
                return scene
            case .failed:
                throw SplatError.processingFailed(
                    scene.processingStage ?? "Processing failed."
                )
            case .cancelled:
                throw SplatError.cancelled
            default:
                break
            }

            // Wait before next poll
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }

        throw SplatError.timeout
    }
}
