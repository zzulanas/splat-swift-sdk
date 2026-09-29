import Foundation

// MARK: - SceneSequence

/// Every scene for the authenticated user, newest first, from
/// ``SplatClient/allScenes(pageSize:)``.
///
/// Pages are fetched as you iterate, so stopping early stops fetching. A
/// cancelled task ends the iteration by throwing `CancellationError`, never by
/// finishing early, so a partial list can't pass for a complete one.
public struct SceneSequence: AsyncSequence, Sendable {

    public typealias Element = Scene

    private let client: SplatClient
    private let pageSize: Int?

    init(client: SplatClient, pageSize: Int?) {
        self.client = client
        self.pageSize = pageSize
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(pager: ScenePager(client: client, pageSize: pageSize))
    }

    // MARK: - Iterator

    /// Hands out buffered scenes and fetches the next page when they run out.
    public struct Iterator: AsyncIteratorProtocol {

        private let pager: ScenePager

        init(pager: ScenePager) {
            self.pager = pager
        }

        public mutating func next() async throws -> Scene? {
            // Checked before every scene, buffered or not: a stream that just
            // stops would look like the last page.
            try Task.checkCancellation()

            do {
                return try await pager.next()
            } catch {
                // A page request cut off by cancellation reads as cancellation.
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw error
            }
        }
    }
}
