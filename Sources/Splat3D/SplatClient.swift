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
struct ProcessSceneBody: Encodable, Sendable {
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
    /// - Throws: ``SplatError/uploadFailed(_:)`` on upload failure, and before
    ///   sending anything when the file is missing, unreadable, a folder or
    ///   empty: URLSession would send those as an empty body, which storage
    ///   accepts. Its `URLError` is `.fileDoesNotExist`,
    ///   `.noPermissionsToReadFile`, `.fileIsDirectory` or `.zeroByteResource`.
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
    /// retried: resume with ``waitForScene(id:onProgress:)`` instead. A launch
    /// the API failed for good (e.g. `upstream_error`, when the pipeline
    /// rejected it) was refunded and failed the scene; repeats replay that
    /// error, so start over with a new scene.
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
        return try await launch(id: id, body: body, idempotencyKey: idempotencyKey ?? Self.launchKey(for: id))
    }

    /// Send a launch body with its key and return the API's acknowledgement.
    ///
    /// Nothing else is read after the launch: once the API accepts it, it is
    /// charged, and a failed follow-up read must not look like a failure.
    private func launch(id: String, body: ProcessSceneBody, idempotencyKey key: String) async throws -> SceneLaunch {
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
    public func getScene(id: String) async throws -> SplatScene {
        try await api.request(SplatScene.self, path: APIPath.scene(id), method: .get)
    }

    // MARK: - List Scenes

    /// List the first page of scenes for the authenticated user.
    ///
    /// Returns at most 50 scenes, newest first, not every scene.
    ///
    /// - Returns: The scenes on the first page.
    /// - Throws: ``SplatError`` on network or API errors.
    @available(*, deprecated, message: "Returns only the first page. Use listScenePage(cursor:limit:) or allScenes(pageSize:).")
    public func listScenes() async throws -> [SplatScene] {
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

        let page = try await api.requestPage(SplatScene.self, path: APIPath.scenes, query: query)
        return ScenePage(scenes: page.data, nextCursor: page.meta.nextCursor, hasMore: page.meta.hasMore)
    }

    /// Every scene for the authenticated user, newest first.
    ///
    /// Pages are fetched as you iterate, so stopping early stops fetching.
    /// If the task is cancelled, iteration throws `CancellationError` rather
    /// than ending, so a finished loop always means every scene was seen.
    ///
    /// ```swift
    /// for try await scene in client.allScenes() {
    ///     print(scene.id)
    /// }
    /// ```
    ///
    /// - Parameter pageSize: Scenes per request, 1–100. The API defaults to 50.
    /// - Returns: A sequence that throws ``SplatError`` if a page fails to load.
    public func allScenes(pageSize: Int? = nil) -> SceneSequence {
        SceneSequence(client: self, pageSize: pageSize)
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
    /// - Returns: The updated scene, in the shape ``getScene(id:)`` returns.
    /// - Throws: ``SplatError/notFound(_:)`` if the scene doesn't exist.
    ///   ``SplatError/requestFailed(_:)`` with code `invalid_input` if `update`
    ///   sets no fields.
    public func updateScene(id: String, _ update: SceneUpdate) async throws -> SplatScene {
        try await api.request(
            SplatScene.self,
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
    /// If it throws after the request was sent, e.g. the connection dropped
    /// while the API was copying the source, the new scene may exist and be
    /// charged anyway. Look for it in ``allScenes(pageSize:)`` (newest first,
    /// titled with the next version number) before retraining again.
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
    ///   ``SplatError/requestFailed(_:)`` with code `conflict` if the scene
    ///   can't be cancelled in its current state: it has finished, or it is in
    ///   a preview stage (``SceneStatus/previewExtracting``,
    ///   ``SceneStatus/previewGenerating``, ``SceneStatus/previewCompressing``).
    public func cancelScene(id: String) async throws {
        try await api.requestVoid(path: APIPath.scene(id, .cancel), method: .post)
    }

    // MARK: - Download Scene

    /// Download a completed scene's 3D model to a temporary file.
    ///
    /// When the requested SOG or PLY isn't stored, the API serves the other one.
    /// The file's extension, `sog` or `ply`, is the format actually served.
    /// SPZ is never swapped for another format. Older scenes, and scenes whose
    /// SPZ conversion failed, have none, so asking for one throws.
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
    /// - Throws: ``SplatError/notFound(_:)`` if the scene has no model yet, or
    ///   no SPZ when you ask for ``ModelFormat/spz``.
    public func downloadScene(id: String, format: ModelFormat = .sog) async throws -> URL {
        let query = [URLQueryItem(name: "format", value: format.rawValue)]
        let (file, response) = try await api.download(path: APIPath.scene(id, .download), query: query)

        let served = Self.servedFormat(response.value(forHTTPHeaderField: HTTPHeader.splatFormat)) ?? format
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("scene-\(id)-\(UUID().uuidString)")
            .appendingPathExtension(served.rawValue)

        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    /// The format a download reports in `X-Splat-Format`, if it is a plain
    /// name that is safe to use as a file extension.
    private static func servedFormat(_ header: String?) -> ModelFormat? {
        guard let header, !header.isEmpty, header.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        return ModelFormat(rawValue: header.lowercased())
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
    /// Use it to pick up a launched scene, e.g. after an app restart, without
    /// paying for another job. Network failures, 5xx and rate limits don't
    /// end the wait, since they say nothing about the job; once the scene has
    /// been read, neither does a short run of 401 or 404, which the API also
    /// returns when its database blips. After the deadline it looks once more.
    ///
    /// - Parameters:
    ///   - id: The scene ID.
    ///   - onProgress: Optional callback, on the main actor, with each polled
    ///     status and progress.
    /// - Returns: The completed scene.
    /// - Throws: ``SplatError/notStarted`` if the scene is still `uploading`
    ///           on two polls in a row: no job exists to wait for.
    ///           ``SplatError/timeout`` if ``Configuration/pollingTimeout``
    ///           passes first; the job may still finish, so call again to keep waiting.
    ///           ``SplatError/processingFailed(_:)`` if the server reports failure.
    ///           ``SplatError/cancelled`` if the scene was cancelled.
    ///           An API error for a rejected request, e.g. ``SplatError/notFound(_:)``.
    ///           `CancellationError` if the task is cancelled.
    public func waitForScene(
        id: String,
        onProgress: (@MainActor @Sendable (SceneStatus, Double?) -> Void)? = nil
    ) async throws -> SplatScene {
        try await poller.poll(sceneId: id, using: api, evidence: .none, onProgress: onProgress)
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
    /// Once the scene exists, a failure that leaves the outcome open (network,
    /// timeout, cancellation, a launch refused for want of credits) is thrown
    /// as ``SplatError/interrupted(_:)``: continue with ``resume(_:onProgress:)``,
    /// which doesn't pay again. Anything else ends the run, and no resume
    /// can continue it:
    /// - ``SplatError/processingFailed(_:)``: the server failed the scene,
    ///   including a launch it failed, and refunds it. Rarely, a job the
    ///   stale-job sweep failed still completes, so check ``getScene(id:)``
    ///   before starting over.
    /// - ``SplatError/cancelled``: the scene was cancelled. The server doesn't
    ///   refund a job that had started.
    /// - ``SplatError/notFound(_:)``: the scene was deleted. A 404 while
    ///   waiting counts only once a replay of the launch also finds no scene,
    ///   since the API answers a failed read with 404 too.
    /// - ``SplatError/uploadFailed(_:)`` with a `URLError` such as
    ///   `.fileDoesNotExist` or `.zeroByteResource`: the capture is missing
    ///   or empty, so nothing was sent. It is checked before the scene is
    ///   created too, so a bad path costs no scene creation.
    /// - ``SplatError/requestFailed(_:)`` with a 4xx: storage refused the
    ///   upload URL (403 once it expires, after an hour), or the API refused
    ///   the launch request itself (400).
    ///
    /// If the app may be killed while it works, save the ID `onSceneCreated`
    /// passes, and the preset and capture. On relaunch, continue with
    /// ``resume(sceneID:preset:arkitPoses:lidarPoints:onProgress:)``.
    ///
    /// - Parameters:
    ///   - videoURL: Local file URL of the video to upload.
    ///   - title: Optional title for the scene.
    ///   - preset: Processing quality preset. Defaults to `.standard`.
    ///   - arkitPoses: Optional ARKit camera poses to skip SfM.
    ///   - lidarPoints: Optional LiDAR points from ``SplatScanner``.
    ///   - onProgress: Optional callback, on the main actor, for status updates.
    ///   - onSceneCreated: Optional callback, on the main actor, with the new
    ///     scene's ID as soon as it exists, before the upload.
    /// - Returns: The completed scene.
    /// - Throws: The creation error if the scene could not be created. If the
    ///           task is cancelled while the scene is being created, a plain
    ///           `CancellationError`: the API may have created it anyway, and
    ///           ``allScenes(pageSize:)`` lists it. Afterwards,
    ///           ``SplatError/interrupted(_:)`` or a final error, as above.
    public func createAndProcess(
        videoURL: URL,
        title: String? = nil,
        preset: SceneParams = .standard,
        arkitPoses: [ARKitPose]? = nil,
        lidarPoints: [[Float]]? = nil,
        onProgress: (@MainActor @Sendable (SceneStatus, Double?) -> Void)? = nil,
        onSceneCreated: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws -> SplatScene {
        // A capture that can't be sent would spend a scene creation for nothing.
        try APIClient.checkUploadable(videoURL)

        // 1. Create scene
        let (sceneID, uploadURL) = try await createScene(title: title, preset: preset)
        await onSceneCreated?(sceneID)

        // 2–4. Upload, launch and wait, recording what resume would repeat.
        let run = Run(
            sceneID: sceneID,
            idempotencyKey: Self.launchKey(for: sceneID),
            request: ResumableRequest(
                upload: ResumableRequest.Upload(videoURL: videoURL, uploadURL: uploadURL),
                launch: Self.launchBody(preset: preset, arkitPoses: arkitPoses, lidarPoints: lidarPoints)
            )
        )
        return try await proceed(run, from: .upload, onProgress: onProgress)
    }

    /// The launch `createAndProcess` sends, rebuilt identically by
    /// ``resume(sceneID:preset:arkitPoses:lidarPoints:onProgress:)``.
    private static func launchBody(preset: SceneParams, arkitPoses: [ARKitPose]?, lidarPoints: [[Float]]?) -> ProcessSceneBody {
        ProcessSceneBody(enableLOD: preset.enableLOD, arkitPoses: arkitPoses, lidarPoints: lidarPoints)
    }

    // MARK: - Resume

    /// Continue a `createAndProcess` that stopped before its outcome was
    /// known, without paying for another job.
    ///
    /// It picks up at the step that stopped, sending exactly the request
    /// `createAndProcess` sent (same body, same key):
    /// - upload or launch: launches, then waits. The API replays a launch
    ///   that went through instead of charging it again, and refuses one
    ///   whose upload never arrived before charging anything; resume then
    ///   uploads the same file to the same URL and launches.
    /// - wait: waits.
    ///
    /// ```swift
    /// do {
    ///     scene = try await client.createAndProcess(videoURL: video, arkitPoses: poses)
    /// } catch SplatError.interrupted(let interruption) {
    ///     scene = try await client.resume(interruption)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - interruption: What `createAndProcess` threw.
    ///   - onProgress: Optional callback, on the main actor, for status updates.
    /// - Returns: The completed scene.
    /// - Throws: ``SplatError/interrupted(_:)`` again if it stops before the
    ///           outcome is known (resume that one). Otherwise a final error,
    ///           as from `createAndProcess`, or ``SplatError/notStarted`` for
    ///           an interruption made without the original request, whose
    ///           scene was never launched.
    public func resume(
        _ interruption: SplatError.Interruption,
        onProgress: (@MainActor @Sendable (SceneStatus, Double?) -> Void)? = nil
    ) async throws -> SplatScene {
        let run = Run(sceneID: interruption.sceneID, idempotencyKey: interruption.idempotencyKey, request: interruption.request)

        // Launching again is free to try, so an interrupted upload or launch
        // continues with the launch; see deliver(_:for:phase:onProgress:).
        let start: SplatError.Interruption.Phase = interruption.phase == .wait ? .wait : .launch
        return try await proceed(run, from: start, onProgress: onProgress)
    }

    /// Continue a scene that `createAndProcess` created in an earlier run of
    /// the app, e.g. one killed while it waited, without paying for another
    /// job. Pass the ID `onSceneCreated` passed, and the preset and capture
    /// `createAndProcess` was given: this rebuilds exactly the launch it sent
    /// (same body, same key), launches, and waits. The API replays a launch
    /// that went through instead of charging it again.
    ///
    /// Every argument that shapes the launch is required, `nil` included: a
    /// launch rebuilt without the poses, LiDAR or LOD would be a different
    /// paid job. Save them with the ID; `ARKitPose` is `Codable`.
    ///
    /// ```swift
    /// // After a relaunch, with the saved capture:
    /// scene = try await client.resume(sceneID: pendingID, preset: .ultra, arkitPoses: saved.poses, lidarPoints: saved.points)
    /// ```
    ///
    /// The upload URL isn't kept, so this can't upload. If the app was killed
    /// before its upload finished, the API refuses the launch (400) before
    /// charging anything: start over with a new scene.
    ///
    /// - Parameters:
    ///   - sceneID: The ID `onSceneCreated` passed.
    ///   - preset: The preset `createAndProcess` was given.
    ///   - arkitPoses: The ARKit poses it was given, or `nil` if none.
    ///   - lidarPoints: The LiDAR points it was given, or `nil` if none.
    ///   - onProgress: Optional callback, on the main actor, for status updates.
    /// - Returns: The completed scene.
    /// - Throws: As ``resume(_:onProgress:)``.
    public func resume(
        sceneID: String,
        preset: SceneParams,
        arkitPoses: [ARKitPose]?,
        lidarPoints: [[Float]]?,
        onProgress: (@MainActor @Sendable (SceneStatus, Double?) -> Void)? = nil
    ) async throws -> SplatScene {
        let run = Run(
            sceneID: sceneID,
            idempotencyKey: Self.launchKey(for: sceneID),
            request: ResumableRequest(
                upload: nil,
                launch: Self.launchBody(preset: preset, arkitPoses: arkitPoses, lidarPoints: lidarPoints)
            )
        )
        return try await proceed(run, from: .launch, onProgress: onProgress)
    }

    // MARK: - Upload, Launch, Wait (internal)

    /// One `createAndProcess`, as far as continuing it needs.
    private struct Run {
        let sceneID: String
        let idempotencyKey: String
        let request: ResumableRequest?
    }

    /// An error no resume can get past, e.g. a failed scene. Thrown as the
    /// wrapped error, never as `.interrupted`.
    private struct Final: Error {
        let error: SplatError
    }

    /// Upload, launch and wait from `start` on. A failure that leaves the
    /// outcome open is thrown as `.interrupted`; a final one as itself.
    ///
    ///   upload ──> launch ──> wait ──> complete
    ///     │          │         │
    ///     │          │         └─ deleted (404), failed, cancelled ──> final
    ///     │          └─ refused for good (400, 404, upstream_error) ─> final
    ///     └─ storage refused the URL (4xx, e.g. expired) ────────────> final
    ///   anything else, e.g. network, timeout, 402 ───────────────────> .interrupted
    private func proceed(
        _ run: Run,
        from start: SplatError.Interruption.Phase,
        onProgress: ProgressHandler?
    ) async throws -> SplatScene {
        var phase = start

        do {
            if let request = run.request, phase != .wait {
                try await deliver(request, for: run, phase: &phase, onProgress: onProgress)
            }

            return try await poller.poll(sceneId: run.sceneID, using: api, evidence: .exists, onProgress: onProgress)
        } catch let final as Final {
            throw final.error
        } catch let error as SplatError where error.isFinal {
            throw error
        } catch SplatError.notFound(let refusal) {
            // The API answers a failed scene read with 404 too, so a read's
            // 404 ends the run only once a launch replay confirms it.
            guard await isGone(run) else {
                throw stopped(run, at: phase, by: SplatError.notFound(refusal))
            }
            throw SplatError.notFound(refusal)
        } catch {
            throw stopped(run, at: phase, by: error)
        }
    }

    /// `.interrupted` for a run that stopped at `phase`, with what `resume`
    /// needs to continue it.
    private func stopped(_ run: Run, at phase: SplatError.Interruption.Phase, by error: Error) -> SplatError {
        .interrupted(SplatError.Interruption(
            sceneID: run.sceneID,
            phase: phase,
            idempotencyKey: run.idempotencyKey,
            underlying: Self.cause(of: error),
            request: run.request
        ))
    }

    /// Whether the scene is gone, asked by replaying its launch. The replay is
    /// free: the API replays a launch that went through, and a scene past
    /// `uploading` can't be claimed again. processScene answers 404 only for
    /// a scene that doesn't exist (a failed lookup there is a 503). Without
    /// the launch body there is nothing to replay, so nothing is confirmed.
    private func isGone(_ run: Run) async -> Bool {
        guard let body = run.request?.launch else {
            return false
        }
        do {
            _ = try await launch(id: run.sceneID, body: body, idempotencyKey: run.idempotencyKey)
            return false
        } catch {
            return (error as? SplatError)?.apiError?.statusCode == HTTPStatus.notFound
        }
    }

    /// Upload and launch from `phase` on, moving `phase` along as each step
    /// lands. From `.upload` the file goes first. From `.launch` the launch
    /// goes first, and the file only if the API answers that it never
    /// arrived: the API checks before charging, so trying is free, and a file
    /// that did arrive isn't sent twice.
    private func deliver(
        _ request: ResumableRequest,
        for run: Run,
        phase: inout SplatError.Interruption.Phase,
        onProgress: ProgressHandler?
    ) async throws {
        var uploaded = false
        if phase == .upload, let upload = request.upload {
            try await send(upload, onProgress: onProgress)
            uploaded = true
            phase = .launch
        }

        do {
            try await settleOrLaunch(run, body: request.launch)
        } catch let final as Final where final.error.isMissingSource && !uploaded {
            // Without the upload URL (after an app restart) the refusal stands.
            guard let upload = request.upload else {
                throw final
            }
            phase = .upload
            try await send(upload, onProgress: onProgress)
            phase = .launch
            try await settleOrLaunch(run, body: request.launch)
        }
        phase = .wait
    }

    /// Send the capture to its presigned URL.
    private func send(_ upload: ResumableRequest.Upload, onProgress: ProgressHandler?) async throws {
        await onProgress?(.uploading, 0)
        do {
            try await uploadVideo(from: upload.videoURL, to: upload.uploadURL)
        } catch let error as SplatError where error.isStorageRefusal || error.isUnsendableFile {
            // Storage refused the URL itself (e.g. it expired after an hour),
            // or the capture is gone or empty: no resume can upload it.
            throw Final(error: error)
        }
        await onProgress?(.uploading, 100)
    }

    /// Launch with the recorded body and key. If the launch fails, the scene
    /// says what happened, and outranks the launch's own error:
    /// - failed or cancelled: that outcome, final.
    /// - past uploading: a launch went through (this one, with its response
    ///   lost, or another client's), so there is nothing to launch: wait.
    /// - still uploading, or unreadable: the launch's error, final when no
    ///   repeat of the request can get past it.
    private func settleOrLaunch(_ run: Run, body: ProcessSceneBody) async throws {
        let launchError: Error
        do {
            _ = try await launch(id: run.sceneID, body: body, idempotencyKey: run.idempotencyKey)
            return
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            launchError = error
        }

        if let scene = try? await getScene(id: run.sceneID) {
            switch scene.status {
            case .failed:
                throw Final(error: .processingFailed(scene.failureMessage))
            case .cancelled:
                throw Final(error: .cancelled)
            case .uploading:
                break
            default:
                return
            }
        }

        if let final = SplatError.ending(launchError) {
            throw Final(error: final)
        }
        throw launchError
    }

    /// The error to report: cancellation as Swift reports it, whatever form it took.
    private static func cause(of error: Error) -> Error {
        Task.isCancelled ? CancellationError() : error
    }
}

// MARK: - Final Errors

extension SplatError {

    /// Statuses of a launch refusal that a repeat of the request meets again:
    /// the request itself is refused (400), or the scene is gone for this key
    /// (404; processScene answers a failed lookup with 503).
    private static let finalLaunchStatuses: Set<Int> = [HTTPStatus.badRequest, HTTPStatus.notFound]

    /// Code of processScene's answer when the source isn't in storage, since
    /// gaussian-splatting #323.
    private static let missingSourceCode = "source_missing"

    /// Start of that answer's message, for servers without the code, which
    /// send it as `invalid_input` like other 400s (api/src/lib/scenes.ts).
    private static let missingSourceMessage = "Source file not found"

    /// Why an upload failed before sending: the file is missing, unreadable,
    /// a folder, or empty (see `APIClient.checkUploadable(_:)`).
    private static let unsendableFileCodes: Set<URLError.Code> = [
        .fileDoesNotExist,
        .noPermissionsToReadFile,
        .fileIsDirectory,
        .zeroByteResource,
    ]

    /// Whether the run is over: nothing is left for a resume to continue.
    var isFinal: Bool {
        switch self {
        case .processingFailed, .cancelled, .notStarted:
            return true
        default:
            return false
        }
    }

    /// Whether a launch was refused because its upload never arrived. The
    /// API checks before charging, so uploading again and relaunching is safe.
    var isMissingSource: Bool {
        guard let refusal = apiError else {
            return false
        }
        if refusal.code == Self.missingSourceCode {
            return true
        }
        return refusal.statusCode == HTTPStatus.badRequest && refusal.message.hasPrefix(Self.missingSourceMessage)
    }

    /// Whether an upload failed before sending anything, because its file
    /// can't be sent: no resume can send it either.
    var isUnsendableFile: Bool {
        guard case .uploadFailed(let cause) = self, let code = (cause as? URLError)?.code else {
            return false
        }
        return Self.unsendableFileCodes.contains(code)
    }

    /// Whether storage refused an upload outright: a 4xx that isn't worth
    /// repeating, e.g. 403 once the presigned URL expires.
    var isStorageRefusal: Bool {
        guard case .requestFailed(let refusal) = self else {
            return false
        }
        return HTTPStatus.clientError.contains(refusal.statusCode) && !APIClient.isTransient(self)
    }

    /// The error that ends a run after a failed launch, or `nil` when a
    /// resume may still get past it (network, 5xx, 401, 402, 409, 429…).
    /// A launch the API failed (upstream_error) failed the scene, so it ends
    /// as ``processingFailed(_:)``, as a read of the scene would.
    static func ending(_ launchError: Error) -> SplatError? {
        guard let error = launchError as? SplatError, let refusal = error.apiError else {
            return nil
        }
        if refusal.code == APIClient.launchFailedCode {
            return .processingFailed(refusal.message)
        }
        return finalLaunchStatuses.contains(refusal.statusCode) ? error : nil
    }
}
