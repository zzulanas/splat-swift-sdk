import Foundation

// MARK: - Interruption

extension SplatError {

    /// Where ``SplatClient/createAndProcess(videoURL:title:preset:arkitPoses:lidarPoints:onProgress:)``
    /// stopped after creating its scene, and how to resume without paying twice.
    ///
    /// | Phase | Charged | Resume |
    /// |---|---|---|
    /// | ``Phase/upload`` | No | Start over; the upload URL isn't kept. |
    /// | ``Phase/launch`` | At most once | `processScene` with the same inputs and ``idempotencyKey``, then `waitForScene`. |
    /// | ``Phase/wait`` | Yes | `waitForScene`. The job keeps running. |
    ///
    /// ```swift
    /// } catch SplatError.interrupted(let interruption) {
    ///     switch interruption.phase {
    ///     case .launch:
    ///         _ = try await client.processScene(
    ///             id: interruption.sceneID,
    ///             arkitPoses: poses,
    ///             idempotencyKey: interruption.idempotencyKey
    ///         )
    ///         scene = try await client.waitForScene(id: interruption.sceneID)
    ///     case .wait:
    ///         scene = try await client.waitForScene(id: interruption.sceneID)
    ///     default:
    ///         break  // .upload: nothing was charged, so start over.
    ///     }
    /// }
    /// ```
    public struct Interruption: Sendable {

        /// The scene that `createAndProcess` created.
        public let sceneID: String

        /// The step that failed. It decides what was charged and how to resume.
        public let phase: Phase

        /// The `Idempotency-Key` for this scene's launch.
        ///
        /// Pass it to ``SplatClient/processScene(id:arkitPoses:lidarPoints:enableLOD:idempotencyKey:)``
        /// with the same inputs: the API replays a launch that went through
        /// and starts one that didn't, so the scene is charged at most once.
        public let idempotencyKey: String

        /// Why it stopped: an API or network error, ``SplatError/timeout``,
        /// ``SplatError/processingFailed(_:)``, or `CancellationError` when the
        /// task was cancelled.
        public let underlying: Error

        /// Create an interruption, e.g. for a test double.
        public init(sceneID: String, phase: Phase, idempotencyKey: String, underlying: Error) {
            self.sceneID = sceneID
            self.phase = phase
            self.idempotencyKey = idempotencyKey
            self.underlying = underlying
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

        /// Uploading the source. Nothing was charged. The presigned upload URL
        /// isn't kept, so start over; ``SplatClient/deleteScene(id:)`` removes
        /// the unused scene.
        public static let upload = Phase(rawValue: "upload")

        /// Starting processing. The launch may or may not have gone through:
        /// call `processScene` again with the same inputs and
        /// ``SplatError/Interruption/idempotencyKey`` to replay or start it,
        /// charged at most once. If the API rejected the launch, e.g. with
        /// `insufficient_credits`, fix that first.
        public static let launch = Phase(rawValue: "launch")

        /// Waiting for the result. Processing was accepted and charged, and
        /// the job keeps running: call ``SplatClient/waitForScene(id:onProgress:)``.
        public static let wait = Phase(rawValue: "wait")

        public var description: String {
            rawValue
        }
    }
}
