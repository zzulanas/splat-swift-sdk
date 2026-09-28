import Foundation

// MARK: - ModelFormat

/// File format of a scene's 3D model, for ``SplatClient/downloadScene(id:format:)``.
public enum ModelFormat: String, Sendable, CaseIterable {

    /// Compressed SOG, the smaller file. The API's default.
    case sog

    /// Uncompressed PLY.
    case ply
}
