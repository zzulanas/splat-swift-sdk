import Foundation

// MARK: - SceneUpdate

/// Changes for ``SplatClient/updateScene(id:_:)``.
///
/// Only fields that are set are sent; `nil` fields keep their current value.
///
/// ```swift
/// var update = SceneUpdate(title: "Kitchen")
/// update.isPublic = true
/// ```
public struct SceneUpdate: Sendable, Equatable {

    /// New title, up to 200 characters. An empty string clears it.
    public var title: String?

    /// New address, up to 500 characters. An empty string clears it.
    public var address: String?

    /// New description, up to 2,000 characters. An empty string clears it.
    public var description: String?

    /// Whether the scene is publicly viewable.
    public var isPublic: Bool?

    /// Create an update. Omitted fields are left unchanged.
    public init(
        title: String? = nil,
        address: String? = nil,
        description: String? = nil,
        isPublic: Bool? = nil
    ) {
        self.title = title
        self.address = address
        self.description = description
        self.isPublic = isPublic
    }
}
