import Foundation

// MARK: - SceneStatus

/// Processing status of a scene.
///
/// A scene progresses through these statuses during the processing pipeline:
///
/// ```
/// uploading -> extracting_frames -> running_sfm -> training -> exporting -> compressing -> complete
///                                                                                       -> failed
/// ```
public enum SceneStatus: String, Codable, Sendable, CaseIterable {
    /// Video is being uploaded to storage.
    case uploading

    /// Frames are being extracted from the uploaded video.
    case extractingFrames = "extracting_frames"

    /// Structure from Motion is running (GLOMAP or ARKit poses).
    case runningSfm = "running_sfm"

    /// Gaussian splat model is being trained.
    case training

    /// Trained model is being exported.
    case exporting

    /// Model is being compressed to SOG format.
    case compressing

    /// Processing completed successfully.
    case complete

    /// Processing failed. Check ``Scene/processingError`` for details.
    case failed

    /// Processing was cancelled by the user.
    case cancelled

    /// Alias for backwards compatibility with API responses that use "processing".
    case processing
}

// MARK: - Scene

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
public struct Scene: Codable, Identifiable, Sendable, Equatable {

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

    /// Viewer URL for the scene on splat-3d.com.
    public var viewerURL: URL? {
        guard status == .complete else { return nil }
        return URL(string: "https://splat-3d.com/s/\(id)")
    }

    /// When the scene was created.
    public let createdAt: Date

    /// When the scene was last updated.
    public let updatedAt: Date

    /// Whether processing has completed successfully.
    public var isComplete: Bool { status == .complete }

    /// Whether processing has failed.
    public var isFailed: Bool { status == .failed }

    /// Whether the scene is currently being processed.
    public var isProcessing: Bool {
        switch status {
        case .uploading, .extractingFrames, .runningSfm, .training, .exporting, .compressing, .processing:
            return true
        case .complete, .failed, .cancelled:
            return false
        }
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
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        // Build thumbnail URL from the scene ID (API route, not R2 key)
        if thumbnailR2Key != nil {
            thumbnailURL = URL(string: "https://api.splat-3d.com/v1/scenes/\(id)/thumbnail")
        } else {
            thumbnailURL = nil
        }
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Equatable conformance (ignores derived thumbnailURL — compares all stored properties).
    public static func == (lhs: Scene, rhs: Scene) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.address == rhs.address
            && lhs.status == rhs.status
            && lhs.isPublic == rhs.isPublic
            && lhs.processingStage == rhs.processingStage
            && lhs.processingPct == rhs.processingPct
            && lhs.numGaussians == rhs.numGaussians
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
    }
}
