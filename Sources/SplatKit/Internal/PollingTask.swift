import Foundation

// MARK: - PollingTask

/// Polls a scene's status at regular intervals until it reaches a terminal state.
///
/// Backs ``SplatClient/waitForScene(id:onProgress:)`` and
/// ``SplatClient/createAndProcess(videoURL:title:preset:arkitPoses:lidarPoints:onProgress:)``.
///
///   poll ──> complete ─────────────> return
///     │      failed / cancelled ───> throw (the server's outcome)
///     │      uploading ────────────> throw .notStarted (no job exists)
///     │      any other status ─────> wait the interval, poll again
///     └─ fails: network, 5xx, 429 ─> no news; wait the interval (or Retry-After)
///               other 4xx ─────────> throw (the request itself is wrong)
///   deadline passes ───────────────> throw .timeout (the job may still finish)
final class PollingTask: Sendable {

    /// How often to poll for status updates (in seconds).
    let interval: TimeInterval

    /// Maximum time to wait before throwing ``SplatError/timeout`` (in seconds).
    let timeout: TimeInterval

    /// Clock and sleep; replaced in tests.
    let timing: Timing

    /// URL failures that no amount of waiting fixes: the request can't be made.
    private static let fatalURLErrors: Set<URLError.Code> = [.badURL, .unsupportedURL]

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
    ///           ``SplatError/notStarted`` if the scene is still `uploading`.
    ///           The API error for a rejected request, e.g. ``SplatError/notFound(_:)``.
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

            let scene: Scene
            do {
                scene = try await client.request(
                    Scene.self,
                    path: APIPath.scene(sceneId),
                    method: .get
                )
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                guard Self.leavesOutcomeUnknown(error) else {
                    throw error
                }

                // An outage says nothing about a job that is already paid
                // for and running: keep waiting, as long as the server asks.
                let requested = (error as? SplatError)?.apiError?.retryAfter ?? 0
                try await sleep(max(interval, requested), until: deadline)
                continue
            }

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
            case .uploading:
                // Only a launch moves a scene past uploading, so no job exists.
                throw SplatError.notStarted
            default:
                break
            }

            // Wait before next poll
            try await sleep(interval, until: deadline)
        }

        throw SplatError.timeout
    }

    /// Whether a failed status read leaves the job's outcome unknown, so
    /// waiting goes on: network failures, 5xx, rate limits, and unreadable
    /// responses. A rejected request (any other 4xx, e.g. a revoked key or a
    /// deleted scene) or a URL that can't be requested ends the wait.
    static func leavesOutcomeUnknown(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return !fatalURLErrors.contains(urlError.code)
        }
        guard (error as? SplatError)?.apiError != nil else {
            return true
        }
        return APIClient.isTransient(error)
    }

    /// Sleep for `seconds`, but never past `deadline`.
    private func sleep(_ seconds: TimeInterval, until deadline: Date) async throws {
        let remaining = deadline.timeIntervalSince(timing.now())
        try await timing.sleep(max(0, min(seconds, remaining)))
    }
}
