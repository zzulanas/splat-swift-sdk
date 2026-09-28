import XCTest
@testable import SplatKit

// MARK: - Pagination tests

extension SplatClientTests {

    /// The raw (still percent-encoded) query string of a captured request.
    private func encodedQuery(_ request: URLRequest?) -> String? {
        guard let url = request?.url else {
            return nil
        }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
    }

    func testListScenePageReturnsCursorAndHasMore() async throws {
        MockURLProtocol.stub("/v1/scenes", .json(200, Fixture.scenePageOne))

        let page = try await makeClient().listScenePage(limit: 2)

        XCTAssertEqual(page.scenes.map(\.id), ["a1b2c3d4e5f6", "0f1e2d3c4b5a"])
        XCTAssertEqual(page.nextCursor, Fixture.pageOneCursor)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(encodedQuery(MockURLProtocol.capturedRequests.first), "limit=2")
    }

    func testCursorIsSentPercentEncoded() async throws {
        MockURLProtocol.stub("/v1/scenes", .json(200, Fixture.scenePageTwo))

        let page = try await makeClient().listScenePage(cursor: Fixture.pageOneCursor, limit: 2)

        XCTAssertNil(page.nextCursor)
        XCTAssertFalse(page.hasMore)
        // A bare "+" would reach the API as a space and break the cursor.
        XCTAssertEqual(
            encodedQuery(MockURLProtocol.capturedRequests.first),
            "cursor=2026-09-27T09%3A30%3A00.654321%2B00%3A00&limit=2"
        )
    }

    func testAllScenesWalksEveryPage() async throws {
        MockURLProtocol.stub(
            "/v1/scenes",
            .json(200, Fixture.scenePageOne),
            .json(200, Fixture.scenePageTwo)
        )

        var ids: [String] = []
        for try await scene in makeClient().allScenes(pageSize: 2) {
            ids.append(scene.id)
        }

        XCTAssertEqual(ids, ["a1b2c3d4e5f6", "0f1e2d3c4b5a", "9a8b7c6d5e4f"])
        let queries = MockURLProtocol.capturedRequests.map(encodedQuery)
        XCTAssertEqual(queries, [
            "limit=2",
            "cursor=2026-09-27T09%3A30%3A00.654321%2B00%3A00&limit=2",
        ])
    }

    func testAllScenesFetchesLazily() async throws {
        MockURLProtocol.stub(
            "/v1/scenes",
            .json(200, Fixture.scenePageOne),
            .json(200, Fixture.scenePageTwo)
        )

        for try await _ in makeClient().allScenes(pageSize: 2) {
            break
        }

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
    }

    func testAllScenesThrowsWhenAPageFails() async throws {
        MockURLProtocol.stub(
            "/v1/scenes",
            .json(200, Fixture.scenePageOne),
            .json(500, Fixture.internalError)
        )

        var ids: [String] = []
        do {
            for try await scene in makeClient().allScenes(pageSize: 2) {
                ids.append(scene.id)
            }
            XCTFail("Expected the second page to fail")
        } catch let error as SplatError {
            XCTAssertEqual(error.apiError?.statusCode, 500)
        }

        XCTAssertEqual(ids, ["a1b2c3d4e5f6", "0f1e2d3c4b5a"])
    }
}
