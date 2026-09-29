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
        // Seen twice, one interval apart, before it counts (see the web launch test).
        XCTAssertEqual(MockURLProtocol.requests(to: Fixture.scenePath).count, 2)
        XCTAssertEqual(clock.sleeps, [10])
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
        let seen = Recorder<String>()

        let scene = try await makeClient(configuration: patientPolling).waitForScene(id: "walk") { status, _ in
            seen.record(status.rawValue)
        }

        XCTAssertEqual(scene.status, .complete)
        let values = await seen.values
        XCTAssertEqual(values, stages + ["complete"])
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

    /// createAndProcess with an ultra preset and LiDAR, as SplatCapture
    /// sends it: the launch body carries enable_lod and lidar_points.
    private func interruptedUltraLaunch(_ client: SplatClient) async throws -> SplatError.Interruption {
        let error = await expectSplatError {
            try await client.createAndProcess(
                videoURL: try self.makeVideo(),
                preset: .ultra,
                arkitPoses: (0..<6).map(self.makePose),
                lidarPoints: [[0, 0, 0], [1, 1, 1]]
            )
        }
        let interruption = try XCTUnwrap(interruption(error))
        XCTAssertEqual(interruption.phase, .launch)
        return interruption
    }

    func testResumeRepeatsTheExactLaunch() async throws {
        // The launch POST dropped before the API claimed it, so the scene is
        // still uploading: resume launches it, with the identical request.
        stubCreateAndUpload()
        MockURLProtocol.stub(processPath, .failure(.networkConnectionLost), .json(200, Fixture.processAccepted))
        MockURLProtocol.stub(
            Fixture.scenePath,
            .json(200, Fixture.uploadingScene),
            .json(200, Fixture.uploadingScene),
            .json(200, Fixture.completeScene)
        )
        let client = makeClient(configuration: patientPolling)

        let interruption = try await interruptedUltraLaunch(client)
        let scene = try await client.resume(interruption)

        XCTAssertEqual(scene.status, .complete)
        let launches = MockURLProtocol.requests(to: processPath)
        XCTAssertEqual(launches.count, 2)
        XCTAssertEqual(Set(launches.map { $0.value(forHTTPHeaderField: "Idempotency-Key") }), ["process-\(Fixture.sceneID)"])
        XCTAssertEqual(launches.first?.httpBody, launches.last?.httpBody)
        let body = try jsonBody(launches.last)
        XCTAssertEqual(body["enable_lod"] as? Bool, true)
        XCTAssertEqual((body["lidar_points"] as? [[Double]])?.count, 2)
    }

    func testResumeWaitsForASceneLaunchedElsewhere() async throws {
        // The web app launched the scene and kept no launch the API could
        // replay, so resume's launch gets a 409. The scene is running: wait.
        stubCreateAndUpload()
        MockURLProtocol.stub(processPath, .failure(.networkConnectionLost), .json(409, Fixture.alreadyProcessing))
        MockURLProtocol.stub(
            Fixture.scenePath,
            .json(500, Fixture.internalError),
            .json(200, Fixture.trainingScene),
            .json(200, Fixture.completeScene)
        )
        let client = makeClient(configuration: patientPolling)

        let interruption = try await interruptedUltraLaunch(client)
        let scene = try await client.resume(interruption)

        XCTAssertEqual(scene.status, .complete)
        XCTAssertEqual(MockURLProtocol.requests(to: processPath).count, 2)
    }

    /// createAndProcess, stopped by a lost upload response.
    private func interruptedUpload(_ client: SplatClient) async throws -> SplatError.Interruption {
        let error = await expectSplatError { try await client.createAndProcess(videoURL: try self.makeVideo()) }
        let interruption = try XCTUnwrap(interruption(error))
        XCTAssertEqual(interruption.phase, .upload)
        return interruption
    }

    func testResumeLaunchesBeforeUploadingAgain() async throws {
        // The upload landed but its response was lost. Launching is free to
        // try, since the API checks the source before charging, so the file
        // isn't sent twice.
        MockURLProtocol.stub("/v1/scenes", .json(201, Fixture.createScene))
        MockURLProtocol.stub("/upload", .failure(.networkConnectionLost))
        MockURLProtocol.stub(processPath, .json(200, Fixture.processAccepted))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.trainingScene), .json(200, Fixture.completeScene))
        let client = makeClient(configuration: patientPolling)

        let interruption = try await interruptedUpload(client)
        let scene = try await client.resume(interruption)

        XCTAssertEqual(scene.status, .complete)
        XCTAssertEqual(MockURLProtocol.requests(to: "/upload").count, 1)
        XCTAssertEqual(MockURLProtocol.requests(to: processPath).count, 1)
    }

    func testResumeUploadsAgainWhenTheSourceIsMissing() async throws {
        // The upload never landed: the launch says so, before charging, and
        // resume sends the file to the same presigned URL, then launches.
        MockURLProtocol.stub("/v1/scenes", .json(201, Fixture.createScene))
        MockURLProtocol.stub(
            "/upload",
            .failure(.networkConnectionLost),
            MockURLProtocol.Stub(statusCode: 200, body: Data(), headers: [:])
        )
        MockURLProtocol.stub(processPath, .json(400, Fixture.sourceMissing), .json(200, Fixture.processAccepted))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.uploadingScene), .json(200, Fixture.completeScene))
        let client = makeClient(configuration: patientPolling)

        let interruption = try await interruptedUpload(client)
        let scene = try await client.resume(interruption)

        XCTAssertEqual(scene.status, .complete)
        XCTAssertEqual(MockURLProtocol.requests(to: "/upload").count, 2)
        XCTAssertEqual(MockURLProtocol.requests(to: processPath).count, 2)
        // Same scene, same presigned URL: no second scene creation.
        XCTAssertEqual(MockURLProtocol.requests(to: "/v1/scenes").count, 1)
    }

    func testResumeUploadsAgainOnTheMissingSourceCode() async throws {
        // The same recovery, with the code gaussian-splatting #323 gives it.
        MockURLProtocol.stub("/v1/scenes", .json(201, Fixture.createScene))
        MockURLProtocol.stub(
            "/upload",
            .failure(.networkConnectionLost),
            MockURLProtocol.Stub(statusCode: 200, body: Data(), headers: [:])
        )
        MockURLProtocol.stub(processPath, .json(400, Fixture.sourceMissingCoded), .json(200, Fixture.processAccepted))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.uploadingScene), .json(200, Fixture.completeScene))
        let client = makeClient(configuration: patientPolling)

        let interruption = try await interruptedUpload(client)
        let scene = try await client.resume(interruption)

        XCTAssertEqual(scene.status, .complete)
        XCTAssertEqual(MockURLProtocol.requests(to: "/upload").count, 2)
    }

    func testTheMissingSourceCodeIsEnough() {
        // Matched on the code first, so a reworded message still counts.
        let refusal = SplatError.APIError(statusCode: 400, code: "source_missing", message: "Upload the source first.")

        XCTAssertTrue(SplatError.requestFailed(refusal).isMissingSource)
    }

    func testTheMissingSourceMessageCountsWithoutTheCode() {
        // Servers without #323 send it as invalid_input, like other 400s.
        let missing = SplatError.APIError(
            statusCode: 400,
            code: "invalid_input",
            message: "Source file not found. Please try uploading again."
        )
        let duplicate = SplatError.APIError(
            statusCode: 400,
            code: "invalid_input",
            message: "Duplicate file_path values in arkit_poses."
        )

        XCTAssertTrue(SplatError.requestFailed(missing).isMissingSource)
        XCTAssertFalse(SplatError.requestFailed(duplicate).isMissingSource)
    }

    func testAMissingSourceRightAfterTheUploadIsFinal() async throws {
        // The upload was accepted, yet the launch finds no source. Sending
        // the same file again would meet the same answer on every resume.
        stubCreateAndUpload()
        MockURLProtocol.stub(processPath, .json(400, Fixture.sourceMissing))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.uploadingScene))

        let error = await expectSplatError { try await self.makeClient().createAndProcess(videoURL: try self.makeVideo()) }

        guard case .requestFailed(let refusal) = error else {
            return XCTFail("Expected the launch's refusal, got \(String(describing: error))")
        }
        XCTAssertEqual(refusal.statusCode, 400)
        XCTAssertEqual(MockURLProtocol.requests(to: "/upload").count, 1)
    }

    func testAnExpiredUploadURLIsFinal() async throws {
        // The upload never landed, and its presigned URL expired (after an
        // hour) before resume ran: no resume can upload to this scene.
        MockURLProtocol.stub("/v1/scenes", .json(201, Fixture.createScene))
        MockURLProtocol.stub(
            "/upload",
            .failure(.networkConnectionLost),
            MockURLProtocol.Stub(statusCode: 403, body: Data(), headers: [:])
        )
        MockURLProtocol.stub(processPath, .json(400, Fixture.sourceMissing))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.uploadingScene))
        let client = makeClient(configuration: patientPolling)

        let interruption = try await interruptedUpload(client)
        let error = await expectSplatError { try await client.resume(interruption) }

        guard case .requestFailed(let refusal) = error else {
            return XCTFail("Expected the storage's refusal, got \(String(describing: error))")
        }
        XCTAssertEqual(refusal.statusCode, 403)
    }

    func testResumeReportsASettledOutcome() async throws {
        // The job failed while nobody was waiting: nothing to continue.
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.sweptScene))
        let interruption = SplatError.Interruption(
            sceneID: Fixture.sceneID,
            phase: .wait,
            idempotencyKey: "process-\(Fixture.sceneID)",
            underlying: SplatError.timeout
        )

        let error = await expectSplatError { try await self.makeClient().resume(interruption) }

        guard case .processingFailed = error else {
            return XCTFail("Expected .processingFailed, got \(String(describing: error))")
        }
    }

    func testResumeCannotLaunchWithoutTheOriginalRequest() async throws {
        // An interruption built by hand has no body to repeat, so resume
        // won't guess one and risk a different launch.
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.uploadingScene))
        let interruption = SplatError.Interruption(
            sceneID: Fixture.sceneID,
            phase: .launch,
            idempotencyKey: "process-\(Fixture.sceneID)",
            underlying: URLError(.networkConnectionLost)
        )

        let error = await expectSplatError { try await self.makeClient().resume(interruption) }

        guard case .notStarted = error else {
            return XCTFail("Expected .notStarted, got \(String(describing: error))")
        }
        XCTAssertTrue(MockURLProtocol.requests(to: processPath).isEmpty)
    }

    func testAFailedResumeCanBeResumed() async throws {
        // Offline throughout: resume waits out the outage like any wait, and
        // at its deadline stops with an interruption to resume later.
        MockURLProtocol.stub(Fixture.scenePath, .failure(.notConnectedToInternet))
        let interruption = SplatError.Interruption(
            sceneID: Fixture.sceneID,
            phase: .wait,
            idempotencyKey: "process-\(Fixture.sceneID)",
            underlying: SplatError.timeout
        )
        var configuration = SplatClient.Configuration()
        configuration.pollingTimeout = 60

        let error = await expectSplatError { try await self.makeClient(configuration: configuration).resume(interruption) }

        let again = try XCTUnwrap(self.interruption(error))
        XCTAssertEqual(again.phase, .wait)
        guard case .timeout = again.underlying as? SplatError else {
            return XCTFail("Expected .timeout, got \(again.underlying)")
        }
    }

    // MARK: - After an app restart

    func testResumeAfterARestartSendsTheSameLaunch() async throws {
        // The app was killed before the launch went through, keeping only the
        // scene ID and its capture. Resuming rebuilds the launch
        // createAndProcess sent, LOD and LiDAR included, under the same key.
        stubCreateAndUpload()
        MockURLProtocol.stub(processPath, .failure(.networkConnectionLost), .json(200, Fixture.processAccepted))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.uploadingScene), .json(200, Fixture.completeScene))
        let client = makeClient(configuration: patientPolling)

        _ = try await interruptedUltraLaunch(client)
        let scene = try await client.resume(
            sceneID: Fixture.sceneID,
            preset: .ultra,
            arkitPoses: (0..<6).map(makePose),
            lidarPoints: [[0, 0, 0], [1, 1, 1]]
        )

        XCTAssertEqual(scene.status, .complete)
        let launches = MockURLProtocol.requests(to: processPath)
        XCTAssertEqual(launches.count, 2)
        XCTAssertEqual(Set(launches.map { $0.value(forHTTPHeaderField: "Idempotency-Key") }), ["process-\(Fixture.sceneID)"])
        XCTAssertEqual(launches.first?.httpBody, launches.last?.httpBody)
    }

    func testResumeAfterARestartCannotUploadAgain() async throws {
        // Killed before the upload finished. The upload URL wasn't kept, so
        // the launch's refusal (no source, before any charge) is final.
        MockURLProtocol.stub(processPath, .json(400, Fixture.sourceMissing))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.uploadingScene))

        let error = await expectSplatError {
            try await self.makeClient().resume(sceneID: Fixture.sceneID, preset: .standard, arkitPoses: nil, lidarPoints: nil)
        }

        guard case .requestFailed(let refusal) = error else {
            return XCTFail("Expected the launch's refusal, got \(String(describing: error))")
        }
        XCTAssertEqual(refusal.statusCode, 400)
        XCTAssertTrue(MockURLProtocol.requests(to: "/upload").isEmpty)
    }

    // MARK: - Scene ID before the charge

    func testSceneIDArrivesBeforeTheUpload() async throws {
        // An app killed mid-wait needs the ID it saved when the scene appeared.
        stubCreateAndUpload()
        MockURLProtocol.stub(processPath, .json(200, Fixture.processAccepted))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.completeScene))
        let created = Recorder<String>()
        let uploadsWhenCreated = Recorder<Int>()

        _ = try await makeClient().createAndProcess(videoURL: try makeVideo(), onSceneCreated: { id in
            created.record(id)
            uploadsWhenCreated.record(MockURLProtocol.requests(to: "/upload").count)
        })

        let ids = await created.values
        let uploads = await uploadsWhenCreated.values
        XCTAssertEqual(ids, [Fixture.sceneID])
        XCTAssertEqual(uploads, [0])
    }

    func testALaunchTheAPIFailedIsNotRetried() async throws {
        // A replayed upstream_error is the same stored failure every time.
        let clock = FakeClock()
        MockURLProtocol.stub(processPath, .json(502, Fixture.launchRejected))

        _ = await expectSplatError { try await self.makeClient(clock: clock).processScene(id: Fixture.sceneID) }

        XCTAssertEqual(MockURLProtocol.requests(to: processPath).count, 1)
        XCTAssertEqual(clock.sleeps, [])
    }

    // MARK: - Waiting through server blips

    func testWaitRidesOutKeyAndLookupBlipsOnceTheSceneIsSeen() async throws {
        // A database blip makes the API answer 401 (its key lookup failed) or
        // 404 (its scene query failed) for a scene it served a moment ago.
        let clock = FakeClock()
        MockURLProtocol.stub(
            Fixture.scenePath,
            .json(200, Fixture.trainingScene),
            .json(401, Fixture.keyLookupFailed),
            .json(404, Fixture.sceneNotFound),
            .json(200, Fixture.completeScene)
        )

        let scene = try await makeClient(clock: clock).waitForScene(id: Fixture.sceneID)

        XCTAssertEqual(scene.status, .complete)
        XCTAssertEqual(clock.sleeps, [10, 10, 10])
    }

    func testWaitGivesUpOnARejectionThatPersists() async throws {
        let clock = FakeClock()
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.trainingScene), .json(404, Fixture.sceneNotFound))

        let error = await expectSplatError { try await self.makeClient(clock: clock).waitForScene(id: Fixture.sceneID) }

        guard case .notFound = error else {
            return XCTFail("Expected .notFound, got \(String(describing: error))")
        }
        // Tolerated for five minutes after the scene was last read.
        XCTAssertEqual(clock.sleeps.reduce(0, +), 5 * 60)
    }

    func testLongPollingIntervalsStillTolerateAFewRejections() async throws {
        // Polling every 10 minutes, one poll outlasts the window: the first
        // few rejections are still taken as blips.
        var configuration = SplatClient.Configuration()
        configuration.pollingInterval = 10 * 60
        MockURLProtocol.stub(
            Fixture.scenePath,
            .json(200, Fixture.trainingScene),
            .json(404, Fixture.sceneNotFound),
            .json(404, Fixture.sceneNotFound),
            .json(200, Fixture.completeScene)
        )

        let scene = try await makeClient(configuration: configuration).waitForScene(id: Fixture.sceneID)

        XCTAssertEqual(scene.status, .complete)
    }

    func testRejectionsAreToleratedForAWindowNotAPollCount() async throws {
        // Polling every 2 seconds, three rejections take 6: far shorter than
        // a database incident.
        var configuration = SplatClient.Configuration()
        configuration.pollingInterval = 2
        let outage: [MockURLProtocol.Stub] = Array(repeating: .json(404, Fixture.sceneNotFound), count: 60)
        MockURLProtocol.stubSequences[Fixture.scenePath] = [.json(200, Fixture.trainingScene)]
            + outage
            + [.json(200, Fixture.completeScene)]

        let scene = try await makeClient(configuration: configuration).waitForScene(id: Fixture.sceneID)

        XCTAssertEqual(scene.status, .complete)
    }

    func testUploadingMustLastBeforeNotStarted() async throws {
        // The web app charges and dispatches a moment before it marks a
        // scene launched (web/src/lib/scenes.ts), so one sighting isn't proof.
        let clock = FakeClock()
        MockURLProtocol.stub(
            Fixture.scenePath,
            .json(200, Fixture.uploadingScene),
            .json(200, Fixture.trainingScene),
            .json(200, Fixture.completeScene)
        )

        let scene = try await makeClient(clock: clock).waitForScene(id: Fixture.sceneID)

        XCTAssertEqual(scene.status, .complete)
    }

    // MARK: - Deadline

    func testTimeoutLooksOnceMoreAfterTheDeadline() async throws {
        // The device slept through the deadline; the job finished meanwhile.
        let clock = FakeClock()
        clock.advanceOnNextSleep(by: 4 * 60 * 60)
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.trainingScene), .json(200, Fixture.completeScene))

        let scene = try await makeClient(clock: clock).waitForScene(id: Fixture.sceneID)

        XCTAssertEqual(scene.status, .complete)
    }

    func testTheLastLookRidesOutOneFailedRead() async throws {
        // A device waking after the deadline often fails its first request,
        // before the radio is back.
        let clock = FakeClock()
        clock.advanceOnNextSleep(by: 4 * 60 * 60)
        MockURLProtocol.stub(
            Fixture.scenePath,
            .json(200, Fixture.trainingScene),
            .failure(.networkConnectionLost),
            .json(200, Fixture.completeScene)
        )

        let scene = try await makeClient(clock: clock).waitForScene(id: Fixture.sceneID)

        XCTAssertEqual(scene.status, .complete)
    }

    func testTheLastLookGivesUpOnASecondFailedRead() async throws {
        let clock = FakeClock()
        clock.advanceOnNextSleep(by: 4 * 60 * 60)
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.trainingScene), .failure(.networkConnectionLost))

        let error = await expectSplatError { try await self.makeClient(clock: clock).waitForScene(id: Fixture.sceneID) }

        guard case .timeout = error else {
            return XCTFail("Expected .timeout, got \(String(describing: error))")
        }
        XCTAssertEqual(MockURLProtocol.requests(to: Fixture.scenePath).count, 3)
    }

    func testDeadlineShortensTheLastSleep() async throws {
        var configuration = SplatClient.Configuration()
        configuration.pollingInterval = 10
        configuration.pollingTimeout = 15
        let clock = FakeClock()
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.trainingScene))

        let error = await expectSplatError {
            try await self.makeClient(configuration: configuration, clock: clock).waitForScene(id: Fixture.sceneID)
        }

        guard case .timeout = error else {
            return XCTFail("Expected .timeout, got \(String(describing: error))")
        }
        XCTAssertEqual(clock.sleeps, [10, 5])
        XCTAssertEqual(MockURLProtocol.requests(to: Fixture.scenePath).count, 3)
    }

    func testPollsWaitOutFailuresAtThePollInterval() async throws {
        // No quick retries inside a poll: the interval and the deadline govern.
        let clock = FakeClock()
        MockURLProtocol.stub(
            Fixture.scenePath,
            MockURLProtocol.Stub(statusCode: 503, body: Data(), headers: [:]),
            .json(200, Fixture.completeScene)
        )

        _ = try await makeClient(clock: clock).waitForScene(id: Fixture.sceneID)

        XCTAssertEqual(clock.sleeps, [10])
    }

    // MARK: - Final outcomes

    func testALaunchTheAPIFailedIsFinal() async throws {
        // Modal rejected the launch, so the API refunded it and failed the
        // scene; repeating the launch only replays that error.
        stubCreateAndUpload()
        MockURLProtocol.stub(processPath, .json(502, Fixture.launchRejected))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.failedLaunchScene))

        let error = await expectSplatError { try await self.makeClient().createAndProcess(videoURL: try self.makeVideo()) }

        guard case .processingFailed(let message) = error else {
            return XCTFail("Expected .processingFailed, got \(String(describing: error))")
        }
        XCTAssertEqual(message, "Modal rejected the launch (401).")
        XCTAssertEqual(MockURLProtocol.requests(to: processPath).count, 1)
    }

    func testAStoredLaunchFailureIsFinalWhenTheSceneCantBeRead() async throws {
        // upstream_error is the API's stored verdict on this launch, final
        // even when the read that would confirm it fails.
        stubCreateAndUpload()
        MockURLProtocol.stub(processPath, .json(502, Fixture.launchRejected))
        MockURLProtocol.stub(Fixture.scenePath, .json(500, Fixture.internalError))

        let error = await expectSplatError { try await self.makeClient().createAndProcess(videoURL: try self.makeVideo()) }

        guard case .processingFailed(let message) = error else {
            return XCTFail("Expected .processingFailed, got \(String(describing: error))")
        }
        XCTAssertEqual(message, "Modal rejected the launch (401).")
    }

    func testAFailedSceneBehindALostLaunchIsFinal() async throws {
        // The API claimed the launch and failed it, but every response was
        // lost. The caller gets the scene's outcome, not a bare URLError
        // without a scene ID.
        stubCreateAndUpload()
        MockURLProtocol.stub(processPath, .failure(.networkConnectionLost))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.failedLaunchScene))

        let error = await expectSplatError { try await self.makeClient().createAndProcess(videoURL: try self.makeVideo()) }

        guard case .processingFailed(let message) = error else {
            return XCTFail("Expected .processingFailed, got \(String(describing: error))")
        }
        XCTAssertEqual(message, "Modal rejected the launch (401).")
    }

    func testACancelledSceneIsACancellationNotAConflict() async throws {
        // Cancelled while its video uploaded: the launch finds a scene that
        // is no longer uploading (409), but what happened is the cancel.
        stubCreateAndUpload()
        MockURLProtocol.stub(processPath, .json(409, Fixture.alreadyProcessing))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.cancelledScene))

        let error = await expectSplatError { try await self.makeClient().createAndProcess(videoURL: try self.makeVideo()) }

        guard case .cancelled = error else {
            return XCTFail("Expected .cancelled, got \(String(describing: error))")
        }
    }

    func testALostLaunchResponseKeepsWaiting() async throws {
        // The API claimed the launch but its response was lost. The scene is
        // processing, so the job runs and the wait goes on.
        stubCreateAndUpload()
        MockURLProtocol.stub(processPath, .failure(.networkConnectionLost))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.trainingScene), .json(200, Fixture.completeScene))

        let scene = try await makeClient().createAndProcess(videoURL: try makeVideo())

        XCTAssertEqual(scene.status, .complete)
    }

    func testALaunchRefusedForGoodIsFinal() async throws {
        // The API refuses this exact request (400) before charging, and
        // would refuse it again on every resume.
        stubCreateAndUpload()
        MockURLProtocol.stub(processPath, .json(400, Fixture.duplicatePosePaths))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.uploadingScene))

        let error = await expectSplatError { try await self.makeClient().createAndProcess(videoURL: try self.makeVideo()) }

        guard case .requestFailed(let refusal) = error else {
            return XCTFail("Expected the launch's refusal, got \(String(describing: error))")
        }
        XCTAssertEqual(refusal.statusCode, 400)
    }

    func testAStorageRefusalIsFinal() async throws {
        // The storage refused the presigned upload URL: no resume can upload
        // to this scene, so there is nothing to continue.
        MockURLProtocol.stub("/v1/scenes", .json(201, Fixture.createScene))
        MockURLProtocol.stub("/upload", MockURLProtocol.Stub(statusCode: 403, body: Data(), headers: [:]))

        let error = await expectSplatError { try await self.makeClient().createAndProcess(videoURL: try self.makeVideo()) }

        guard case .requestFailed(let refusal) = error else {
            return XCTFail("Expected the storage's refusal, got \(String(describing: error))")
        }
        XCTAssertEqual(refusal.statusCode, 403)
        XCTAssertTrue(MockURLProtocol.requests(to: processPath).isEmpty)
    }

    func testADeletedSceneEndsTheWait() async throws {
        // Deleted through the API while createAndProcess waited: the reads
        // 404 for good, and so does a replay of the launch, which processScene
        // answers with 404 only for a missing scene. Nothing is left to resume.
        stubCreateAndUpload()
        MockURLProtocol.stub(processPath, .json(200, Fixture.processAccepted), .json(404, Fixture.sceneNotFound))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.trainingScene), .json(404, Fixture.sceneNotFound))

        let error = await expectSplatError { try await self.makeClient().createAndProcess(videoURL: try self.makeVideo()) }

        guard case .notFound = error else {
            return XCTFail("Expected .notFound, got \(String(describing: error))")
        }
        XCTAssertEqual(MockURLProtocol.requests(to: processPath).count, 2)
    }

    func testAFailedReadWhileWaitingIsNotADeletion() async throws {
        // The API answers a failed scene read with 404 too
        // (getSceneStatus in api/src/lib/scenes.ts). The launch still
        // replays, so the scene exists and its paid job may be running.
        stubCreateAndUpload()
        MockURLProtocol.stub(processPath, .json(200, Fixture.processAccepted))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.trainingScene), .json(404, Fixture.sceneNotFound))

        let error = await expectSplatError { try await self.makeClient().createAndProcess(videoURL: try self.makeVideo()) }

        let interruption = try XCTUnwrap(interruption(error))
        XCTAssertEqual(interruption.phase, .wait)
        XCTAssertEqual(interruption.sceneID, Fixture.sceneID)
        guard case .notFound = interruption.underlying as? SplatError else {
            return XCTFail("Expected .notFound underneath, got \(interruption.underlying)")
        }
    }

    func testResumingADeletedSceneIsFinal() async throws {
        MockURLProtocol.stub(processPath, .json(404, Fixture.sceneNotFound))
        MockURLProtocol.stub(Fixture.scenePath, .json(404, Fixture.sceneNotFound))
        let interruption = SplatError.Interruption(
            sceneID: Fixture.sceneID,
            phase: .wait,
            idempotencyKey: "process-\(Fixture.sceneID)",
            underlying: SplatError.timeout,
            request: ResumableRequest(upload: nil, launch: ProcessSceneBody(enableLOD: false, arkitPoses: nil, lidarPoints: nil))
        )

        let error = await expectSplatError { try await self.makeClient().resume(interruption) }

        guard case .notFound = error else {
            return XCTFail("Expected .notFound, got \(String(describing: error))")
        }
    }

    func testADeletionWithoutALaunchToReplayStaysResumable() async throws {
        // Made with the public initializer, the interruption has no launch to
        // replay, so its 404s can't be told from failed reads.
        MockURLProtocol.stub(Fixture.scenePath, .json(404, Fixture.sceneNotFound))
        let interruption = SplatError.Interruption(
            sceneID: Fixture.sceneID,
            phase: .wait,
            idempotencyKey: "process-\(Fixture.sceneID)",
            underlying: SplatError.timeout
        )

        let error = await expectSplatError { try await self.makeClient().resume(interruption) }

        let again = try XCTUnwrap(self.interruption(error))
        XCTAssertEqual(again.phase, .wait)
        XCTAssertTrue(MockURLProtocol.requests(to: processPath).isEmpty)
    }

    func testASceneDeletedFromTheDashboardCannotBeLaunched() async throws {
        // The dashboard only marks a scene deleted: reads still serve it as
        // uploading, but processScene skips it and answers 404
        // (api/src/lib/scenes.ts; a failed query there is a 503, not a 404).
        stubCreateAndUpload()
        MockURLProtocol.stub(processPath, .json(404, Fixture.sceneNotFound))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.uploadingScene))

        let error = await expectSplatError { try await self.makeClient().createAndProcess(videoURL: try self.makeVideo()) }

        guard case .notFound = error else {
            return XCTFail("Expected .notFound, got \(String(describing: error))")
        }
    }

    func testAFailedJobIsFinal() async throws {
        stubCreateAndUpload()
        MockURLProtocol.stub(processPath, .json(200, Fixture.processAccepted))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.sweptScene))

        let error = await expectSplatError { try await self.makeClient().createAndProcess(videoURL: try self.makeVideo()) }

        guard case .processingFailed(let message) = error else {
            return XCTFail("Expected .processingFailed, got \(String(describing: error))")
        }
        XCTAssertEqual(message, "Processing timed out — the GPU job did not complete.")
    }

    // MARK: - Cancellation in flight

    /// Wait (in real time, briefly) until a request to `path` has been sent.
    private func waitForRequest(to path: String) async throws {
        for _ in 0..<200 where MockURLProtocol.requests(to: path).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(MockURLProtocol.requests(to: path).isEmpty, "no request to \(path)")
    }

    func testCancellingAReadInFlightThrowsCancellationError() async throws {
        MockURLProtocol.stub(Fixture.scenePath, .hang)
        let client = makeClient()
        let task = Task { try await client.getScene(id: Fixture.sceneID) }

        try await waitForRequest(to: Fixture.scenePath)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testCancellingABareUploadThrowsCancellationError() async throws {
        MockURLProtocol.stub("/upload", .hang)
        let client = makeClient()
        let video = try makeVideo()
        let target = try XCTUnwrap(URL(string: "https://r2.dev/upload?token=xyz"))
        let task = Task { try await client.uploadVideo(from: video, to: target) }

        try await waitForRequest(to: "/upload")
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testCancellingAnUploadInFlightIsACancellation() async throws {
        MockURLProtocol.stub("/v1/scenes", .json(201, Fixture.createScene))
        MockURLProtocol.stub("/upload", .hang)
        let client = makeClient()
        let video = try makeVideo()
        let task = Task { try await client.createAndProcess(videoURL: video) }

        try await waitForRequest(to: "/upload")
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected an interruption")
        } catch let error as SplatError {
            let interruption = try XCTUnwrap(interruption(error))
            XCTAssertTrue(interruption.underlying is CancellationError, "\(interruption.underlying)")
            XCTAssertEqual(interruption.phase, .upload)
        }
    }

    // MARK: - Logging an interruption

    func testAnInterruptionPrintsNeitherItsUploadURLNorItsCapture() async throws {
        // Apps log errors with "\(error)". The presigned upload URL can write
        // the scene's source for an hour, and a capture runs to megabytes.
        MockURLProtocol.stub("/v1/scenes", .json(201, Fixture.createScene))
        MockURLProtocol.stub("/upload", .failure(.networkConnectionLost))

        let error = await expectSplatError {
            try await self.makeClient().createAndProcess(
                videoURL: try self.makeVideo(),
                preset: .ultra,
                arkitPoses: (0..<1_000).map(self.makePose)
            )
        }
        let splatError = try XCTUnwrap(error)
        let interruption = try XCTUnwrap(interruption(error))
        var dumped = ""
        dump(splatError, to: &dumped)

        let printed = ["\(splatError)", String(reflecting: splatError), "\(interruption)", String(reflecting: interruption), dumped]
        for text in printed {
            let excerpt = String(text.prefix(300))
            XCTAssertFalse(text.contains("r2.dev/upload"), excerpt)
            XCTAssertFalse(text.contains("frame_"), excerpt)
            XCTAssertLessThan(text.count, 2_000, excerpt)
            XCTAssertTrue(text.contains(Fixture.sceneID), excerpt)
        }
    }

    // MARK: - The capture file

    /// A capture path with nothing at it.
    private func missingVideo() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("splatkit-missing-\(UUID().uuidString).mp4")
    }

    /// The `URLError` code inside `.uploadFailed`, or `nil`.
    private func uploadFailure(_ error: SplatError?) -> URLError.Code? {
        guard case .uploadFailed(let cause) = error else {
            return nil
        }
        return (cause as? URLError)?.code
    }

    func testAMissingCaptureIsNeverUploaded() async throws {
        // URLSession sends a missing file as an empty PUT, storage accepts
        // it, and the launch would be charged for an empty video. Checked
        // before the scene is created, so no monthly scene creation is spent.
        MockURLProtocol.stub("/v1/scenes", .json(201, Fixture.createScene))
        MockURLProtocol.stub("/upload", MockURLProtocol.Stub(statusCode: 200, body: Data(), headers: [:]))

        let error = await expectSplatError { try await self.makeClient().createAndProcess(videoURL: self.missingVideo()) }

        XCTAssertEqual(uploadFailure(error), .fileDoesNotExist, "\(String(describing: error))")
        XCTAssertTrue(MockURLProtocol.requests(to: "/v1/scenes").isEmpty)
        XCTAssertTrue(MockURLProtocol.requests(to: "/upload").isEmpty)
    }

    func testAnEmptyCaptureIsNeverUploaded() async throws {
        MockURLProtocol.stub("/v1/scenes", .json(201, Fixture.createScene))
        MockURLProtocol.stub("/upload", MockURLProtocol.Stub(statusCode: 200, body: Data(), headers: [:]))
        let empty = missingVideo()
        try Data().write(to: empty)
        addTeardownBlock { try? FileManager.default.removeItem(at: empty) }

        let error = await expectSplatError { try await self.makeClient().createAndProcess(videoURL: empty) }

        XCTAssertEqual(uploadFailure(error), .zeroByteResource, "\(String(describing: error))")
        XCTAssertTrue(MockURLProtocol.requests(to: "/upload").isEmpty)
    }

    func testResumeAfterTheCaptureIsGoneIsFinal() async throws {
        // The upload never landed, and the capture was deleted before resume
        // ran (SplatScanner records to a temporary file): nothing can send it.
        MockURLProtocol.stub("/v1/scenes", .json(201, Fixture.createScene))
        MockURLProtocol.stub(
            "/upload",
            .failure(.networkConnectionLost),
            MockURLProtocol.Stub(statusCode: 200, body: Data(), headers: [:])
        )
        MockURLProtocol.stub(processPath, .json(400, Fixture.sourceMissing), .json(200, Fixture.processAccepted))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.uploadingScene), .json(200, Fixture.completeScene))
        let client = makeClient(configuration: patientPolling)
        let video = try makeVideo()

        let error = await expectSplatError { try await client.createAndProcess(videoURL: video) }
        let stopped = try XCTUnwrap(interruption(error))
        try FileManager.default.removeItem(at: video)
        let resumed = await expectSplatError { try await client.resume(stopped) }

        XCTAssertEqual(uploadFailure(resumed), .fileDoesNotExist, "\(String(describing: resumed))")
        XCTAssertEqual(MockURLProtocol.requests(to: "/upload").count, 1)
        XCTAssertEqual(MockURLProtocol.requests(to: processPath).count, 1)
    }

    func testUploadVideoRefusesAMissingFile() async throws {
        MockURLProtocol.stub("/upload", MockURLProtocol.Stub(statusCode: 200, body: Data(), headers: [:]))
        let target = try XCTUnwrap(URL(string: "https://r2.dev/upload?token=xyz"))

        let error = await expectSplatError { try await self.makeClient().uploadVideo(from: self.missingVideo(), to: target) }

        XCTAssertEqual(uploadFailure(error), .fileDoesNotExist, "\(String(describing: error))")
        XCTAssertTrue(MockURLProtocol.requests(to: "/upload").isEmpty)
    }
}
