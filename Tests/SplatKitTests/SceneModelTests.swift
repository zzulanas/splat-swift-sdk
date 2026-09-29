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

        XCTAssertEqual(scene.status, SceneStatus(rawValue: "some_future_state"))
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

// MARK: - Server statuses
//
// Every value the API can put in `status`: the database's tour_stage enum
// (supabase/migrations: create_tours, add_cancelled_stage, add_preview_fields,
// tour_stage_enum_additions in the gaussian-splatting repo), plus
// "processing", which getSceneStatus reports from its live Modal probe
// (api/src/lib/scenes.ts). listScenes and a failed probe return the raw
// database value, so the pipeline's own stages reach clients too.

extension SplatClientTests {

    static let inFlightStatuses = [
        "uploading",
        "preview_extracting",
        "preview_generating",
        "preview_compressing",
        "preview_ready",
        "extracting_frames",
        "running_sfm",
        "estimating_poses",
        "training",
        "exporting",
        "compressing",
        "processing",
    ]

    static let terminalStatuses = ["complete", "failed", "cancelled"]

    /// Decode a scene whose `status` is `raw`.
    func scene(withStatus raw: String) async throws -> Scene {
        MockURLProtocol.mockResponses["/v1/scenes/status-\(raw)"] =
            (200, scenePayload(id: "status-\(raw)", status: raw))
        return try await makeClient().getScene(id: "status-\(raw)")
    }

    func testEveryInFlightServerStatusIsProcessing() async throws {
        for raw in Self.inFlightStatuses {
            let scene = try await scene(withStatus: raw)

            XCTAssertEqual(scene.status.rawValue, raw)
            XCTAssertTrue(scene.isProcessing, "\(raw) is in flight")
        }
    }

    func testTerminalServerStatusesAreNotProcessing() async throws {
        for raw in Self.terminalStatuses {
            let scene = try await scene(withStatus: raw)

            XCTAssertFalse(scene.isProcessing, "\(raw) is terminal")
        }
    }

    func testEveryServerStatusHasAName() {
        let named = Set(SceneStatus.allCases.map(\.rawValue))

        XCTAssertEqual(named, Set(Self.inFlightStatuses + Self.terminalStatuses))
    }

    func testFutureStatusCountsAsProcessing() async throws {
        // Anything that isn't terminal is still in flight, even a stage this
        // SDK has never heard of.
        let scene = try await scene(withStatus: "some_future_stage")

        XCTAssertTrue(scene.isProcessing)
    }
}

// MARK: - Thumbnail URL

extension SplatClientTests {

    func testThumbnailURLUsesTheClientsBaseURL() async throws {
        // A client pointed at another deployment must not link thumbnails
        // to production, where that scene ID doesn't exist.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let staging = try XCTUnwrap(URL(string: "https://api-staging.example.com"))
        let client = SplatClient(apiKey: "s3d_test_key_12345", baseURL: staging, session: URLSession(configuration: config))
        MockURLProtocol.mockResponses["/v1/scenes/thumb"] = (200, mockJSON("""
        {
            "data": {
                "id": "thumb",
                "title": null,
                "address": null,
                "status": "complete",
                "is_public": false,
                "processing_stage": null,
                "processing_pct": 100,
                "num_gaussians": null,
                "thumbnail_r2_key": "tours/thumb/thumbnail.png",
                "created_at": "2026-09-28T12:00:00Z",
                "updated_at": "2026-09-28T12:00:00Z"
            },
            "meta": { "request_id": "req-thumb" }
        }
        """))

        let scene = try await client.getScene(id: "thumb")

        XCTAssertEqual(scene.thumbnailURL?.absoluteString, "https://api-staging.example.com/v1/scenes/thumb/thumbnail")
    }
}
