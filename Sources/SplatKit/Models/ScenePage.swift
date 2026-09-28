import Foundation

// MARK: - ScenePage

/// One page of scenes from ``SplatClient/listScenePage(cursor:limit:)``.
public struct ScenePage: Sendable, Equatable {

    /// Scenes on this page, newest first.
    public let scenes: [Scene]

    /// Cursor for the next page, or `nil` on the last page.
    ///
    /// Pass it back to ``SplatClient/listScenePage(cursor:limit:)`` unchanged.
    /// Its format is not part of the API contract and may change.
    public let nextCursor: String?

    /// Whether more scenes follow this page.
    public let hasMore: Bool
}
