import Foundation

// MARK: - Create Scene Response (internal)

/// Response from `POST /v1/scenes`.
struct CreateSceneData: Decodable {
    let sceneId: String
    let uploadUrl: String
}

// MARK: - Process Scene Response (internal)

/// Response from `POST /v1/scenes/{id}/process`.
struct ProcessSceneData: Decodable {
    let status: String
    let sceneId: String
    let message: String
}

// MARK: - Process Scene Request Body (internal)

/// Request body for `POST /v1/scenes/{id}/process`.
///
/// The API infers `sfm.backend = "none"` from the presence of `arkit_poses`,
/// so the SDK does not send `sfm` explicitly.
struct ProcessSceneBody: Encodable {
    let enableLod: Bool?
    let arkitPoses: [ARKitPose]?

    enum CodingKeys: String, CodingKey {
        case enableLod = "enable_lod"
        case arkitPoses = "arkit_poses"
    }
}

// MARK: - SplatClient

/// The main entry point for interacting with the Splat API.
///
/// `SplatClient` provides methods for creating, uploading, processing, and
/// managing 3D Gaussian Splat scenes.
///
/// ## Quick Start
///
/// ```swift
/// let client = SplatClient(apiKey: "s3d_your_api_key")
///
/// // Create and process a scene from a video file
/// let scene = try await client.createAndProcess(
///     videoURL: videoFileURL,
///     title: "My Living Room",
///     preset: .standard,
///     arkitPoses: capturedPoses,
///     onProgress: { status, pct in
///         print("Status: \(status), Progress: \(pct ?? 0)%")
///     }
/// )
///
/// print("Scene ready: \(scene.viewerURL!)")
/// ```
///
/// ## Authentication
///
/// All requests require a valid API key passed as a Bearer token.
/// Generate API keys from the [Splat dashboard](https://splat-3d.com/dashboard).
///
/// ## Thread Safety
///
/// `SplatClient` is `Sendable` and safe to use from any actor or task.
public final class SplatClient: Sendable {

    private let api: APIClient
    private let poller: PollingTask

    /// Create a new Splat API client.
    ///
    /// - Parameters:
    ///   - apiKey: Your Splat API key (starts with `s3d_`).
    ///   - baseURL: API base URL. Defaults to `https://api.splat-3d.com`.
    ///   - session: URLSession to use for requests. Defaults to `.shared`.
    ///   - pollingInterval: Seconds between status polls. Defaults to 10.
    ///   - pollingTimeout: Maximum seconds to wait for processing. Defaults to 1200 (20 min).
    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.splat-3d.com")!,
        session: URLSession = .shared,
        pollingInterval: TimeInterval = 10,
        pollingTimeout: TimeInterval = 1200
    ) {
        self.api = APIClient(apiKey: apiKey, baseURL: baseURL, session: session)
        self.poller = PollingTask(interval: pollingInterval, timeout: pollingTimeout)
    }

    // MARK: - Create Scene

    /// Create a new scene and get a presigned upload URL.
    ///
    /// After creating the scene, upload your video file to the returned `uploadURL`
    /// using ``uploadVideo(from:to:)``, then trigger processing with
    /// ``processScene(id:arkitPoses:enableLOD:)``.
    ///
    /// - Parameters:
    ///   - title: Optional title for the scene.
    ///   - preset: Processing quality preset. Defaults to `.standard`.
    /// - Returns: A tuple of the created scene's ID and a presigned upload URL.
    /// - Throws: ``SplatError`` on network or API errors.
    public func createScene(
        title: String? = nil,
        preset: SceneParams = .standard
    ) async throws -> (sceneId: String, uploadURL: URL) {
        struct Body: Encodable {
            let title: String?
            let preset: String
            let enableLod: Bool?
            let contentType: String

            enum CodingKeys: String, CodingKey {
                case title, preset
                case enableLod = "enable_lod"
                case contentType = "content_type"
            }
        }

        let body = Body(
            title: title,
            preset: preset.preset.rawValue,
            enableLod: preset.enableLOD ? true : nil,
            contentType: "video/mp4"
        )

        let result: CreateSceneData = try await api.request(
            CreateSceneData.self,
            path: "/v1/scenes",
            method: "POST",
            body: body
        )

        guard let uploadURL = URL(string: result.uploadUrl) else {
            throw SplatError.serverError(0, "Invalid upload URL returned by API.")
        }

        return (sceneId: result.sceneId, uploadURL: uploadURL)
    }

    // MARK: - Upload Video

    /// Upload a video file to a presigned R2 URL.
    ///
    /// The upload is a raw HTTP PUT with `Content-Type: video/mp4`.
    ///
    /// - Parameters:
    ///   - fileURL: Local file URL of the video to upload.
    ///   - uploadURL: Presigned upload URL from ``createScene(title:preset:)``.
    /// - Throws: ``SplatError/uploadFailed(_:)`` on upload failure.
    public func uploadVideo(from fileURL: URL, to uploadURL: URL) async throws {
        try await api.uploadFile(from: fileURL, to: uploadURL, contentType: "video/mp4")
    }

    // MARK: - Process Scene

    /// Trigger GPU processing for an uploaded scene.
    ///
    /// If ARKit poses are provided, the pipeline skips Structure from Motion
    /// (GLOMAP/COLMAP) and uses the poses directly, which is significantly faster.
    /// The API infers `sfm.backend = "none"` from the presence of `arkit_poses`.
    ///
    /// - Parameters:
    ///   - id: The scene ID to process.
    ///   - arkitPoses: Optional array of ARKit camera poses. When provided,
    ///     the API automatically skips SfM and uses the poses directly.
    ///   - enableLOD: Whether to generate LOD chunks. Defaults to `false`.
    /// - Returns: The scene with updated status (typically `.processing`).
    /// - Throws: ``SplatError`` on network or API errors.
    public func processScene(
        id: String,
        arkitPoses: [ARKitPose]? = nil,
        enableLOD: Bool = false
    ) async throws -> Scene {
        let body = ProcessSceneBody(
            enableLod: enableLOD ? true : nil,
            arkitPoses: arkitPoses
        )

        // The process endpoint returns { status, sceneId, message }
        // but we want to return a full Scene, so we fetch it after triggering
        let _: ProcessSceneData = try await api.request(
            ProcessSceneData.self,
            path: "/v1/scenes/\(id)/process",
            method: "POST",
            body: body
        )

        // Fetch the full scene to return
        return try await getScene(id: id)
    }

    // MARK: - Get Scene

    /// Get the current status and metadata for a scene.
    ///
    /// Use this to check processing progress or retrieve scene details.
    ///
    /// - Parameter id: The scene ID.
    /// - Returns: The scene with current status.
    /// - Throws: ``SplatError/notFound(_:)`` if the scene doesn't exist.
    public func getScene(id: String) async throws -> Scene {
        try await api.request(Scene.self, path: "/v1/scenes/\(id)", method: "GET")
    }

    // MARK: - List Scenes

    /// List all scenes for the authenticated user.
    ///
    /// Returns scenes ordered by creation date (newest first).
    ///
    /// - Returns: Array of all scenes.
    /// - Throws: ``SplatError`` on network or API errors.
    public func listScenes() async throws -> [Scene] {
        try await api.requestArray(Scene.self, path: "/v1/scenes", method: "GET")
    }

    // MARK: - Delete Scene

    /// Delete a scene and all associated files.
    ///
    /// This permanently removes the scene, its video, 3D model, and thumbnail.
    /// This action cannot be undone.
    ///
    /// - Parameter id: The scene ID to delete.
    /// - Throws: ``SplatError/notFound(_:)`` if the scene doesn't exist.
    public func deleteScene(id: String) async throws {
        try await api.requestVoid(path: "/v1/scenes/\(id)", method: "DELETE")
    }

    // MARK: - Create and Process (Convenience)

    /// Create, upload, process, and wait for a scene in a single call.
    ///
    /// This is the highest-level API method. It handles the entire flow:
    /// 1. Creates the scene and gets an upload URL
    /// 2. Uploads the video file
    /// 3. Triggers processing (with optional ARKit poses)
    /// 4. Polls for completion (every 10 seconds, up to 20 minutes)
    ///
    /// ```swift
    /// let scene = try await client.createAndProcess(
    ///     videoURL: recordedVideoURL,
    ///     title: "Office Tour",
    ///     preset: .standard,
    ///     arkitPoses: capturedPoses
    /// ) { status, pct in
    ///     print("\(status.rawValue): \(pct ?? 0)%")
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - videoURL: Local file URL of the video to upload.
    ///   - title: Optional title for the scene.
    ///   - preset: Processing quality preset. Defaults to `.standard`.
    ///   - arkitPoses: Optional ARKit camera poses to skip SfM.
    ///   - onProgress: Optional callback for status updates during polling.
    /// - Returns: The completed scene.
    /// - Throws: ``SplatError/timeout`` if processing exceeds 20 minutes.
    ///           ``SplatError/processingFailed(_:)`` if the pipeline fails.
    public func createAndProcess(
        videoURL: URL,
        title: String? = nil,
        preset: SceneParams = .standard,
        arkitPoses: [ARKitPose]? = nil,
        onProgress: ((SceneStatus, Double?) -> Void)? = nil
    ) async throws -> Scene {
        // 1. Create scene
        let (sceneId, uploadURL) = try await createScene(title: title, preset: preset)

        // 2. Upload video
        onProgress?(.uploading, 0)
        try await uploadVideo(from: videoURL, to: uploadURL)
        onProgress?(.uploading, 100)

        // 3. Trigger processing
        _ = try await processScene(id: sceneId, arkitPoses: arkitPoses, enableLOD: preset.enableLOD)

        // 4. Poll until complete or failed
        let scene = try await poller.poll(
            sceneId: sceneId,
            using: api,
            onProgress: onProgress
        )

        return scene
    }
}
