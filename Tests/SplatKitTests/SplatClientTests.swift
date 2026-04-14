import XCTest
@testable import SplatKit

// MARK: - Mock URLProtocol

/// A URLProtocol subclass that intercepts all requests and returns mock responses.
final class MockURLProtocol: URLProtocol {

    /// Map of URL path -> (statusCode, responseData)
    /// Set this before running each test.
    static var mockResponses: [String: (Int, Data)] = [:]

    /// Captured requests for assertion.
    static var capturedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        // Preserve httpBody from the stream if the body was consumed by URLSession
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let stream = capturedRequest.httpBodyStream {
            stream.open()
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4096)
                if count > 0 { data.append(buffer, count: count) }
                else { break }
            }
            stream.close()
            capturedRequest.httpBody = data
        }
        Self.capturedRequests.append(capturedRequest)

        let path = request.url?.path ?? ""

        if let (statusCode, data) = Self.mockResponses[path] {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
        } else {
            // Default: 404
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            let errorBody = """
            {"error":{"code":"not_found","message":"Not found"},"meta":{"request_id":"test-id"}}
            """
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: errorBody.data(using: .utf8)!)
        }

        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Reset all mock state between tests.
    static func reset() {
        mockResponses = [:]
        capturedRequests = []
    }
}

// MARK: - Test Helpers

extension SplatClientTests {

    func makeClient() -> SplatClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)

        return SplatClient(
            apiKey: "s3d_test_key_12345",
            baseURL: URL(string: "https://api.splat-3d.com")!,
            session: session
        )
    }

    func mockJSON(_ value: String) -> Data {
        value.data(using: .utf8)!
    }
}

// MARK: - SplatClientTests

final class SplatClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    // MARK: - createScene

    func testCreateSceneReturnsSceneIdAndUploadURL() async throws {
        let responseJSON = """
        {
            "data": {
                "sceneId": "abc123",
                "uploadUrl": "https://r2.dev/upload?token=xyz"
            },
            "meta": {
                "request_id": "req-001"
            }
        }
        """
        MockURLProtocol.mockResponses["/v1/scenes"] = (201, mockJSON(responseJSON))

        let client = makeClient()
        let (sceneId, uploadURL) = try await client.createScene(title: "Test Scene", preset: .standard)

        XCTAssertEqual(sceneId, "abc123")
        XCTAssertEqual(uploadURL.absoluteString, "https://r2.dev/upload?token=xyz")

        // Verify the request was sent correctly
        let captured = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.path, "/v1/scenes")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer s3d_test_key_12345")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Content-Type"), "application/json")

        // Verify the request body
        if let body = captured?.httpBody {
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["title"] as? String, "Test Scene")
            XCTAssertEqual(json?["preset"] as? String, "standard")
            XCTAssertEqual(json?["content_type"] as? String, "video/mp4")
        } else {
            XCTFail("Request body should not be nil")
        }
    }

    // MARK: - processScene

    func testProcessSceneSendsCorrectBodyWithPoses() async throws {
        // Mock the process endpoint
        let processJSON = """
        {
            "data": {
                "status": "processing",
                "sceneId": "abc123",
                "message": "Processing started"
            },
            "meta": {
                "request_id": "req-002"
            }
        }
        """
        MockURLProtocol.mockResponses["/v1/scenes/abc123/process"] = (200, mockJSON(processJSON))

        // Mock the getScene endpoint (called after process)
        let sceneJSON = """
        {
            "data": {
                "id": "abc123",
                "title": "Test",
                "address": null,
                "status": "processing",
                "is_public": false,
                "processing_stage": "extracting_frames",
                "processing_pct": 10.0,
                "num_gaussians": null,
                "thumbnail_r2_key": null,
                "created_at": "2026-04-14T12:00:00Z",
                "updated_at": "2026-04-14T12:01:00Z"
            },
            "meta": {
                "request_id": "req-003"
            }
        }
        """
        MockURLProtocol.mockResponses["/v1/scenes/abc123"] = (200, mockJSON(sceneJSON))

        let client = makeClient()

        let poses = [
            ARKitPose(
                timestamp: 1.234,
                filePath: "frame_000000.jpg",
                transform: [
                    1, 0, 0, 0,      // col 0
                    0, 1, 0, 0,      // col 1
                    0, 0, 1, 0,      // col 2
                    0.5, 1.0, 0.3, 1, // col 3 (translation)
                ],
                intrinsics: [
                    1440, 0, 960,
                    0, 1440, 720,
                    0, 0, 1,
                ],
                width: 1920,
                height: 1440
            ),
        ]

        let scene = try await client.processScene(id: "abc123", arkitPoses: poses)

        XCTAssertEqual(scene.id, "abc123")
        XCTAssertEqual(scene.status, .processing)

        // Verify the process request body contains ARKit poses
        let processRequest = MockURLProtocol.capturedRequests.first { $0.url?.path == "/v1/scenes/abc123/process" }
        XCTAssertNotNil(processRequest)

        if let body = processRequest?.httpBody {
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]

            // SDK should NOT send sfm — the API infers it from arkit_poses presence
            XCTAssertNil(json?["sfm"], "SDK should not send sfm; API infers from arkit_poses")

            // Should have arkit_poses array
            let arkitPoses = json?["arkit_poses"] as? [[String: Any]]
            XCTAssertEqual(arkitPoses?.count, 1)
            XCTAssertEqual(arkitPoses?.first?["timestamp"] as? Double, 1.234)
            XCTAssertEqual(arkitPoses?.first?["file_path"] as? String, "frame_000000.jpg")
            XCTAssertEqual(arkitPoses?.first?["width"] as? Int, 1920)
            XCTAssertEqual(arkitPoses?.first?["height"] as? Int, 1440)

            // Transform should be flat 16-element array, not nested
            let firstPoseTransform = arkitPoses?.first?["transform"] as? [NSNumber]
            XCTAssertEqual(firstPoseTransform?.count, 16)

            // Intrinsics should be flat 9-element array, not nested
            let firstPoseIntrinsics = arkitPoses?.first?["intrinsics"] as? [NSNumber]
            XCTAssertEqual(firstPoseIntrinsics?.count, 9)
        } else {
            XCTFail("Process request body should not be nil")
        }
    }

    // MARK: - getScene

    func testGetSceneDecodesAllStatuses() async throws {
        let statuses: [(String, SceneStatus)] = [
            ("uploading", .uploading),
            ("extracting_frames", .extractingFrames),
            ("running_sfm", .runningSfm),
            ("training", .training),
            ("exporting", .exporting),
            ("compressing", .compressing),
            ("complete", .complete),
            ("failed", .failed),
            ("cancelled", .cancelled),
        ]

        let client = makeClient()

        for (rawStatus, expectedStatus) in statuses {
            MockURLProtocol.reset()

            let json = """
            {
                "data": {
                    "id": "scene-\(rawStatus)",
                    "title": null,
                    "address": null,
                    "status": "\(rawStatus)",
                    "is_public": false,
                    "processing_stage": null,
                    "processing_pct": null,
                    "num_gaussians": null,
                    "thumbnail_r2_key": null,
                    "created_at": "2026-04-14T12:00:00Z",
                    "updated_at": "2026-04-14T12:00:00Z"
                },
                "meta": {
                    "request_id": "req-\(rawStatus)"
                }
            }
            """
            MockURLProtocol.mockResponses["/v1/scenes/scene-\(rawStatus)"] = (200, mockJSON(json))

            let scene = try await client.getScene(id: "scene-\(rawStatus)")
            XCTAssertEqual(scene.status, expectedStatus, "Failed to decode status: \(rawStatus)")
        }
    }

    func testGetSceneCompleteHasViewerURL() async throws {
        let json = """
        {
            "data": {
                "id": "complete-scene",
                "title": "My Room",
                "address": "123 Main St",
                "status": "complete",
                "is_public": true,
                "processing_stage": null,
                "processing_pct": 100.0,
                "num_gaussians": 500000,
                "thumbnail_r2_key": "scenes/complete-scene/thumbnail.jpg",
                "created_at": "2026-04-14T12:00:00Z",
                "updated_at": "2026-04-14T12:05:00Z"
            },
            "meta": {
                "request_id": "req-complete"
            }
        }
        """
        MockURLProtocol.mockResponses["/v1/scenes/complete-scene"] = (200, mockJSON(json))

        let client = makeClient()
        let scene = try await client.getScene(id: "complete-scene")

        XCTAssertTrue(scene.isComplete)
        XCTAssertFalse(scene.isFailed)
        XCTAssertFalse(scene.isProcessing)
        XCTAssertEqual(scene.viewerURL?.absoluteString, "https://splat-3d.com/s/complete-scene")
        XCTAssertNotNil(scene.thumbnailURL)
        XCTAssertEqual(scene.numGaussians, 500000)
        XCTAssertEqual(scene.title, "My Room")
        XCTAssertEqual(scene.address, "123 Main St")
        XCTAssertTrue(scene.isPublic)
    }

    // MARK: - listScenes

    func testListScenesReturnsArray() async throws {
        let json = """
        {
            "data": [
                {
                    "id": "scene-1",
                    "title": "Scene One",
                    "address": null,
                    "status": "complete",
                    "is_public": false,
                    "processing_stage": null,
                    "processing_pct": null,
                    "num_gaussians": 100000,
                    "thumbnail_r2_key": null,
                    "created_at": "2026-04-14T12:00:00Z",
                    "updated_at": "2026-04-14T12:00:00Z"
                },
                {
                    "id": "scene-2",
                    "title": "Scene Two",
                    "address": null,
                    "status": "processing",
                    "is_public": false,
                    "processing_stage": "training",
                    "processing_pct": 45.0,
                    "num_gaussians": null,
                    "thumbnail_r2_key": null,
                    "created_at": "2026-04-14T13:00:00Z",
                    "updated_at": "2026-04-14T13:00:00Z"
                }
            ],
            "meta": {
                "request_id": "req-list",
                "next_cursor": null,
                "has_more": false,
                "count": 2
            }
        }
        """
        MockURLProtocol.mockResponses["/v1/scenes"] = (200, mockJSON(json))

        let client = makeClient()
        let scenes = try await client.listScenes()

        XCTAssertEqual(scenes.count, 2)
        XCTAssertEqual(scenes[0].id, "scene-1")
        XCTAssertEqual(scenes[0].status, .complete)
        XCTAssertEqual(scenes[1].id, "scene-2")
        XCTAssertEqual(scenes[1].status, .processing)
        XCTAssertEqual(scenes[1].processingPct, 45.0)
    }

    // MARK: - Error Handling

    func testUnauthorizedThrowsSplatError() async throws {
        let json = """
        {
            "error": {"code": "unauthorized", "message": "Invalid API key."},
            "meta": {"request_id": "req-err"}
        }
        """
        MockURLProtocol.mockResponses["/v1/scenes"] = (401, mockJSON(json))

        let client = makeClient()

        do {
            _ = try await client.listScenes()
            XCTFail("Should have thrown unauthorized")
        } catch let error as SplatError {
            if case .unauthorized = error {
                // Expected
            } else {
                XCTFail("Expected .unauthorized, got \(error)")
            }
        }
    }

    func testNotFoundThrowsSplatError() async throws {
        let json = """
        {
            "error": {"code": "not_found", "message": "Scene not found."},
            "meta": {"request_id": "req-404"}
        }
        """
        MockURLProtocol.mockResponses["/v1/scenes/nonexistent"] = (404, mockJSON(json))

        let client = makeClient()

        do {
            _ = try await client.getScene(id: "nonexistent")
            XCTFail("Should have thrown notFound")
        } catch let error as SplatError {
            if case .notFound(let message) = error {
                XCTAssertEqual(message, "Scene not found.")
            } else {
                XCTFail("Expected .notFound, got \(error)")
            }
        }
    }

    func testRateLimitedThrowsSplatError() async throws {
        let json = """
        {
            "error": {"code": "rate_limited", "message": "Too many requests."},
            "meta": {"request_id": "req-429"}
        }
        """
        MockURLProtocol.mockResponses["/v1/scenes"] = (429, mockJSON(json))

        let client = makeClient()

        do {
            _ = try await client.listScenes()
            XCTFail("Should have thrown rateLimited")
        } catch let error as SplatError {
            if case .rateLimited = error {
                // Expected
            } else {
                XCTFail("Expected .rateLimited, got \(error)")
            }
        }
    }

    func testServerErrorThrowsSplatError() async throws {
        let json = """
        {
            "error": {"code": "internal", "message": "Something went wrong."},
            "meta": {"request_id": "req-500"}
        }
        """
        MockURLProtocol.mockResponses["/v1/scenes"] = (500, mockJSON(json))

        let client = makeClient()

        do {
            _ = try await client.listScenes()
            XCTFail("Should have thrown serverError")
        } catch let error as SplatError {
            if case .serverError(let code, let message) = error {
                XCTAssertEqual(code, 500)
                XCTAssertEqual(message, "Something went wrong.")
            } else {
                XCTFail("Expected .serverError, got \(error)")
            }
        }
    }

    // MARK: - deleteScene

    func testDeleteSceneSucceeds() async throws {
        MockURLProtocol.mockResponses["/v1/scenes/to-delete"] = (204, Data())

        let client = makeClient()
        try await client.deleteScene(id: "to-delete")

        let captured = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(captured?.httpMethod, "DELETE")
        XCTAssertEqual(captured?.url?.path, "/v1/scenes/to-delete")
    }

    // MARK: - Authorization Header

    func testAuthorizationHeaderIncluded() async throws {
        let json = """
        {
            "data": [],
            "meta": {"request_id": "req-auth", "next_cursor": null, "has_more": false, "count": 0}
        }
        """
        MockURLProtocol.mockResponses["/v1/scenes"] = (200, mockJSON(json))

        let client = makeClient()
        _ = try await client.listScenes()

        let captured = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer s3d_test_key_12345")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "User-Agent"), "SplatKit/1.0")
    }

    // MARK: - Date Decoding

    func testDateDecodingWithFractionalSeconds() async throws {
        let json = """
        {
            "data": {
                "id": "date-test",
                "title": null,
                "address": null,
                "status": "complete",
                "is_public": false,
                "processing_stage": null,
                "processing_pct": null,
                "num_gaussians": null,
                "thumbnail_r2_key": null,
                "created_at": "2026-04-14T12:00:00.123Z",
                "updated_at": "2026-04-14T12:05:30.456Z"
            },
            "meta": {"request_id": "req-date"}
        }
        """
        MockURLProtocol.mockResponses["/v1/scenes/date-test"] = (200, mockJSON(json))

        let client = makeClient()
        let scene = try await client.getScene(id: "date-test")

        // Should not throw — fractional seconds should be parsed correctly
        XCTAssertEqual(scene.id, "date-test")
    }

    // MARK: - Process without poses

    func testProcessSceneWithoutPosesOmitsSfm() async throws {
        let processJSON = """
        {
            "data": {"status": "processing", "sceneId": "no-poses", "message": "Started"},
            "meta": {"request_id": "req-nop"}
        }
        """
        MockURLProtocol.mockResponses["/v1/scenes/no-poses/process"] = (200, mockJSON(processJSON))

        let sceneJSON = """
        {
            "data": {
                "id": "no-poses",
                "title": null,
                "address": null,
                "status": "processing",
                "is_public": false,
                "processing_stage": null,
                "processing_pct": null,
                "num_gaussians": null,
                "thumbnail_r2_key": null,
                "created_at": "2026-04-14T12:00:00Z",
                "updated_at": "2026-04-14T12:00:00Z"
            },
            "meta": {"request_id": "req-nop2"}
        }
        """
        MockURLProtocol.mockResponses["/v1/scenes/no-poses"] = (200, mockJSON(sceneJSON))

        let client = makeClient()
        _ = try await client.processScene(id: "no-poses")

        let processRequest = MockURLProtocol.capturedRequests.first { $0.url?.path == "/v1/scenes/no-poses/process" }
        XCTAssertNotNil(processRequest)

        if let body = processRequest?.httpBody {
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            // sfm should be null/absent when no poses
            XCTAssertNil(json?["sfm"])
            XCTAssertNil(json?["arkit_poses"])
        }
    }
}
