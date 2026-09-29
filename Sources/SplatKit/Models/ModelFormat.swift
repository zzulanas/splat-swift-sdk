import Foundation

// MARK: - ModelFormat

/// File format of a scene's 3D model, for ``SplatClient/downloadScene(id:format:)``
/// and ``SplatScene/format``.
///
/// The set is open: a format the API adds later keeps its raw value, so
/// `switch` with a `default`.
public struct ModelFormat: RawRepresentable, Hashable, Codable, Sendable, CaseIterable, CustomStringConvertible {

    /// The format as the API names it, e.g. `"sog"`. Also the file extension.
    public let rawValue: String

    /// A format from its API name. Names this SDK doesn't know are kept as they are.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Compressed SOG, the smaller file. The API's default.
    public static let sog = ModelFormat(rawValue: "sog")

    /// Uncompressed PLY.
    public static let ply = ModelFormat(rawValue: "ply")

    /// Every format this SDK names.
    public static let allCases: [ModelFormat] = [.sog, .ply]

    public var description: String {
        rawValue
    }
}
