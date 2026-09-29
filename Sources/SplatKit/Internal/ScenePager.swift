import Foundation

// MARK: - ScenePager

/// Walks `GET /v1/scenes` for ``SplatClient/allScenes(pageSize:)``, fetching
/// the next page only when the caller asks for another scene.
actor ScenePager {

    private let client: SplatClient
    private let pageSize: Int?
    private var buffered: [SplatScene] = []
    private var cursor: String?
    private var exhausted = false

    init(client: SplatClient, pageSize: Int?) {
        self.client = client
        self.pageSize = pageSize
    }

    /// The next scene, or `nil` after the last page.
    func next() async throws -> SplatScene? {
        while buffered.isEmpty {
            guard !exhausted else {
                return nil
            }

            let page = try await client.listScenePage(cursor: cursor, limit: pageSize)
            buffered = page.scenes
            cursor = page.nextCursor

            // The API never reports more results after an empty page; stopping
            // on one also ends the walk if a cursor ever fails to advance.
            exhausted = !page.hasMore || page.nextCursor == nil || page.scenes.isEmpty
        }

        return buffered.removeFirst()
    }
}
