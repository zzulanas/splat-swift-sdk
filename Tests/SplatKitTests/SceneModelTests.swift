import XCTest
@testable import SplatKit

// MARK: - Scene model decoding
//
// Payloads mirror what GET /v1/scenes/{id} returns today (api/src/lib/scenes.ts
// in the gaussian-splatting repo): complete scenes carry viewer_url,
// download_url and format; in-flight scenes may report "preview_ready".

extension SplatClientTests {

    /// A scene payload with the given status and extra JSON fields.
    func scenePayload(id: String, status: String, extra: String = "") -> Data {
        let fields = extra.isEmpty ? "" : ",\n\(extra)"
        return mockJSON("""
        {
            "data": {
                "id": "\(id)",
                "title": null,
                "address": null,
                "status": "\(status)",
                "is_public": false,
                "processing_stage": null,
                "processing_pct": null,
                "num_gaussians": null,
                "thumbnail_r2_key": null,
                "created_at": "2026-09-28T12:00:00Z",
                "updated_at": "2026-09-28T12:00:00Z"\(fields)
            },
            "meta": { "request_id": "req-\(id)" }
        }
        """)
    }

    func testServerViewerURLWins() async throws {
        let extra = """
            "viewer_url": "https://splat-3d.com/tour/server-url",
            "download_url": "https://api.splat-3d.com/v1/scenes/server-url/download",
            "format": "sog"
        """
        MockURLProtocol.mockResponses["/v1/scenes/server-url"] =
            (200, scenePayload(id: "server-url", status: "complete", extra: extra))

        let scene = try await makeClient().getScene(id: "server-url")

        XCTAssertEqual(scene.viewerURL?.absoluteString, "https://splat-3d.com/tour/server-url")
        XCTAssertEqual(scene.downloadURL?.absoluteString, "https://api.splat-3d.com/v1/scenes/server-url/download")
        XCTAssertEqual(scene.format, "sog")
    }

    func testFallbackViewerURLUsesTourRoute() async throws {
        // /s/{id} was retired; it now returns 404 on splat-3d.com.
        let scene = Scene(id: "local", status: .complete)
        XCTAssertEqual(scene.viewerURL?.absoluteString, "https://splat-3d.com/tour/local")
    }

    func testPreviewReadyIsInProgress() async throws {
        MockURLProtocol.mockResponses["/v1/scenes/preview"] =
            (200, scenePayload(id: "preview", status: "preview_ready"))

        let scene = try await makeClient().getScene(id: "preview")

        XCTAssertEqual(scene.status, .previewReady)
        XCTAssertEqual(scene.status.rawValue, "preview_ready")
        XCTAssertTrue(scene.isProcessing)
    }

    func testUnknownStatusDecodesInsteadOfThrowing() async throws {
        MockURLProtocol.mockResponses["/v1/scenes/future"] =
            (200, scenePayload(id: "future", status: "some_future_state"))

        let scene = try await makeClient().getScene(id: "future")

        XCTAssertEqual(scene.status, .unknown("some_future_state"))
        XCTAssertEqual(scene.status.rawValue, "some_future_state")
    }

    func testFailedSceneCarriesProcessingError() async throws {
        let extra = #""processing_error": "Not enough overlap between photos""#
        MockURLProtocol.mockResponses["/v1/scenes/failed-scene"] =
            (200, scenePayload(id: "failed-scene", status: "failed", extra: extra))

        let scene = try await makeClient().getScene(id: "failed-scene")

        XCTAssertTrue(scene.isFailed)
        XCTAssertEqual(scene.processingError, "Not enough overlap between photos")
    }
}
