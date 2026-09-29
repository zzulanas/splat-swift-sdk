import Foundation

// MARK: - Interruption

extension SplatError {

    /// Where ``SplatClient/createAndProcess(videoURL:title:preset:arkitPoses:lidarPoints:onProgress:onSceneCreated:)``
    /// stopped before its outcome was known. Continue it with
    /// ``SplatClient/resume(_:onProgress:)``.
    ///
    /// `resume` reads the scene first and does only what is missing, sending
    /// exactly the request `createAndProcess` sent, so a scene is charged at
    /// most once:
    ///
    /// | Phase | What was charged | What `resume` does |
    /// |---|---|---|
    /// | ``Phase/upload`` | No credits (the scene used one monthly scene creation) | Uploads the same file again, then launches and waits |
    /// | ``Phase/launch`` | At most once, if the launch got through | Launches only if nothing was launched, then waits |
    /// | ``Phase/wait`` | The launch | Waits again |
    ///
    /// Outcomes the server has settled are never interruptions: a failed or
    /// cancelled scene is thrown as ``SplatError/processingFailed(_:)`` or
    /// ``SplatError/cancelled``, and a launch the API failed for good (and
    /// refunded) as its own error. Those scenes can't be continued.
    ///
    /// ```swift
    /// do {
    ///     scene = try await client.createAndProcess(videoURL: video, arkitPoses: poses)
    /// } catch SplatError.interrupted(let interruption) {
    ///     scene = try await client.resume(interruption)
    /// }
    /// ```
    public struct Interruption: Sendable {

        /// The scene that `createAndProcess` created.
        public let sceneID: String

        /// The step that stopped: what was charged, and where `resume` picks up.
        public let phase: Phase

        /// The `Idempotency-Key` for this scene's launch, `process-<scene ID>`.
        public let idempotencyKey: String

        /// Why it stopped: a network or API error, ``SplatError/timeout``, or
        /// `CancellationError` when the task was cancelled.
        public let underlying: Error

        /// What `createAndProcess` sent, so `resume` can repeat it exactly.
        /// `nil` for an interruption made with the public initializer.
        let request: ResumableRequest?

        /// Create an interruption, e.g. for a test double. Without the
        /// original request, ``SplatClient/resume(_:onProgress:)`` can only wait.
        public init(sceneID: String, phase: Phase, idempotencyKey: String, underlying: Error) {
            self.init(sceneID: sceneID, phase: phase, idempotencyKey: idempotencyKey, underlying: underlying, request: nil)
        }

        init(sceneID: String, phase: Phase, idempotencyKey: String, underlying: Error, request: ResumableRequest?) {
            self.sceneID = sceneID
            self.phase = phase
            self.idempotencyKey = idempotencyKey
            self.underlying = underlying
            self.request = request
        }

        /// The same interruption, stopped again for another reason.
        func replacing(underlying: Error) -> Interruption {
            Interruption(sceneID: sceneID, phase: phase, idempotencyKey: idempotencyKey, underlying: underlying, request: request)
        }

        /// The cause, then the scene, e.g. "Cancelled. Scene ID: a1b2c3d4e5f6."
        var summary: String {
            let cause = underlying is CancellationError ? "Cancelled." : underlying.localizedDescription
            return "\(cause) Scene ID: \(sceneID)."
        }
    }
}

// MARK: - Interruption.Phase

extension SplatError.Interruption {

    /// A step of `createAndProcess`. Steps may be added, so `switch` with a `default`.
    public struct Phase: RawRepresentable, Hashable, Sendable, CustomStringConvertible {

        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// Uploading the source. No credits were charged, but creating the
        /// scene used one of the plan's monthly scene creations. `resume`
        /// uploads to the same scene while its upload URL is valid, about an
        /// hour; after that the storage rejects the upload (403): start over.
        public static let upload = Phase(rawValue: "upload")

        /// Starting processing failed, or its outcome is unknown. `resume`
        /// launches only if nothing was launched, with the identical request
        /// and key, so the scene is charged at most once. If the API refused
        /// the launch, e.g. with `insufficient_credits`, fix that first.
        public static let launch = Phase(rawValue: "launch")

        /// Waiting for the result. Processing was accepted and charged, and
        /// the job keeps running: `resume` waits again.
        public static let wait = Phase(rawValue: "wait")

        public var description: String {
            rawValue
        }
    }
}

// MARK: - ResumableRequest

/// The parts of a `createAndProcess` call that `resume` repeats: the file and
/// where to upload it, and the exact launch body. The API hashes the body, so
/// a launch repeated with anything less (a lost `enable_lod` or LiDAR points)
/// would be a different request: a 409, or a job without them.
struct ResumableRequest: Sendable {
    let videoURL: URL
    let uploadURL: URL
    let launch: ProcessSceneBody
}
