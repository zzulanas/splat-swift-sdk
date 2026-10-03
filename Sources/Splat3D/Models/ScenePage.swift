import Foundation

// MARK: - ScenePage

/// One page of scenes from ``SplatClient/listScenePage(cursor:limit:)``.
public struct ScenePage: Sendable, Equatable {

    /// Scenes on this page, newest first.
    public let scenes: [SplatScene]

    /// Cursor for the next page, or `nil` on the last page.
    ///
    /// Pass it back to ``SplatClient/listScenePage(cursor:limit:)`` unchanged.
    /// Its format is not part of the API contract and may change.
    public let nextCursor: String?

    /// Whether more scenes follow this page.
    public let hasMore: Bool

    /// Create a page, e.g. for a test double.
    public init(scenes: [SplatScene], nextCursor: String?, hasMore: Bool) {
        self.scenes = scenes
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}
