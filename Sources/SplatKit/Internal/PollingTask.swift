import Foundation

// MARK: - PollingTask

/// Polls a scene's status at regular intervals until it reaches a terminal state.
///
/// Backs ``SplatClient/waitForScene(id:onProgress:)`` and
/// ``SplatClient/createAndProcess(videoURL:title:preset:arkitPoses:lidarPoints:onProgress:)``.
///
/// - Interval and timeout come from ``SplatClient/Configuration``.
/// - Each status read is a GET, so transient failures are retried.
/// - Respects Swift Concurrency cancellation.
final class PollingTask: Sendable {

    /// How often to poll for status updates (in seconds).
    let interval: TimeInterval

    /// Maximum time to wait before throwing ``SplatError/timeout`` (in seconds).
    let timeout: TimeInterval

    /// Clock and sleep; replaced in tests.
    let timing: Timing

    /// Creates a polling task with the given interval and timeout.
    ///
    /// - Parameters:
    ///   - interval: Seconds between polls.
    ///   - timeout: Maximum wait time in seconds.
    ///   - timing: Clock and sleep to use.
    init(interval: TimeInterval, timeout: TimeInterval, timing: Timing = .live) {
        self.interval = interval
        self.timeout = timeout
        self.timing = timing
    }

    /// Poll the scene until it reaches a terminal state.
    ///
    /// - Parameters:
    ///   - sceneId: The scene ID to poll.
    ///   - client: The API client to use for requests.
    ///   - onProgress: Optional callback invoked after each poll with the current status and progress percentage.
    /// - Returns: The final ``Scene`` once it is `complete`.
    /// - Throws: ``SplatError/timeout`` if the scene doesn't finish within the timeout.
    ///           ``SplatError/processingFailed(_:)`` if the scene enters the `failed` state.
    ///           ``SplatError/cancelled`` if the scene was cancelled.
    ///           `CancellationError` if the task is cancelled.
    func poll(
        sceneId: String,
        using client: APIClient,
        onProgress: ((SceneStatus, Double?) -> Void)? = nil
    ) async throws -> Scene {
        let deadline = timing.now().addingTimeInterval(timeout)

        while timing.now() < deadline {
            // Check for task cancellation
            try Task.checkCancellation()

            let scene: Scene = try await client.request(
                Scene.self,
                path: APIPath.scene(sceneId),
                method: .get
            )

            // Report progress
            onProgress?(scene.status, scene.processingPct)

            // Check for terminal states
            switch scene.status {
            case .complete:
                return scene
            case .failed:
                throw SplatError.processingFailed(
                    scene.processingError ?? scene.processingStage ?? "Processing failed."
                )
            case .cancelled:
                throw SplatError.cancelled
            default:
                break
            }

            // Wait before next poll
            try await timing.sleep(interval)
        }

        throw SplatError.timeout
    }
}
