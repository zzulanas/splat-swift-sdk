import XCTest
@testable import SplatKit

// MARK: - Operation tests
//
// One success and at least one error per public API operation, replaying the
// cited fixtures in APIFixtures.swift.

extension SplatClientTests {

    /// Run `operation`, expecting a ``SplatError``; fails the test otherwise.
    func expectSplatError<T>(
        _ operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> SplatError? {
        do {
            _ = try await operation()
            XCTFail("Expected a SplatError", file: file, line: line)
        } catch let error as SplatError {
            return error
        } catch {
            XCTFail("Expected a SplatError, got \(error)", file: file, line: line)
        }
        return nil
    }

    /// The JSON object sent as a request body.
    func jsonBody(_ request: URLRequest?) throws -> [String: Any] {
        let body = try XCTUnwrap(request?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: - createScene

    func testCreateSceneRejectsOutOfTierParameters() async throws {
        MockURLProtocol.stub("/v1/scenes", .json(422, Fixture.tierViolation))

        let error = await expectSplatError { try await self.makeClient().createScene(preset: .fast) }

        guard case .requestFailed(let apiError) = error else {
            return XCTFail("Expected .requestFailed, got \(String(describing: error))")
        }
        XCTAssertEqual(apiError.statusCode, 422)
        XCTAssertEqual(apiError.code, "invalid_input")
        XCTAssertTrue(apiError.message.contains("iterations=15000"))
    }

    // MARK: - getScene

    func testGetSceneDecodesSceneDetail() async throws {
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.completeScene))

        let scene = try await makeClient().getScene(id: Fixture.sceneID)

        XCTAssertEqual(scene.status, .complete)
        XCTAssertEqual(scene.numGaussians, 1_940_000)
        XCTAssertEqual(scene.format, .sog)
        XCTAssertEqual(scene.downloadURL?.absoluteString, "https://api.splat-3d.com/v1/scenes/a1b2c3d4e5f6/download")
        // PostgREST's microsecond timestamps decode (to millisecond precision).
        let whole = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z"))
        XCTAssertEqual(scene.createdAt.timeIntervalSince(whole), 0.123, accuracy: 0.001)
    }

    // MARK: - updateScene

    func testUpdateSceneSendsOnlySetFields() async throws {
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.updatedScene))

        let scene = try await makeClient().updateScene(
            id: Fixture.sceneID,
            SceneUpdate(title: "Kitchen", isPublic: true)
        )

        XCTAssertEqual(scene.title, "Kitchen")
        XCTAssertTrue(scene.isPublic)
        XCTAssertEqual(scene.status, .complete)
        XCTAssertNotNil(scene.thumbnailURL)
        // PATCH answers in the public shape GET serves, URLs included.
        XCTAssertEqual(scene.viewerURL?.absoluteString, "https://splat-3d.com/tour/a1b2c3d4e5f6")
        XCTAssertEqual(scene.downloadURL?.absoluteString, "https://api.splat-3d.com/v1/scenes/a1b2c3d4e5f6/download")
        XCTAssertEqual(scene.format, .sog)

        let request = MockURLProtocol.requests(to: Fixture.scenePath).first
        XCTAssertEqual(request?.httpMethod, "PATCH")
        let body = try jsonBody(request)
        XCTAssertEqual(body["title"] as? String, "Kitchen")
        XCTAssertEqual(body["is_public"] as? Bool, true)
        XCTAssertEqual(Set(body.keys), ["title", "is_public"])
    }

    func testUpdateSceneWithNoFieldsIsRejected() async throws {
        MockURLProtocol.stub(Fixture.scenePath, .json(400, Fixture.nothingToUpdate))

        let error = await expectSplatError { try await self.makeClient().updateScene(id: Fixture.sceneID, SceneUpdate()) }

        XCTAssertEqual(error?.apiError?.statusCode, 400)
        XCTAssertEqual(error?.apiError?.code, "invalid_input")
        XCTAssertEqual(error?.apiError?.message, "No valid fields to update.")
    }

    // MARK: - deleteScene

    func testDeleteSceneOwnedByAnotherUserIsForbidden() async throws {
        MockURLProtocol.stub(Fixture.scenePath, .json(403, Fixture.forbidden))

        let error = await expectSplatError { try await self.makeClient().deleteScene(id: Fixture.sceneID) }

        guard case .requestFailed(let apiError) = error else {
            return XCTFail("Expected .requestFailed, got \(String(describing: error))")
        }
        XCTAssertEqual(apiError.statusCode, 403)
        XCTAssertEqual(apiError.code, "forbidden")
    }

    // MARK: - processScene

    func testProcessSceneConflictIsSurfaced() async throws {
        MockURLProtocol.stub("\(Fixture.scenePath)/process", .json(409, Fixture.launchConflict))

        let error = await expectSplatError { try await self.makeClient().processScene(id: Fixture.sceneID) }

        XCTAssertEqual(error?.apiError?.statusCode, 409)
        XCTAssertEqual(error?.apiError?.code, "conflict")
    }

    func testProcessSceneWithoutCreditsIsSurfaced() async throws {
        MockURLProtocol.stub("\(Fixture.scenePath)/process", .json(402, Fixture.insufficientCredits))

        let error = await expectSplatError { try await self.makeClient().processScene(id: Fixture.sceneID) }

        XCTAssertEqual(error?.apiError?.statusCode, 402)
        XCTAssertEqual(error?.apiError?.code, "insufficient_credits")
        XCTAssertEqual(error?.errorDescription?.hasPrefix("Request failed (402)"), true)
    }

    func testProcessSceneReturnsSceneAfterLaunch() async throws {
        MockURLProtocol.stub("\(Fixture.scenePath)/process", .json(200, Fixture.processAccepted))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.completeScene))

        let scene = try await makeClient().processScene(id: Fixture.sceneID)

        XCTAssertEqual(scene.id, Fixture.sceneID)
        XCTAssertEqual(MockURLProtocol.requests(to: "\(Fixture.scenePath)/process").first?.httpMethod, "POST")
    }

    // MARK: - retrainScene

    func testRetrainSceneReturnsNewSceneID() async throws {
        MockURLProtocol.stub("\(Fixture.scenePath)/retrain", .json(200, Fixture.retrainAccepted))

        let newID = try await makeClient().retrainScene(id: Fixture.sceneID, preset: .quality)

        XCTAssertEqual(newID, "0f1e2d3c4b5a")
        let request = MockURLProtocol.requests(to: "\(Fixture.scenePath)/retrain").first
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(try jsonBody(request)["quality_tier"] as? String, "pro")
    }

    func testRetrainSceneMapsPresetsToBillingTiers() async throws {
        MockURLProtocol.stub("\(Fixture.scenePath)/retrain", .json(200, Fixture.retrainAccepted))
        let expected: [(ScenePreset, String)] = [
            (.fast, "fast"),
            (.standard, "standard"),
            (.quality, "pro"),
            (.ultra, "ultra"),
        ]

        for (preset, _) in expected {
            _ = try await makeClient().retrainScene(id: Fixture.sceneID, preset: preset)
        }

        let tiers = try MockURLProtocol.requests(to: "\(Fixture.scenePath)/retrain").compactMap {
            try jsonBody($0)["quality_tier"] as? String
        }
        XCTAssertEqual(tiers, expected.map(\.1))
    }

    func testRetrainUploadingSceneConflicts() async throws {
        MockURLProtocol.stub("\(Fixture.scenePath)/retrain", .json(409, Fixture.retrainConflict))

        let error = await expectSplatError { try await self.makeClient().retrainScene(id: Fixture.sceneID, preset: .ultra) }

        XCTAssertEqual(error?.apiError?.code, "conflict")
        XCTAssertEqual(error?.apiError?.message, "Cannot retrain a scene that is still uploading.")
    }

    // MARK: - cancelScene

    func testCancelSceneSucceeds() async throws {
        MockURLProtocol.stub("\(Fixture.scenePath)/cancel", .json(200, Fixture.cancelAccepted))

        try await makeClient().cancelScene(id: Fixture.sceneID)

        XCTAssertEqual(MockURLProtocol.requests(to: "\(Fixture.scenePath)/cancel").first?.httpMethod, "POST")
    }

    func testCancelFinishedSceneConflicts() async throws {
        MockURLProtocol.stub("\(Fixture.scenePath)/cancel", .json(409, Fixture.cancelConflict))

        let error = await expectSplatError { try await self.makeClient().cancelScene(id: Fixture.sceneID) }

        guard case .requestFailed(let apiError) = error else {
            return XCTFail("Expected .requestFailed, got \(String(describing: error))")
        }
        XCTAssertEqual(apiError.statusCode, 409)
        XCTAssertEqual(apiError.message, "Cannot cancel scene in 'complete' state.")
    }

    // MARK: - downloadScene

    func testDownloadSceneWritesModelToFile() async throws {
        let model = Data("model-bytes".utf8)
        MockURLProtocol.stub("\(Fixture.scenePath)/download", MockURLProtocol.Stub(
            statusCode: 200,
            body: model,
            // Headers set by the download route in api/src/routes/scenes.ts.
            headers: ["Content-Type": "application/octet-stream", "X-Splat-Format": "ply"]
        ))

        let file = try await makeClient().downloadScene(id: Fixture.sceneID, format: .ply)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(file.pathExtension, "ply")
        XCTAssertEqual(try Data(contentsOf: file), model)
        let request = MockURLProtocol.requests(to: "\(Fixture.scenePath)/download").first
        XCTAssertEqual(request?.url?.query, "format=ply")
    }

    func testDownloadSceneReportsServedFormat() async throws {
        // Asking for PLY when only SOG exists: the API serves SOG instead.
        MockURLProtocol.stub("\(Fixture.scenePath)/download", MockURLProtocol.Stub(
            statusCode: 200,
            body: Data("sog".utf8),
            headers: ["Content-Type": "application/octet-stream", "X-Splat-Format": "sog"]
        ))

        let file = try await makeClient().downloadScene(id: Fixture.sceneID, format: .ply)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(file.pathExtension, "sog")
    }

    func testDownloadSceneWithoutModelIsNotFound() async throws {
        MockURLProtocol.stub("\(Fixture.scenePath)/download", .json(404, Fixture.noModel))

        let error = await expectSplatError { try await self.makeClient().downloadScene(id: Fixture.sceneID) }

        guard case .notFound(let apiError) = error else {
            return XCTFail("Expected .notFound, got \(String(describing: error))")
        }
        XCTAssertEqual(apiError.message, "No model file available for this scene.")
        XCTAssertEqual(apiError.requestID, Fixture.requestID)
    }

    // MARK: - getSceneThumbnail

    func testGetSceneThumbnailReturnsImageBytes() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        MockURLProtocol.stub("\(Fixture.scenePath)/thumbnail", MockURLProtocol.Stub(
            statusCode: 200,
            body: png,
            // thumbnailContentType in api/src/lib/scenes.ts serves PNG keys as image/png.
            headers: ["Content-Type": "image/png"]
        ))

        let data = try await makeClient().getSceneThumbnail(id: Fixture.sceneID)

        XCTAssertEqual(data, png)
    }

    func testGetSceneThumbnailMissingIsNotFound() async throws {
        MockURLProtocol.stub("\(Fixture.scenePath)/thumbnail", .json(404, Fixture.noThumbnail))

        let error = await expectSplatError { try await self.makeClient().getSceneThumbnail(id: Fixture.sceneID) }

        guard case .notFound(let apiError) = error else {
            return XCTFail("Expected .notFound, got \(String(describing: error))")
        }
        XCTAssertEqual(apiError.message, "Thumbnail not found.")
    }

    // MARK: - getUsage

    func testGetUsageDecodesUsageAndLimits() async throws {
        MockURLProtocol.stub("/v1/usage", .json(200, Fixture.usage))

        let usage = try await makeClient().getUsage()

        XCTAssertEqual(usage.period, "2026-04")
        XCTAssertEqual(usage.scenesCreated, 3)
        XCTAssertEqual(usage.scenesProcessed, 2)
        XCTAssertEqual(usage.gpuSecondsUsed, 450)
        XCTAssertEqual(usage.storageBytes, 1_073_741_824)
        XCTAssertEqual(usage.limits.scenesCreated, 100)
        XCTAssertEqual(usage.limits.gpuSeconds, 36_000)
        XCTAssertEqual(usage.limits.storageBytes, 53_687_091_200)
    }

    func testGetUsageUnlimitedPlanHasNilLimits() async throws {
        MockURLProtocol.stub("/v1/usage", .json(200, Fixture.unlimitedUsage))

        let usage = try await makeClient().getUsage()

        XCTAssertNil(usage.limits.scenesCreated)
        XCTAssertNil(usage.limits.scenesProcessed)
        XCTAssertEqual(usage.limits.storageBytes, 1_099_511_627_776)
    }

    func testGetUsageWithoutKeyIsUnauthorized() async throws {
        MockURLProtocol.stub("/v1/usage", .json(401, Fixture.unauthorized))

        let error = await expectSplatError { try await self.makeClient().getUsage() }

        guard case .unauthorized(let apiError) = error else {
            return XCTFail("Expected .unauthorized, got \(String(describing: error))")
        }
        XCTAssertEqual(apiError.requestID, Fixture.requestID)
    }
}

// MARK: - Process payload limits
//
// The process route accepts 5–1,000 ARKit poses and up to 50,000 LiDAR points
// (processSceneBodySchema in api/src/routes/schemas.ts); anything outside is a
// 400 for the whole launch, after the source is already uploaded.

extension SplatClientTests {

    /// A pose like SplatScanner records: sequential frame names, 10 per second.
    func makePose(_ index: Int) -> ARKitPose {
        ARKitPose(
            timestamp: Double(index) / 10,
            filePath: String(format: "frame_%06d.jpg", index),
            transform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            intrinsics: [1440, 0, 960, 0, 1440, 720, 0, 0, 1],
            width: 1920,
            height: 1440
        )
    }

    /// Launch with `poses` and `points`, returning the JSON body sent.
    func launchBody(poses: [ARKitPose]? = nil, points: [[Float]]? = nil) async throws -> [String: Any] {
        MockURLProtocol.stub("\(Fixture.scenePath)/process", .json(200, Fixture.processAccepted))
        MockURLProtocol.stub(Fixture.scenePath, .json(200, Fixture.completeScene))

        _ = try await makeClient().processScene(id: Fixture.sceneID, arkitPoses: poses, lidarPoints: points)

        return try jsonBody(MockURLProtocol.requests(to: "\(Fixture.scenePath)/process").first)
    }

    func testLongCaptureIsThinnedToThePoseLimit() async throws {
        // A 150-second scan at SplatScanner's ~10 poses per second.
        let body = try await launchBody(poses: (0..<1500).map(makePose))

        let names = (body["arkit_poses"] as? [[String: Any]])?.compactMap { $0["file_path"] as? String }
        XCTAssertEqual(names?.count, 1000)
        // Evenly spaced like the pipeline's own thinning: index int(i × 1.5).
        XCTAssertEqual(names?.prefix(3), ["frame_000000.jpg", "frame_000001.jpg", "frame_000003.jpg"])
        XCTAssertEqual(names?.last, "frame_001498.jpg")
    }

    func testTooFewPosesAreNotSent() async throws {
        let body = try await launchBody(poses: (0..<4).map(makePose))

        XCTAssertNil(body["arkit_poses"])
    }

    func testLidarPointsAreThinnedToTheLimit() async throws {
        let points = (0..<60_000).map { [Float($0), 0, 0] }

        let body = try await launchBody(points: points)

        XCTAssertEqual((body["lidar_points"] as? [[Double]])?.count, 50_000)
    }
}

// MARK: - Model formats

extension SplatClientTests {

    func testDownloadKeepsAFormatThisSDKDoesntName() async throws {
        // If the API serves a format added after this release, the file must
        // say what it is rather than borrow the requested extension.
        MockURLProtocol.stub("\(Fixture.scenePath)/download", MockURLProtocol.Stub(
            statusCode: 200,
            body: Data("spz".utf8),
            headers: ["Content-Type": "application/octet-stream", "X-Splat-Format": "spz"]
        ))

        let file = try await makeClient().downloadScene(id: Fixture.sceneID)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(file.pathExtension, "spz")
    }
}
