import XCTest
@testable import SplatKit

// MARK: - Resume tests
//
// The recovery contract: what a caller can do after a failure without paying
// for a second job. Each test is a path that reaches users in production.

extension SplatClientTests {

    private var processPath: String { "\(Fixture.scenePath)/process" }

    /// Polling at a 10-second interval with a deadline far away, and no
    /// per-request retries, so each poll is exactly one request.
    private var patientPolling: SplatClient.Configuration {
        var configuration = SplatClient.Configuration()
        configuration.pollingInterval = 10
        configuration.maxRetries = 0
        return configuration
    }

    // MARK: - Launch key

    func testDefaultLaunchKeyIsStablePerScene() async throws {
        // After an app restart, calling processScene again must replay the
        // launch (same key and body), not get a 409 for a new key.
        MockURLProtocol.stub(processPath, .json(200, Fixture.processAccepted))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.trainingScene))

        _ = try await makeClient().processScene(id: Fixture.sceneID)
        _ = try await makeClient().processScene(id: Fixture.sceneID)

        let keys = MockURLProtocol.requests(to: processPath).map { $0.value(forHTTPHeaderField: "Idempotency-Key") }
        XCTAssertEqual(keys, ["process-\(Fixture.sceneID)", "process-\(Fixture.sceneID)"])
    }

    func testAcceptedLaunchIsNotAnErrorWhenTheFollowUpFetchFails() async throws {
        // The launch is charged once the API accepts it; a failed read after
        // that must not look like a failed launch.
        MockURLProtocol.stub(processPath, .json(200, Fixture.processAccepted))
        MockURLProtocol.stub(Fixture.scenePath, .json(500, Fixture.internalError))

        _ = try await makeClient().processScene(id: Fixture.sceneID)
    }

    func testQuotaExhaustedLaunchIsNotRetried() async throws {
        // A used-up monthly quota doesn't change until next month.
        let clock = FakeClock()
        MockURLProtocol.stub(processPath, .json(429, Fixture.processQuotaExceeded))

        _ = await expectSplatError { try await self.makeClient(clock: clock).processScene(id: Fixture.sceneID) }

        XCTAssertEqual(MockURLProtocol.requests(to: processPath).count, 1)
        XCTAssertEqual(clock.sleeps, [])
    }

    // MARK: - Waiting

    func testWaitingOnANeverLaunchedSceneFailsFast() async throws {
        // Nothing moves a scene past uploading but a launch: there is no job,
        // so waiting 165 minutes for one would only end in a false timeout.
        let clock = FakeClock()
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.uploadingScene))

        let error = await expectSplatError { try await self.makeClient(clock: clock).waitForScene(id: Fixture.sceneID) }

        guard case .notStarted = error else {
            return XCTFail("Expected .notStarted, got \(String(describing: error))")
        }
        XCTAssertEqual(MockURLProtocol.requests(to: Fixture.scenePath).count, 1)
        XCTAssertEqual(clock.sleeps, [])
    }

    func testWaitingFollowsEveryInFlightStatus() async throws {
        // Every stage the pipeline writes keeps the wait going.
        let stages = Self.inFlightStatuses.filter { $0 != "uploading" }
        let path = "/v1/scenes/walk"
        let responses = (stages + ["complete"]).map { MockURLProtocol.Stub(
            statusCode: 200,
            body: scenePayload(id: "walk", status: $0),
            headers: ["Content-Type": "application/json"]
        ) }
        MockURLProtocol.stubSequences[path] = responses
        var seen: [String] = []

        let scene = try await makeClient(configuration: patientPolling).waitForScene(id: "walk") { status, _ in
            seen.append(status.rawValue)
        }

        XCTAssertEqual(scene.status, .complete)
        XCTAssertEqual(seen, stages + ["complete"])
    }

    func testPollingRidesOutOutages() async throws {
        let clock = FakeClock()
        MockURLProtocol.stub(
            Fixture.scenePath,
            .failure(.networkConnectionLost),
            .json(500, Fixture.internalError),
            MockURLProtocol.Stub(statusCode: 429, body: Data(), headers: ["Retry-After": "90"]),
            .json(200, Fixture.estimatingPosesScene),
            .json(200, Fixture.completeScene)
        )

        let scene = try await makeClient(configuration: patientPolling, clock: clock).waitForScene(id: Fixture.sceneID)

        XCTAssertEqual(scene.status, .complete)
        // Each outage waits the interval, or longer when the server asks.
        XCTAssertEqual(clock.sleeps, [10, 10, 90, 10])
    }

    func testPollingStopsOnClientErrors() async throws {
        MockURLProtocol.stub(Fixture.scenePath, .json(404, Fixture.sceneNotFound))

        let error = await expectSplatError {
            try await self.makeClient(configuration: self.patientPolling).waitForScene(id: Fixture.sceneID)
        }

        guard case .notFound = error else {
            return XCTFail("Expected .notFound, got \(String(describing: error))")
        }
        XCTAssertEqual(MockURLProtocol.requests(to: Fixture.scenePath).count, 1)
    }

    // MARK: - Cancellation

    func testCancellingDuringUploadIsACancellation() async throws {
        stubCreateAndUpload()

        let error = await expectSplatError {
            try await self.makeClient().createAndProcess(videoURL: try self.makeVideo()) { status, pct in
                // The user leaves just as the upload starts.
                if status == .uploading, pct == 0 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }

        let interruption = try XCTUnwrap(interruption(error))
        XCTAssertTrue(interruption.underlying is CancellationError, "\(interruption.underlying)")
        XCTAssertEqual(interruption.phase, .upload)
        XCTAssertEqual(error?.errorDescription, "Cancelled. Scene ID: \(Fixture.sceneID).")
    }

    func testCancellingWhileWaitingKeepsTheSceneID() async throws {
        // A SwiftUI .task cancelled mid-wait: the job is paid for and keeps
        // running, so the caller still learns which scene to come back to.
        let clock = FakeClock()
        stubCreateAndUpload()
        MockURLProtocol.stub(processPath, .json(200, Fixture.processAccepted))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.trainingScene))
        clock.cancelOnNextSleep()

        let error = await expectSplatError {
            try await self.makeClient(clock: clock).createAndProcess(videoURL: try self.makeVideo())
        }

        let interruption = try XCTUnwrap(interruption(error))
        XCTAssertTrue(interruption.underlying is CancellationError, "\(interruption.underlying)")
        XCTAssertEqual(interruption.phase, .wait)
        XCTAssertEqual(interruption.sceneID, Fixture.sceneID)
    }

    func testCancellingWaitForSceneThrowsCancellationError() async throws {
        let clock = FakeClock()
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.trainingScene))
        clock.cancelOnNextSleep()

        do {
            _ = try await makeClient(clock: clock).waitForScene(id: Fixture.sceneID)
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    // MARK: - Resuming

    func testInterruptedLaunchResumesWithOneCharge() async throws {
        // The launch outcome was unknown (a 503 the API asks to retry), so the
        // caller resumes: the same key replays or starts the launch, once.
        stubCreateAndUpload()
        MockURLProtocol.stub(
            processPath,
            .json(503, Fixture.launchUnconfirmed),
            .json(200, Fixture.processAccepted)
        )
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.completeScene))
        let client = makeClient(configuration: patientPolling)

        let error = await expectSplatError { try await client.createAndProcess(videoURL: try self.makeVideo()) }
        let interruption = try XCTUnwrap(interruption(error))
        XCTAssertEqual(interruption.phase, .launch)

        _ = try await client.processScene(id: interruption.sceneID, idempotencyKey: interruption.idempotencyKey)
        let scene = try await client.waitForScene(id: interruption.sceneID)

        XCTAssertEqual(scene.status, .complete)
        let launches = MockURLProtocol.requests(to: processPath)
        XCTAssertEqual(launches.map { $0.value(forHTTPHeaderField: "Idempotency-Key") }, [
            "process-\(Fixture.sceneID)",
            "process-\(Fixture.sceneID)",
        ])
        XCTAssertEqual(launches.first?.httpBody, launches.last?.httpBody)
    }
}
