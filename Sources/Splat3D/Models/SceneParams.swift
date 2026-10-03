import Foundation

// MARK: - ScenePreset

/// Processing quality preset for a scene.
///
/// Higher presets produce better quality but take longer to process.
///
/// | Preset   | Resolution | Iterations | Typical Time |
/// |----------|-----------|------------|--------------|
/// | fast     | 800px     | 3K         | ~3 min       |
/// | standard | 1600px    | 7K         | ~13 min      |
/// | quality  | 1600px    | 15K        | ~25 min      |
/// | ultra    | full-res  | 30K        | ~45 min      |
public enum ScenePreset: String, Codable, Sendable, CaseIterable {
    case fast
    case standard
    case quality
    case ultra
}

// MARK: - SceneParams

/// Configuration parameters for scene processing.
///
/// Use the static presets for common configurations:
///
/// ```swift
/// let scene = try await client.createScene(
///     title: "Living Room",
///     preset: .standard
/// )
/// ```
public struct SceneParams: Sendable, Equatable {

    /// The quality preset controlling resolution and training iterations.
    public let preset: ScenePreset

    /// Whether to generate Level-of-Detail chunks for progressive streaming.
    ///
    /// LOD is recommended for large scenes that will be viewed on the web.
    /// Only the `ultra` static preset enables this by default.
    public let enableLOD: Bool

    /// Create custom scene parameters.
    ///
    /// - Parameters:
    ///   - preset: Quality preset.
    ///   - enableLOD: Whether to generate LOD chunks.
    public init(preset: ScenePreset, enableLOD: Bool) {
        self.preset = preset
        self.enableLOD = enableLOD
    }

    /// Fast preset: 800px resolution, 3K iterations. Best for testing.
    public static let fast = SceneParams(preset: .fast, enableLOD: false)

    /// Standard preset: 1600px resolution, 7K iterations. Good balance of speed and quality.
    public static let standard = SceneParams(preset: .standard, enableLOD: false)

    /// Quality preset: 1600px resolution, 15K iterations. High quality output.
    public static let quality = SceneParams(preset: .quality, enableLOD: false)

    /// Ultra preset: full resolution, 30K iterations, LOD enabled. Maximum quality.
    public static let ultra = SceneParams(preset: .ultra, enableLOD: true)
}
