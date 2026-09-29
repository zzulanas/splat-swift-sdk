import Foundation

// MARK: - Progress

/// Progress callbacks run on the main actor, so a view model can update its
/// state from them directly.
typealias ProgressHandler = @MainActor @Sendable (SceneStatus, Double?) -> Void

// MARK: - SceneEvidence

/// What is known about a scene before polling starts.
enum SceneEvidence {
    /// Nothing yet: a 401 or 404 on the first read is taken at its word.
    case none
    /// It was just launched or read, so a brief run of 401 or 404 is a server
    /// blip, not a revoked key or a deleted scene.
    case exists
}

// MARK: - PollingTask

/// Polls a scene's status at regular intervals until it reaches a terminal state.
///
/// Backs ``SplatClient/waitForScene(id:onProgress:)``,
/// ``SplatClient/createAndProcess(videoURL:title:preset:arkitPoses:lidarPoints:onProgress:onSceneCreated:)``
/// and ``SplatClient/resume(_:onProgress:)``.
///
///   poll ──> complete ─────────────> return
///     │      failed / cancelled ───> throw (the server's outcome)
///     │      uploading, twice ─────> throw .notStarted (no job exists)
///     │      any other status ─────> wait the interval, poll again
///     └─ fails: network, 5xx, 429 ─> no news; wait the interval (or Retry-After)
///               401 / 404 ─────────> no news for 3 polls once the scene is known
///               other 4xx ─────────> throw (the request itself is wrong)
///   deadline passes ───────────────> one last poll, then throw .timeout
final class PollingTask: Sendable {

    /// How often to poll for status updates (in seconds).
    let interval: TimeInterval

    /// Maximum time to wait before throwing ``SplatError/timeout`` (in seconds).
    let timeout: TimeInterval

    /// Clock and sleep; replaced in tests.
    let timing: Timing

    /// URL failures that no amount of waiting fixes: the request can't be made.
    private static let fatalURLErrors: Set<URLError.Code> = [.badURL, .unsupportedURL]

    /// Consecutive 401/404 answers tolerated for a scene already seen. The API
    /// returns them when its database blips (auth.ts answers a failed key
    /// lookup with 401; getSceneStatus answers a failed query with 404).
    static let toleratedRejections = 3

    /// Polls in a row that must find `uploading` before concluding nothing was
    /// launched. The web app charges and dispatches a moment before it marks a
    /// scene launched, so one sighting isn't proof.
    static let uploadingSightingsForNotStarted = 2

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
    ///   - evidence: Whether the scene is already known to exist.
    ///   - onProgress: Optional callback, on the main actor, after each poll.
    /// - Returns: The final ``SplatScene`` once it is `complete`.
    /// - Throws: ``SplatError/timeout`` if the scene doesn't finish within the timeout.
    ///           ``SplatError/processingFailed(_:)`` if the scene enters the `failed` state.
    ///           ``SplatError/cancelled`` if the scene was cancelled.
    ///           ``SplatError/notStarted`` if the scene stays `uploading`.
    ///           The API error for a rejected request, e.g. ``SplatError/notFound(_:)``.
    ///           `CancellationError` if the task is cancelled.
    func poll(
        sceneId: String,
        using client: APIClient,
        evidence: SceneEvidence,
        onProgress: ProgressHandler? = nil
    ) async throws -> SplatScene {
        let deadline = timing.now().addingTimeInterval(timeout)
        var seen = evidence == .exists
        var rejections = 0
        var uploadingSightings = 0

        while true {
            // Check for task cancellation
            try Task.checkCancellation()

            // One request per poll: the loop does its own waiting, bounded by
            // the deadline, so per-request retries would only overrun it.
            let scene: SplatScene
            do {
                scene = try await client.request(
                    SplatScene.self,
                    path: APIPath.scene(sceneId),
                    method: .get,
                    retry: .never
                )
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                if Self.isRejection(error) {
                    guard seen, rejections < Self.toleratedRejections else {
                        throw error
                    }
                    rejections += 1
                } else if !Self.leavesOutcomeUnknown(error) {
                    throw error
                }

                // An outage says nothing about a job that is already paid
                // for and running: keep waiting, as long as the server asks.
                guard timing.now() < deadline else {
                    throw SplatError.timeout
                }
                let requested = (error as? SplatError)?.apiError?.retryAfter ?? 0
                try await sleep(max(interval, requested), until: deadline)
                continue
            }

            seen = true
            rejections = 0

            // Report progress
            await onProgress?(scene.status, scene.processingPct)

            // Check for terminal states
            switch scene.status {
            case .complete:
                return scene
            case .failed:
                throw SplatError.processingFailed(scene.failureMessage)
            case .cancelled:
                throw SplatError.cancelled
            case .uploading:
                // Only a launch moves a scene past uploading, so no job exists.
                uploadingSightings += 1
                if uploadingSightings >= Self.uploadingSightingsForNotStarted {
                    throw SplatError.notStarted
                }
            default:
                uploadingSightings = 0
            }

            // A poll after the deadline is the last one: a device that slept
            // through the deadline still looks before calling it a timeout.
            guard timing.now() < deadline else {
                throw SplatError.timeout
            }
            try await sleep(interval, until: deadline)
        }
    }

    /// Whether the API refused the read as unauthorized or not found.
    static func isRejection(_ error: Error) -> Bool {
        let status = (error as? SplatError)?.apiError?.statusCode
        return status == HTTPStatus.unauthorized || status == HTTPStatus.notFound
    }

    /// Whether a failed status read leaves the job's outcome unknown, so
    /// waiting goes on: network failures, 5xx, rate limits, and unreadable
    /// responses. A rejected request (any other 4xx) or a URL that can't be
    /// requested ends the wait.
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

// MARK: - Failure Message

extension SplatScene {

    /// Why the server says processing failed.
    var failureMessage: String {
        processingError ?? processingStage ?? "Processing failed."
    }
}
