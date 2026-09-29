import Foundation

// MARK: - SceneStatus

/// Processing status of a scene, as the API reports it.
///
/// A scene moves through these statuses while it processes:
///
/// ```
/// uploading -> preview_extracting -> preview_generating -> preview_compressing
///           -> extracting_frames -> estimating_poses -> training -> exporting -> compressing
///           -> complete | failed | cancelled
/// ```
///
/// The set is open. The API adds pipeline stages over time, and a status this
/// SDK doesn't name still decodes with its raw value. Anything other than
/// ``complete``, ``failed`` and ``cancelled`` is still in progress, so match the
/// statuses you care about and handle the rest with `default`.
public struct SceneStatus: RawRepresentable, Hashable, Codable, Sendable, CaseIterable, CustomStringConvertible {

    /// The status as the API sends it, e.g. `"estimating_poses"`.
    public let rawValue: String

    /// A status from its API value. Values this SDK doesn't name are kept as they are.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    // MARK: Before processing

    /// The scene exists and waits for its source. No processing job has started.
    public static let uploading = SceneStatus(rawValue: "uploading")

    // MARK: Preview

    /// Frames are being extracted for the fast preview.
    public static let previewExtracting = SceneStatus(rawValue: "preview_extracting")

    /// The fast preview is being generated.
    public static let previewGenerating = SceneStatus(rawValue: "preview_generating")

    /// The fast preview is being compressed.
    public static let previewCompressing = SceneStatus(rawValue: "preview_compressing")

    /// A fast preview is viewable; full processing is still running.
    public static let previewReady = SceneStatus(rawValue: "preview_ready")

    // MARK: Full processing

    /// Frames are being extracted from the uploaded source.
    public static let extractingFrames = SceneStatus(rawValue: "extracting_frames")

    /// Camera poses are being estimated, by Structure from Motion or from ARKit poses.
    public static let estimatingPoses = SceneStatus(rawValue: "estimating_poses")

    /// Older name for ``estimatingPoses``, still stored for some scenes.
    public static let runningSfm = SceneStatus(rawValue: "running_sfm")

    /// The Gaussian splat model is being trained.
    public static let training = SceneStatus(rawValue: "training")

    /// The trained model is being exported.
    public static let exporting = SceneStatus(rawValue: "exporting")

    /// The model is being compressed to SOG.
    public static let compressing = SceneStatus(rawValue: "compressing")

    /// Processing is running. The API reports this while it reads live progress.
    public static let processing = SceneStatus(rawValue: "processing")

    // MARK: Terminal

    /// Processing completed successfully.
    public static let complete = SceneStatus(rawValue: "complete")

    /// Processing failed. Check ``SplatScene/processingError`` for details.
    public static let failed = SceneStatus(rawValue: "failed")

    /// Processing was cancelled.
    public static let cancelled = SceneStatus(rawValue: "cancelled")

    /// Every status this SDK names, in pipeline order. It grows when the SDK
    /// names a new stage, so don't use it as a fixed-size or indexed list.
    public static let allCases: [SceneStatus] = [
        .uploading,
        .previewExtracting,
        .previewGenerating,
        .previewCompressing,
        .previewReady,
        .extractingFrames,
        .runningSfm,
        .estimatingPoses,
        .training,
        .exporting,
        .compressing,
        .processing,
        .complete,
        .failed,
        .cancelled,
    ]

    /// Statuses a scene never leaves on its own.
    private static let terminal: Set<SceneStatus> = [.complete, .failed, .cancelled]

    /// Whether processing has stopped: ``complete``, ``failed`` or ``cancelled``.
    public var isTerminal: Bool {
        Self.terminal.contains(self)
    }

    public var description: String {
        rawValue
    }
}

// MARK: - SplatScene

/// A 3D Gaussian Splat scene.
///
/// Scenes are created by uploading a video, then processed on GPU to produce
/// an interactive 3D model. Query the ``status`` property to track progress.
///
/// ```swift
/// let scene = try await client.getScene(id: "abc123")
/// if scene.isComplete {
///     print("View at: \(scene.viewerURL!)")
/// }
/// ```
public struct SplatScene: Codable, Identifiable, Sendable, Equatable {

    /// Unique scene identifier.
    public let id: String

    /// User-provided scene title.
    public let title: String?

    /// Physical address or location (optional).
    public let address: String?

    /// Current processing status.
    public let status: SceneStatus

    /// Whether the scene is publicly viewable.
    public let isPublic: Bool

    /// Detailed processing stage (may differ from top-level status during transitions).
    public let processingStage: String?

    /// Processing progress as a percentage (0-100), or `nil` if not available.
    public let processingPct: Double?

    /// Number of Gaussians in the trained model (available after training completes).
    public let numGaussians: Int?

    /// URL of the scene thumbnail image, or `nil` if not yet generated.
    public let thumbnailURL: URL?

    /// Error message when processing failed, or `nil` if no error.
    public let processingError: String?

    /// Viewer URL for the scene on splat-3d.com.
    /// Decoded from the server response; falls back to a locally-constructed URL for
    /// backwards compatibility with older API responses.
    public let viewerURL: URL?

    /// API URL for the scene's 3D model, once processing is complete.
    ///
    /// It serves SOG by default and PLY with `?format=ply`. It requires your
    /// API key as a Bearer token, so a browser, web view or `URLSession.shared`
    /// gets a 401 from it.
    public let downloadURL: URL?

    /// Output format of the processed scene (e.g. "sog", "ply").
    public let format: String?

    /// When the scene was created.
    public let createdAt: Date

    /// When the scene was last updated.
    public let updatedAt: Date

    /// Whether processing has completed successfully.
    public var isComplete: Bool { status == .complete }

    /// Whether processing has failed.
    public var isFailed: Bool { status == .failed }

    /// Whether the scene is still in progress: any status that isn't
    /// terminal, including ``SceneStatus/uploading`` and stages this SDK
    /// doesn't name.
    public var isProcessing: Bool {
        !status.isTerminal
    }

    // MARK: - Coding Keys

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case address
        case status
        case isPublic = "is_public"
        case processingStage = "processing_stage"
        case processingPct = "processing_pct"
        case numGaussians = "num_gaussians"
        case thumbnailR2Key = "thumbnail_r2_key"
        case processingError = "processing_error"
        case viewerURLKey = "viewer_url"
        case downloadURL = "download_url"
        case format
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    // We need a custom initializer because thumbnailURL is derived from thumbnail_r2_key
    private let thumbnailR2Key: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        address = try container.decodeIfPresent(String.self, forKey: .address)
        status = try container.decode(SceneStatus.self, forKey: .status)
        isPublic = try container.decodeIfPresent(Bool.self, forKey: .isPublic) ?? false
        processingStage = try container.decodeIfPresent(String.self, forKey: .processingStage)
        processingPct = try container.decodeIfPresent(Double.self, forKey: .processingPct)
        numGaussians = try container.decodeIfPresent(Int.self, forKey: .numGaussians)
        thumbnailR2Key = try container.decodeIfPresent(String.self, forKey: .thumbnailR2Key)
        processingError = try container.decodeIfPresent(String.self, forKey: .processingError)
        downloadURL = try container.decodeIfPresent(URL.self, forKey: .downloadURL)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        // Build thumbnail URL from the scene ID (API route, not R2 key), on
        // the deployment the scene came from.
        if thumbnailR2Key != nil {
            let apiBase = decoder.userInfo[.splatBaseURL] as? URL ?? SplatScene.productionAPI
            thumbnailURL = apiBase.appendingPathComponent("v1/scenes/\(id)/thumbnail")
        } else {
            thumbnailURL = nil
        }

        // Prefer server-provided viewer URL; fall back to local construction for backwards compat
        let serverViewerURL = try container.decodeIfPresent(URL.self, forKey: .viewerURLKey)
        viewerURL = serverViewerURL ?? SplatScene.fallbackViewerURL(id: id, status: status)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(address, forKey: .address)
        try container.encode(status, forKey: .status)
        try container.encode(isPublic, forKey: .isPublic)
        try container.encodeIfPresent(processingStage, forKey: .processingStage)
        try container.encodeIfPresent(processingPct, forKey: .processingPct)
        try container.encodeIfPresent(numGaussians, forKey: .numGaussians)
        try container.encodeIfPresent(thumbnailR2Key, forKey: .thumbnailR2Key)
        try container.encodeIfPresent(processingError, forKey: .processingError)
        try container.encodeIfPresent(viewerURL, forKey: .viewerURLKey)
        try container.encodeIfPresent(downloadURL, forKey: .downloadURL)
        try container.encodeIfPresent(format, forKey: .format)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    /// Memberwise initializer for testing and internal use.
    public init(
        id: String,
        title: String? = nil,
        address: String? = nil,
        status: SceneStatus,
        isPublic: Bool = false,
        processingStage: String? = nil,
        processingPct: Double? = nil,
        numGaussians: Int? = nil,
        thumbnailURL: URL? = nil,
        processingError: String? = nil,
        viewerURL: URL? = nil,
        downloadURL: URL? = nil,
        format: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.address = address
        self.status = status
        self.isPublic = isPublic
        self.processingStage = processingStage
        self.processingPct = processingPct
        self.numGaussians = numGaussians
        self.thumbnailURL = thumbnailURL
        self.thumbnailR2Key = thumbnailURL != nil ? "scenes/\(id)/thumbnail.jpg" : nil
        self.processingError = processingError
        self.viewerURL = viewerURL ?? SplatScene.fallbackViewerURL(id: id, status: status)
        self.downloadURL = downloadURL
        self.format = format
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Equatable conformance (ignores derived thumbnailURL — compares all stored properties).
    public static func == (lhs: SplatScene, rhs: SplatScene) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.address == rhs.address
            && lhs.status == rhs.status
            && lhs.isPublic == rhs.isPublic
            && lhs.processingStage == rhs.processingStage
            && lhs.processingPct == rhs.processingPct
            && lhs.numGaussians == rhs.numGaussians
            && lhs.processingError == rhs.processingError
            && lhs.viewerURL == rhs.viewerURL
            && lhs.downloadURL == rhs.downloadURL
            && lhs.format == rhs.format
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
    }
}

// MARK: - Thumbnail URL

extension CodingUserInfoKey {

    /// The API a response came from, so decoded URLs point back at it.
    static let splatBaseURL = CodingUserInfoKey(rawValue: "SplatKit.baseURL")!
}

extension SplatScene {

    /// Thumbnail host when a scene is decoded outside ``SplatClient``.
    fileprivate static let productionAPI = URL(string: "https://api.splat-3d.com")!
}

// MARK: - Viewer URL

extension SplatScene {
    /// Public viewer route on splat-3d.com. The older `/s/{id}` route was
    /// retired and now returns 404.
    private static let viewerBase = "https://splat-3d.com/tour/"

    /// Viewer link for responses that predate the server's `viewer_url`.
    private static func fallbackViewerURL(id: String, status: SceneStatus) -> URL? {
        guard status == .complete else {
            return nil
        }
        return URL(string: viewerBase + id)
    }
}
