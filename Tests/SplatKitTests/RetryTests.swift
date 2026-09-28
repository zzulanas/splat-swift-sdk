import XCTest
@testable import SplatKit

// MARK: - Retry, idempotency and polling tests
//
// The fake clock records every backoff and poll interval instead of waiting,
// and its jitter always picks the longest delay, so backoff is 1, 2, 4 s.

extension SplatClientTests {

    /// `Idempotency-Key` headers sent to a path, in order.
    private func idempotencyKeys(_ path: String) -> [String?] {
        MockURLProtocol.requests(to: path).map { $0.value(forHTTPHeaderField: "Idempotency-Key") }
    }

    /// A small local file standing in for a captured video.
    func makeVideo() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("splatkit-\(UUID().uuidString).mp4")
        try Data("video".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Create succeeds and the presigned upload (to r2.dev/upload, from the
    /// createScene fixture) accepts the file.
    func stubCreateAndUpload() {
        MockURLProtocol.stub("/v1/scenes", .json(201, Fixture.createScene))
        MockURLProtocol.stub("/upload", MockURLProtocol.Stub(statusCode: 200, body: Data(), headers: [:]))
    }

    /// Two polls, then the configured timeout.
    private var shortPolling: SplatClient.Configuration {
        var configuration = SplatClient.Configuration()
        configuration.pollingInterval = 10
        configuration.pollingTimeout = 20
        return configuration
    }

    // MARK: - Idempotency

    func testProcessRetriesReuseOneIdempotencyKey() async throws {
        let clock = FakeClock()
        MockURLProtocol.stub(
            "\(Fixture.scenePath)/process",
            .json(503, Fixture.launchUnconfirmed),
            .json(200, Fixture.processAccepted)
        )
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.trainingScene))

        _ = try await makeClient(clock: clock).processScene(id: Fixture.sceneID)

        let keys = idempotencyKeys("\(Fixture.scenePath)/process")
        XCTAssertEqual(keys.count, 2)
        XCTAssertNotNil(keys.first ?? nil)
        XCTAssertEqual(keys.first, keys.last)
        XCTAssertEqual(clock.sleeps, [1])
    }

    func testProcessSendsCallerIdempotencyKey() async throws {
        MockURLProtocol.stub("\(Fixture.scenePath)/process", .json(200, Fixture.processAccepted))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.trainingScene))

        _ = try await makeClient().processScene(id: Fixture.sceneID, idempotencyKey: "launch-7f3a")

        XCTAssertEqual(idempotencyKeys("\(Fixture.scenePath)/process"), ["launch-7f3a"])
    }

    func testProcessConflictIsNeverRetried() async throws {
        let clock = FakeClock()
        MockURLProtocol.stub("\(Fixture.scenePath)/process", .json(409, Fixture.launchConflict))

        let error = await expectSplatError {
            try await self.makeClient(clock: clock).processScene(id: Fixture.sceneID, idempotencyKey: "reused-key")
        }

        XCTAssertEqual(error?.apiError?.code, "conflict")
        XCTAssertEqual(MockURLProtocol.requests(to: "\(Fixture.scenePath)/process").count, 1)
        XCTAssertEqual(clock.sleeps, [])
    }

    // MARK: - Writes without idempotency

    func testCreateIsNotRetried() async throws {
        let clock = FakeClock()
        MockURLProtocol.stub("/v1/scenes", .json(500, Fixture.internalError))

        let error = await expectSplatError { try await self.makeClient(clock: clock).createScene() }

        XCTAssertEqual(error?.apiError?.statusCode, 500)
        XCTAssertEqual(MockURLProtocol.requests(to: "/v1/scenes").count, 1)
        XCTAssertEqual(clock.sleeps, [])
    }

    func testRetrainIsNotRetried() async throws {
        let clock = FakeClock()
        MockURLProtocol.stub("\(Fixture.scenePath)/retrain", .json(500, Fixture.internalError))

        let error = await expectSplatError {
            try await self.makeClient(clock: clock).retrainScene(id: Fixture.sceneID, preset: .quality)
        }

        XCTAssertEqual(error?.apiError?.statusCode, 500)
        XCTAssertEqual(MockURLProtocol.requests(to: "\(Fixture.scenePath)/retrain").count, 1)
        XCTAssertEqual(clock.sleeps, [])
    }

    func testUpdateDeleteAndCancelAreNotRetried() async throws {
        let clock = FakeClock()
        let client = makeClient(clock: clock)
        MockURLProtocol.stub(Fixture.scenePath, .json(500, Fixture.internalError))
        MockURLProtocol.stub("\(Fixture.scenePath)/cancel", .json(500, Fixture.internalError))

        _ = await expectSplatError { try await client.updateScene(id: Fixture.sceneID, SceneUpdate(title: "Kitchen")) }
        _ = await expectSplatError { try await client.deleteScene(id: Fixture.sceneID) }
        _ = await expectSplatError { try await client.cancelScene(id: Fixture.sceneID) }

        let methods = MockURLProtocol.capturedRequests.compactMap(\.httpMethod)
        XCTAssertEqual(methods, ["PATCH", "DELETE", "POST"])
        XCTAssertEqual(clock.sleeps, [])
    }

    // MARK: - Reads

    func testReadsRetryDroppedConnections() async throws {
        let clock = FakeClock()
        MockURLProtocol.stub(
            Fixture.scenePath,
            .failure(.networkConnectionLost),
            .json(200, Fixture.completeScene)
        )

        let scene = try await makeClient(clock: clock).getScene(id: Fixture.sceneID)

        XCTAssertEqual(scene.status, .complete)
        XCTAssertEqual(MockURLProtocol.requests(to: Fixture.scenePath).count, 2)
        XCTAssertEqual(clock.sleeps, [1])
    }

    func testRetriesAreBoundedWithExponentialBackoff() async throws {
        let clock = FakeClock()
        MockURLProtocol.stub(Fixture.scenePath, .json(500, Fixture.internalError))

        let error = await expectSplatError { try await self.makeClient(clock: clock).getScene(id: Fixture.sceneID) }

        XCTAssertEqual(error?.apiError?.statusCode, 500)
        XCTAssertEqual(MockURLProtocol.requests(to: Fixture.scenePath).count, 4)
        XCTAssertEqual(clock.sleeps, [1, 2, 4])
    }

    func testRetryAfterIsHonoured() async throws {
        let clock = FakeClock()
        MockURLProtocol.stub(
            Fixture.scenePath,
            MockURLProtocol.Stub(statusCode: 429, body: Data(), headers: ["Retry-After": "7"]),
            .json(200, Fixture.completeScene)
        )

        _ = try await makeClient(clock: clock).getScene(id: Fixture.sceneID)

        XCTAssertEqual(clock.sleeps, [7])
    }

    func testRetryAfterBeyondCapIsThrown() async throws {
        let clock = FakeClock()
        MockURLProtocol.stub(
            Fixture.scenePath,
            MockURLProtocol.Stub(statusCode: 429, body: Data(), headers: ["Retry-After": "3600"])
        )

        let error = await expectSplatError { try await self.makeClient(clock: clock).getScene(id: Fixture.sceneID) }

        guard case .rateLimited(let apiError) = error else {
            return XCTFail("Expected .rateLimited, got \(String(describing: error))")
        }
        XCTAssertEqual(apiError.retryAfter, 3600)
        XCTAssertEqual(MockURLProtocol.requests(to: Fixture.scenePath).count, 1)
        XCTAssertEqual(clock.sleeps, [])
    }

    func testClientErrorsAreNotRetried() async throws {
        let clock = FakeClock()
        let client = makeClient(clock: clock)
        MockURLProtocol.stub(Fixture.scenePath, .json(404, Fixture.sceneNotFound))
        MockURLProtocol.stub("/v1/scenes", .json(400, Fixture.validationFailure))

        _ = await expectSplatError { try await client.getScene(id: Fixture.sceneID) }
        _ = await expectSplatError { try await client.listScenePage(limit: 0) }

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 2)
        XCTAssertEqual(clock.sleeps, [])
    }

    func testPermanentTransportErrorsAreNotRetried() async throws {
        let clock = FakeClock()
        MockURLProtocol.stub(Fixture.scenePath, .failure(.secureConnectionFailed))

        do {
            _ = try await makeClient(clock: clock).getScene(id: Fixture.sceneID)
            XCTFail("Expected a URLError")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .secureConnectionFailed)
        }

        XCTAssertEqual(MockURLProtocol.requests(to: Fixture.scenePath).count, 1)
    }

    func testDownloadsRetry() async throws {
        let clock = FakeClock()
        MockURLProtocol.stub(
            "\(Fixture.scenePath)/download",
            .json(500, Fixture.internalError),
            MockURLProtocol.Stub(statusCode: 200, body: Data("sog".utf8), headers: ["X-Splat-Format": "sog"])
        )

        let file = try await makeClient(clock: clock).downloadScene(id: Fixture.sceneID)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(try Data(contentsOf: file), Data("sog".utf8))
        XCTAssertEqual(clock.sleeps, [1])
    }

    func testRetriesCanBeTurnedOff() async throws {
        var configuration = SplatClient.Configuration()
        configuration.maxRetries = 0
        MockURLProtocol.stub(Fixture.scenePath, .json(500, Fixture.internalError))

        _ = await expectSplatError { try await self.makeClient(configuration: configuration).getScene(id: Fixture.sceneID) }

        XCTAssertEqual(MockURLProtocol.requests(to: Fixture.scenePath).count, 1)
    }

    // MARK: - Configuration

    func testRequestTimeoutIsConfigurable() async throws {
        var configuration = SplatClient.Configuration()
        configuration.requestTimeout = 12
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.completeScene))

        _ = try await makeClient(configuration: configuration).getScene(id: Fixture.sceneID)

        XCTAssertEqual(MockURLProtocol.capturedRequests.first?.timeoutInterval, 12)
    }

    func testDefaultPollingTimeoutOutlastsServerHardCap() {
        let serverHardCap: TimeInterval = 150 * 60

        let timeout = SplatClient.Configuration().pollingTimeout

        XCTAssertEqual(timeout, 165 * 60)
        XCTAssertGreaterThan(timeout, serverHardCap)
    }

    func testLegacyPollingArgumentsStillApply() async throws {
        // The pre-configuration initializer: a zero timeout gives up before polling.
        let client = SplatClient(apiKey: "s3d_test_key_12345", session: mockSession(), pollingInterval: 5, pollingTimeout: 0)

        let error = await expectSplatError { try await client.waitForScene(id: Fixture.sceneID) }

        guard case .timeout = error else {
            return XCTFail("Expected .timeout, got \(String(describing: error))")
        }
        XCTAssertTrue(MockURLProtocol.capturedRequests.isEmpty)
    }

    // MARK: - Timeout vs failure

    func testClientTimeoutIsNotAFailure() async throws {
        let clock = FakeClock()
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.trainingScene))

        let error = await expectSplatError {
            try await self.makeClient(configuration: self.shortPolling, clock: clock).waitForScene(id: Fixture.sceneID)
        }

        guard case .timeout = error else {
            return XCTFail("Expected .timeout, got \(String(describing: error))")
        }
        XCTAssertEqual(clock.sleeps, [10, 10])
        XCTAssertEqual(MockURLProtocol.requests(to: Fixture.scenePath).count, 2)
    }

    func testServerFailureIsNotATimeout() async throws {
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.sweptScene))

        let error = await expectSplatError { try await self.makeClient().waitForScene(id: Fixture.sceneID) }

        guard case .processingFailed(let message) = error else {
            return XCTFail("Expected .processingFailed, got \(String(describing: error))")
        }
        XCTAssertEqual(message, "Processing timed out — the GPU job did not complete.")
    }

    // MARK: - Scene ID after creation

    /// The interruption `createAndProcess` threw, or a test failure.
    func interruption(
        _ error: SplatError?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> SplatError.Interruption? {
        guard case .interrupted(let interruption) = error else {
            XCTFail("Expected .interrupted, got \(String(describing: error))", file: file, line: line)
            return nil
        }
        return interruption
    }

    func testCreateFailureHasNoSceneID() async throws {
        MockURLProtocol.stub("/v1/scenes", .json(429, Fixture.quotaExceeded))

        let error = await expectSplatError { try await self.makeClient().createAndProcess(videoURL: try self.makeVideo()) }

        // No scene exists yet, so there is nothing to resume.
        guard case .rateLimited = error else {
            return XCTFail("Expected .rateLimited, got \(String(describing: error))")
        }
    }

    func testUploadFailureKeepsSceneID() async throws {
        MockURLProtocol.stub("/v1/scenes", .json(201, Fixture.createScene))
        MockURLProtocol.stub("/upload", MockURLProtocol.Stub(statusCode: 403, body: Data(), headers: [:]))

        let error = await expectSplatError { try await self.makeClient().createAndProcess(videoURL: try self.makeVideo()) }

        let interruption = try XCTUnwrap(interruption(error))
        XCTAssertEqual(interruption.sceneID, Fixture.sceneID)
        XCTAssertEqual(interruption.phase, .upload)
        XCTAssertEqual(error?.apiError?.statusCode, 403)
        XCTAssertTrue(MockURLProtocol.requests(to: "\(Fixture.scenePath)/process").isEmpty)
    }

    func testProcessFailureKeepsSceneID() async throws {
        stubCreateAndUpload()
        MockURLProtocol.stub("\(Fixture.scenePath)/process", .json(402, Fixture.insufficientCredits))

        let error = await expectSplatError { try await self.makeClient().createAndProcess(videoURL: try self.makeVideo()) }

        let interruption = try XCTUnwrap(interruption(error))
        XCTAssertEqual(interruption.sceneID, Fixture.sceneID)
        XCTAssertEqual(interruption.phase, .launch)
        XCTAssertEqual(interruption.idempotencyKey, "process-\(Fixture.sceneID)")
        XCTAssertEqual(error?.apiError?.code, "insufficient_credits")
        XCTAssertEqual(error?.errorDescription?.hasSuffix("Scene ID: \(Fixture.sceneID)."), true)
    }

    func testPollingTimeoutKeepsSceneID() async throws {
        stubCreateAndUpload()
        MockURLProtocol.stub("\(Fixture.scenePath)/process", .json(200, Fixture.processAccepted))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.trainingScene))

        let error = await expectSplatError {
            try await self.makeClient(configuration: self.shortPolling).createAndProcess(videoURL: try self.makeVideo())
        }

        let interruption = try XCTUnwrap(interruption(error))
        XCTAssertEqual(interruption.sceneID, Fixture.sceneID)
        XCTAssertEqual(interruption.phase, .wait)
        guard case .timeout = interruption.underlying as? SplatError else {
            return XCTFail("Expected .timeout, got \(interruption.underlying)")
        }
    }

    func testProcessingFailureKeepsSceneID() async throws {
        stubCreateAndUpload()
        MockURLProtocol.stub("\(Fixture.scenePath)/process", .json(200, Fixture.processAccepted))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.sweptScene))

        let error = await expectSplatError { try await self.makeClient().createAndProcess(videoURL: try self.makeVideo()) }

        let interruption = try XCTUnwrap(interruption(error))
        XCTAssertEqual(interruption.phase, .wait)
        guard case .processingFailed(let message) = interruption.underlying as? SplatError else {
            return XCTFail("Expected .processingFailed, got \(interruption.underlying)")
        }
        XCTAssertEqual(message, "Processing timed out — the GPU job did not complete.")
    }
}
