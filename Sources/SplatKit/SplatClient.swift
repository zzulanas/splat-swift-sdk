import Foundation

// MARK: - Create Scene Response (internal)

/// Response from `POST /v1/scenes`.
struct CreateSceneData: Decodable {
    let sceneId: String
    let uploadUrl: URL
}

// MARK: - Update Scene Request Body (internal)

/// Request body for `PATCH /v1/scenes/{id}`. `nil` fields are omitted, so the
/// API leaves them unchanged.
struct UpdateSceneBody: Encodable {
    let title: String?
    let address: String?
    let description: String?
    let isPublic: Bool?

    enum CodingKeys: String, CodingKey {
        case title, address, description
        case isPublic = "is_public"
    }

    init(_ update: SceneUpdate) {
        title = update.title
        address = update.address
        description = update.description
        isPublic = update.isPublic
    }
}

// MARK: - Retrain Scene Request Body (internal)

/// Request body for `POST /v1/scenes/{id}/retrain`.
struct RetrainSceneBody: Encodable {
    let qualityTier: String

    enum CodingKeys: String, CodingKey {
        case qualityTier = "quality_tier"
    }

    /// The retrain endpoint names tiers after billing tiers, where the
    /// `quality` preset is called `pro` (TIER_TABLE in the API's
    /// packages/core/src/tiers.ts: `pro: { preset: "quality" }`).
    init(preset: ScenePreset) {
        switch preset {
        case .fast:
            qualityTier = "fast"
        case .standard:
            qualityTier = "standard"
        case .quality:
            qualityTier = "pro"
        case .ultra:
            qualityTier = "ultra"
        }
    }
}

// MARK: - Retrain Scene Response (internal)

/// Response from `POST /v1/scenes/{id}/retrain`. `id` is the new scene.
struct RetrainSceneData: Decodable {
    let id: String
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
    let lidarPoints: [[Float]]?

    enum CodingKeys: String, CodingKey {
        case enableLod = "enable_lod"
        case arkitPoses = "arkit_poses"
        case lidarPoints = "lidar_points"
    }

    /// Pose count the route accepts, and its LiDAR point cap
    /// (processSceneBodySchema in the API's api/src/routes/schemas.ts).
    /// Outside them the whole launch is a 400, after the upload.
    static let poseRange = 5...1000
    static let maxLidarPoints = 50_000

    /// Fit captured data to the route's limits. Fewer than 5 poses are left
    /// out: the pipeline would solve camera poses itself anyway
    /// (arkit_hydrate.py). Longer captures are thinned evenly.
    init(enableLOD: Bool, arkitPoses: [ARKitPose]?, lidarPoints: [[Float]]?) {
        enableLod = enableLOD ? true : nil

        if let arkitPoses, arkitPoses.count >= Self.poseRange.lowerBound {
            self.arkitPoses = Self.evenlySpaced(arkitPoses, limit: Self.poseRange.upperBound)
        } else {
            self.arkitPoses = nil
        }

        self.lidarPoints = lidarPoints.map { Self.evenlySpaced($0, limit: Self.maxLidarPoints) }
    }

    /// At most `limit` items spread evenly across `items`, in order: index
    /// `Int(i × count / limit)`, as the pipeline thins poses itself. The
    /// result is deterministic, so a repeated launch sends the same body.
    ///
    /// 1,500 poses into 1,000 keep indices 0, 1, 3, 4, 6, … 1,498.
    static func evenlySpaced<T>(_ items: [T], limit: Int) -> [T] {
        guard items.count > limit else {
            return items
        }
        let step = Double(items.count) / Double(limit)
        return (0..<limit).map { items[Int(Double($0) * step)] }
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

    /// The production API.
    @usableFromInline
    static let productionURL = URL(string: "https://api.splat-3d.com")!

    /// Create a new Splat API client.
    ///
    /// - Parameters:
    ///   - apiKey: Your Splat API key (starts with `s3d_`).
    ///   - baseURL: API base URL. Defaults to `https://api.splat-3d.com`.
    ///   - session: URLSession to use for requests. Defaults to `.shared`.
    ///   - pollingInterval: Seconds between status polls. Defaults to
    ///     ``Configuration/pollingInterval``.
    ///   - pollingTimeout: Maximum seconds to wait for processing. Defaults to
    ///     ``Configuration/pollingTimeout`` (165 minutes).
    public convenience init(
        apiKey: String,
        baseURL: URL = SplatClient.productionURL,
        session: URLSession = .shared,
        pollingInterval: TimeInterval? = nil,
        pollingTimeout: TimeInterval? = nil
    ) {
        var configuration = Configuration()
        if let pollingInterval {
            configuration.pollingInterval = pollingInterval
        }
        if let pollingTimeout {
            configuration.pollingTimeout = pollingTimeout
        }
        self.init(apiKey: apiKey, baseURL: baseURL, session: session, configuration: configuration)
    }

    /// Create a new Splat API client with explicit timeouts and retries.
    ///
    /// - Parameters:
    ///   - apiKey: Your Splat API key (starts with `s3d_`).
    ///   - baseURL: API base URL. Defaults to `https://api.splat-3d.com`.
    ///   - session: URLSession to use for requests. Defaults to `.shared`.
    ///   - configuration: Request timeout, polling, and retry settings.
    public convenience init(
        apiKey: String,
        baseURL: URL = SplatClient.productionURL,
        session: URLSession = .shared,
        configuration: Configuration
    ) {
        self.init(apiKey: apiKey, baseURL: baseURL, session: session, configuration: configuration, timing: .live)
    }

    /// Designated initializer; tests inject `timing` so nothing waits.
    init(apiKey: String, baseURL: URL, session: URLSession, configuration: Configuration, timing: Timing) {
        self.api = APIClient(
            apiKey: apiKey,
            baseURL: baseURL,
            session: session,
            configuration: configuration,
            timing: timing
        )
        self.poller = PollingTask(
            interval: configuration.pollingInterval,
            timeout: configuration.pollingTimeout,
            timing: timing
        )
    }

    // MARK: - Create Scene

    /// Create a new scene and get a presigned upload URL.
    ///
    /// After creating the scene, upload your video file to the returned `uploadURL`
    /// using ``uploadVideo(from:to:)``, then trigger processing with
    /// ``processScene(id:arkitPoses:lidarPoints:enableLOD:idempotencyKey:)``.
    ///
    /// - Parameters:
    ///   - title: Optional title for the scene.
    ///   - preset: Processing quality preset. Defaults to `.standard`.
    /// - Returns: A tuple of the created scene's ID and a presigned upload URL.
    /// - Throws: ``SplatError`` on network or API errors.
    public func createScene(
        title: String? = nil,
        preset: SceneParams = .standard
    ) async throws -> (sceneID: String, uploadURL: URL) {
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
            path: APIPath.scenes,
            method: .post,
            body: body
        )

        return (sceneID: result.sceneId, uploadURL: result.uploadUrl)
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
    /// Processing is paid, and the API launches a scene at most once. Every
    /// call sends an `Idempotency-Key`, by default `process-<scene ID>`, and
    /// network failures, 5xx and rate limits are retried with it. So calling
    /// `processScene` again for the same scene with the same inputs, after a
    /// dropped connection or an app restart, replays the original launch
    /// instead of charging again, or starts it if it never went through.
    ///
    /// A launch with different inputs, or a different key, for a scene that
    /// is already launched fails with `conflict` (409), which is never
    /// retried: resume with ``waitForScene(id:onProgress:)`` instead.
    ///
    /// The route accepts 5–1,000 poses and up to 50,000 LiDAR points. Longer
    /// captures are thinned evenly to fit; fewer than 5 poses are not sent,
    /// and the pipeline solves camera poses itself.
    ///
    /// - Parameters:
    ///   - id: The scene ID to process.
    ///   - arkitPoses: Optional array of ARKit camera poses. When provided,
    ///     the API automatically skips SfM and uses the poses directly.
    ///   - lidarPoints: Optional LiDAR points, each `[x, y, z]` or `[x, y, z, r, g, b]`.
    ///   - enableLOD: Whether to generate LOD chunks. Defaults to `false`.
    ///   - idempotencyKey: 1–128 printable ASCII characters, no spaces.
    ///     Defaults to `process-<scene ID>`, which is the same for every call.
    /// - Returns: The API's acknowledgement. The launch is accepted and charged;
    ///   follow it with ``waitForScene(id:onProgress:)``.
    /// - Throws: ``SplatError`` on API errors; `URLError` on network errors
    ///   that persist through retries.
    public func processScene(
        id: String,
        arkitPoses: [ARKitPose]? = nil,
        lidarPoints: [[Float]]? = nil,
        enableLOD: Bool = false,
        idempotencyKey: String? = nil
    ) async throws -> SceneLaunch {
        let body = ProcessSceneBody(enableLOD: enableLOD, arkitPoses: arkitPoses, lidarPoints: lidarPoints)
        let key = idempotencyKey ?? Self.launchKey(for: id)

        // Nothing else is read after the launch: once the API accepts it, it
        // is charged, and a failed follow-up read must not look like a failure.
        let launch = try await api.request(
            ProcessSceneData.self,
            path: APIPath.scene(id, .process),
            method: .post,
            body: body,
            idempotencyKey: key
        )

        return SceneLaunch(
            sceneID: launch.sceneId,
            status: SceneStatus(rawValue: launch.status),
            message: launch.message,
            idempotencyKey: key
        )
    }

    /// The default launch key. The API allows one launch per scene
    /// (scene_launches.scene_id is its primary key), so one fixed key per
    /// scene makes every repeat a replay rather than a 409.
    static func launchKey(for sceneID: String) -> String {
        launchKeyPrefix + sceneID
    }

    private static let launchKeyPrefix = "process-"

    // MARK: - Get Scene

    /// Get the current status and metadata for a scene.
    ///
    /// Use this to check processing progress or retrieve scene details.
    ///
    /// - Parameter id: The scene ID.
    /// - Returns: The scene with current status.
    /// - Throws: ``SplatError/notFound(_:)`` if the scene doesn't exist.
    public func getScene(id: String) async throws -> Scene {
        try await api.request(Scene.self, path: APIPath.scene(id), method: .get)
    }

    // MARK: - List Scenes

    /// List the first page of scenes for the authenticated user.
    ///
    /// Returns at most 50 scenes, newest first, not every scene.
    ///
    /// - Returns: The scenes on the first page.
    /// - Throws: ``SplatError`` on network or API errors.
    @available(*, deprecated, message: "Returns only the first page. Use listScenePage(cursor:limit:) or allScenes(pageSize:).")
    public func listScenes() async throws -> [Scene] {
        try await listScenePage().scenes
    }

    /// Fetch one page of scenes for the authenticated user, newest first.
    ///
    /// ```swift
    /// var page = try await client.listScenePage()
    /// while let cursor = page.nextCursor {
    ///     page = try await client.listScenePage(cursor: cursor)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - cursor: ``ScenePage/nextCursor`` from the previous page, or `nil`
    ///     for the first page.
    ///   - limit: Scenes per page, 1–100. The API defaults to 50.
    /// - Returns: The page's scenes and the cursor for the next page.
    /// - Throws: ``SplatError`` on network or API errors.
    public func listScenePage(cursor: String? = nil, limit: Int? = nil) async throws -> ScenePage {
        var query: [URLQueryItem] = []
        if let cursor {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }

        let page = try await api.requestPage(Scene.self, path: APIPath.scenes, query: query)
        return ScenePage(scenes: page.data, nextCursor: page.meta.nextCursor, hasMore: page.meta.hasMore)
    }

    /// Every scene for the authenticated user, newest first.
    ///
    /// Pages are fetched as you iterate, so stopping early stops fetching.
    ///
    /// ```swift
    /// for try await scene in client.allScenes() {
    ///     print(scene.id)
    /// }
    /// ```
    ///
    /// - Parameter pageSize: Scenes per request, 1–100. The API defaults to 50.
    /// - Returns: A sequence that throws ``SplatError`` if a page fails to load.
    public func allScenes(pageSize: Int? = nil) -> AsyncThrowingStream<Scene, Error> {
        let pager = ScenePager(client: self, pageSize: pageSize)
        return AsyncThrowingStream(unfolding: { try await pager.next() })
    }

    // MARK: - Update Scene

    /// Change a scene's title, address, description, or visibility.
    ///
    /// Only the fields set in `update` change.
    ///
    /// ```swift
    /// let scene = try await client.updateScene(id: sceneId, SceneUpdate(title: "Kitchen"))
    /// ```
    ///
    /// - Parameters:
    ///   - id: The scene ID.
    ///   - update: The fields to change.
    /// - Returns: The updated scene. It is built from the stored record, so
    ///   ``Scene/downloadURL`` and ``Scene/format`` are `nil`; use
    ///   ``getScene(id:)`` for those.
    /// - Throws: ``SplatError/notFound(_:)`` if the scene doesn't exist.
    ///   ``SplatError/requestFailed(_:)`` with code `invalid_input` if `update`
    ///   sets no fields.
    public func updateScene(id: String, _ update: SceneUpdate) async throws -> Scene {
        try await api.request(
            Scene.self,
            path: APIPath.scene(id),
            method: .patch,
            body: UpdateSceneBody(update)
        )
    }

    // MARK: - Retrain Scene

    /// Process a scene's source again at another quality preset.
    ///
    /// The API creates and starts a new, versioned scene ("Kitchen" becomes
    /// "Kitchen v2") and leaves the original unchanged. The new scene is
    /// charged like ``processScene(id:arkitPoses:lidarPoints:enableLOD:idempotencyKey:)``,
    /// so this call is never retried automatically: repeating it starts
    /// another scene.
    ///
    /// - Parameters:
    ///   - id: The scene to retrain.
    ///   - preset: Quality preset for the new scene.
    /// - Returns: The new scene's ID. Poll it with ``getScene(id:)``.
    /// - Throws: ``SplatError/notFound(_:)`` if the scene doesn't exist.
    ///   ``SplatError/requestFailed(_:)`` with code `conflict` while the scene
    ///   is still uploading.
    public func retrainScene(id: String, preset: ScenePreset) async throws -> String {
        let result = try await api.request(
            RetrainSceneData.self,
            path: APIPath.scene(id, .retrain),
            method: .post,
            body: RetrainSceneBody(preset: preset)
        )
        return result.id
    }

    // MARK: - Cancel Scene

    /// Cancel a scene that is uploading or processing.
    ///
    /// - Parameter id: The scene ID.
    /// - Throws: ``SplatError/notFound(_:)`` if the scene doesn't exist.
    ///   ``SplatError/requestFailed(_:)`` with code `conflict` if the scene has
    ///   already finished.
    public func cancelScene(id: String) async throws {
        try await api.requestVoid(path: APIPath.scene(id, .cancel), method: .post)
    }

    // MARK: - Download Scene

    /// Download a completed scene's 3D model to a temporary file.
    ///
    /// When the requested format isn't stored, the API serves the other one.
    /// The file's extension, `sog` or `ply`, is the format actually served.
    ///
    /// ```swift
    /// let file = try await client.downloadScene(id: sceneId, format: .ply)
    /// try FileManager.default.moveItem(at: file, to: destination)
    /// ```
    ///
    /// - Parameters:
    ///   - id: The scene ID.
    ///   - format: Preferred format. Defaults to `.sog`.
    /// - Returns: A file in the temporary directory. Move it somewhere
    ///   permanent: the system may delete temporary files.
    /// - Throws: ``SplatError/notFound(_:)`` if the scene has no model yet.
    public func downloadScene(id: String, format: ModelFormat = .sog) async throws -> URL {
        let query = [URLQueryItem(name: "format", value: format.rawValue)]
        let (file, response) = try await api.download(path: APIPath.scene(id, .download), query: query)

        let served = response.value(forHTTPHeaderField: HTTPHeader.splatFormat)
            .flatMap(ModelFormat.init(rawValue:)) ?? format
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("scene-\(id)-\(UUID().uuidString)")
            .appendingPathExtension(served.rawValue)

        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    // MARK: - Scene Thumbnail

    /// Fetch a scene's thumbnail image.
    ///
    /// - Parameter id: The scene ID.
    /// - Returns: PNG or JPEG image data, e.g. for `UIImage(data:)`.
    /// - Throws: ``SplatError/notFound(_:)`` if the scene has no thumbnail yet.
    public func getSceneThumbnail(id: String) async throws -> Data {
        try await api.requestData(path: APIPath.scene(id, .thumbnail))
    }

    // MARK: - Usage

    /// Usage for the current billing period and your plan's limits.
    ///
    /// - Returns: Counts for this period and the plan limits they count against.
    /// - Throws: ``SplatError`` on network or API errors.
    public func getUsage() async throws -> Usage {
        try await api.request(Usage.self, path: APIPath.usage, method: .get)
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
        try await api.requestVoid(path: APIPath.scene(id), method: .delete)
    }

    // MARK: - Wait for Scene

    /// Poll a scene until processing finishes.
    ///
    /// Use it to resume a launched scene after ``SplatError/interrupted(_:)``
    /// or an app restart, without paying for another job. Network failures,
    /// 5xx and rate limits don't end the wait: they say nothing about the job,
    /// so polling carries on until the deadline.
    ///
    /// - Parameters:
    ///   - id: The scene ID.
    ///   - onProgress: Optional callback with each polled status and progress.
    /// - Returns: The completed scene.
    /// - Throws: ``SplatError/notStarted`` at once if the scene is still
    ///           `uploading`: no job exists to wait for.
    ///           ``SplatError/timeout`` if ``Configuration/pollingTimeout``
    ///           passes first; the job may still finish, so call again to keep waiting.
    ///           ``SplatError/processingFailed(_:)`` if the server reports failure.
    ///           ``SplatError/cancelled`` if the scene was cancelled.
    ///           An API error for a rejected request, e.g. ``SplatError/notFound(_:)``.
    ///           `CancellationError` if the task is cancelled.
    public func waitForScene(
        id: String,
        onProgress: ((SceneStatus, Double?) -> Void)? = nil
    ) async throws -> Scene {
        try await poller.poll(sceneId: id, using: api, onProgress: onProgress)
    }

    // MARK: - Create and Process (Convenience)

    /// Create, upload, process, and wait for a scene in a single call.
    ///
    /// This is the highest-level API method. It handles the entire flow:
    /// 1. Creates the scene and gets an upload URL
    /// 2. Uploads the video file
    /// 3. Triggers processing (with optional ARKit poses)
    /// 4. Polls for completion (see ``Configuration``)
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
    /// Once the scene exists, any failure, including cancellation, is thrown
    /// as ``SplatError/interrupted(_:)``. Its ``SplatError/Interruption`` says
    /// which step failed, what was charged, and how to resume without paying
    /// for another job.
    ///
    /// - Parameters:
    ///   - videoURL: Local file URL of the video to upload.
    ///   - title: Optional title for the scene.
    ///   - preset: Processing quality preset. Defaults to `.standard`.
    ///   - arkitPoses: Optional ARKit camera poses to skip SfM.
    ///   - lidarPoints: Optional LiDAR points from ``SplatScanner``.
    ///   - onProgress: Optional callback for status updates during polling.
    /// - Returns: The completed scene.
    /// - Throws: The creation error if the scene could not be created.
    ///           Afterwards, ``SplatError/interrupted(_:)`` wrapping the cause:
    ///           e.g. ``SplatError/timeout`` when polling outlasts
    ///           ``Configuration/pollingTimeout``, ``SplatError/processingFailed(_:)``
    ///           if the pipeline fails, or `CancellationError`.
    public func createAndProcess(
        videoURL: URL,
        title: String? = nil,
        preset: SceneParams = .standard,
        arkitPoses: [ARKitPose]? = nil,
        lidarPoints: [[Float]]? = nil,
        onProgress: ((SceneStatus, Double?) -> Void)? = nil
    ) async throws -> Scene {
        // 1. Create scene
        let (sceneID, uploadURL) = try await createScene(title: title, preset: preset)
        let key = Self.launchKey(for: sceneID)
        var phase = SplatError.Interruption.Phase.upload

        do {
            // 2. Upload video
            onProgress?(.uploading, 0)
            try await uploadVideo(from: videoURL, to: uploadURL)
            onProgress?(.uploading, 100)

            // 3. Trigger processing
            phase = .launch
            _ = try await processScene(
                id: sceneID,
                arkitPoses: arkitPoses,
                lidarPoints: lidarPoints,
                enableLOD: preset.enableLOD,
                idempotencyKey: key
            )

            // 4. Poll until complete or failed
            phase = .wait
            return try await waitForScene(id: sceneID, onProgress: onProgress)
        } catch {
            // The scene exists, and once launched it is paid for: say where it
            // stopped so the caller resumes instead of starting over.
            let cause = Task.isCancelled ? CancellationError() : error
            throw SplatError.interrupted(SplatError.Interruption(
                sceneID: sceneID,
                phase: phase,
                idempotencyKey: key,
                underlying: cause
            ))
        }
    }
}
