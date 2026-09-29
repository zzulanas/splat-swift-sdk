import XCTest
@testable import SplatKit

// MARK: - Error envelope tests
//
// Failed responses expose the API's code, message, HTTP status, request ID
// and Retry-After, whatever shape the body takes.

extension SplatClientTests {

    /// Header the API sets on every response (requestId middleware in
    /// api/src/middleware/request-id.ts).
    private var requestIDHeader: [String: String] { ["X-Request-Id": Fixture.requestID] }

    func testErrorEnvelopeFieldsAreExposed() async throws {
        MockURLProtocol.stub(Fixture.scenePath, .json(404, Fixture.sceneNotFound))

        let error = await expectSplatError { try await self.makeClient().getScene(id: Fixture.sceneID) }

        let apiError = try XCTUnwrap(error?.apiError)
        XCTAssertEqual(apiError.statusCode, 404)
        XCTAssertEqual(apiError.code, "not_found")
        XCTAssertEqual(apiError.message, "Scene not found.")
        XCTAssertEqual(apiError.requestID, Fixture.requestID)
        XCTAssertNil(apiError.retryAfter)
    }

    func testRequestIDIsInErrorDescription() async throws {
        MockURLProtocol.stub(Fixture.scenePath, .json(500, Fixture.internalError))

        let error = await expectSplatError { try await self.makeClient().getScene(id: Fixture.sceneID) }

        XCTAssertEqual(
            error?.errorDescription,
            "Server error (500): An unexpected error occurred. Request ID: \(Fixture.requestID)."
        )
    }

    func testRequestIDFallsBackToHeader() async throws {
        // Schema-validation 400s skip the envelope, so only the header has the ID.
        MockURLProtocol.stub("/v1/scenes", .json(400, Fixture.validationFailure, headers: requestIDHeader))

        let error = await expectSplatError { try await self.makeClient().listScenePage(limit: 0) }

        let apiError = try XCTUnwrap(error?.apiError)
        XCTAssertEqual(apiError.statusCode, 400)
        XCTAssertNil(apiError.code)
        XCTAssertEqual(apiError.message, "limit: Number must be greater than or equal to 1")
        XCTAssertEqual(apiError.requestID, Fixture.requestID)
    }

    func testBodyRequestIDWinsOverHeader() async throws {
        let header = ["X-Request-Id": "header-id"]
        MockURLProtocol.stub(Fixture.scenePath, .json(404, Fixture.sceneNotFound, headers: header))

        let error = await expectSplatError { try await self.makeClient().getScene(id: Fixture.sceneID) }

        XCTAssertEqual(error?.apiError?.requestID, Fixture.requestID)
    }

    func testQuotaExceededIsRateLimited() async throws {
        MockURLProtocol.stub("/v1/scenes", .json(429, Fixture.quotaExceeded))

        let error = await expectSplatError { try await self.makeClient().createScene() }

        guard case .rateLimited(let apiError) = error else {
            return XCTFail("Expected .rateLimited, got \(String(describing: error))")
        }
        XCTAssertEqual(apiError.code, "quota_exceeded")
        XCTAssertEqual(apiError.requestID, Fixture.requestID)
    }

    func testEdgeRateLimitExposesRetryAfter() async throws {
        // The Cloudflare rate-limit rule answers before the API: 429 with
        // `Retry-After: 60` and no envelope (docs/internal/cloudflare-rate-limit.md).
        MockURLProtocol.stub("/v1/scenes", MockURLProtocol.Stub(
            statusCode: 429,
            body: Data(),
            headers: ["Retry-After": "60"]
        ))

        let error = await expectSplatError { try await self.makeClient().createScene() }

        guard case .rateLimited(let apiError) = error else {
            return XCTFail("Expected .rateLimited, got \(String(describing: error))")
        }
        XCTAssertEqual(apiError.retryAfter, 60)
        XCTAssertNil(apiError.code)
        XCTAssertNil(apiError.requestID)
        XCTAssertEqual(apiError.message, "Too Many Requests")
    }

    func testRetryAfterParsesSecondsAndDates() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2015-10-21T07:28:00Z"))

        XCTAssertEqual(SplatError.APIError.retryAfter("120", now: now), 120)
        XCTAssertEqual(SplatError.APIError.retryAfter("Wed, 21 Oct 2015 07:28:30 GMT", now: now), 30)
        XCTAssertEqual(SplatError.APIError.retryAfter("Wed, 21 Oct 2015 07:27:00 GMT", now: now), 0)
        XCTAssertNil(SplatError.APIError.retryAfter("-5", now: now))
        XCTAssertNil(SplatError.APIError.retryAfter("soon", now: now))
        XCTAssertNil(SplatError.APIError.retryAfter(nil, now: now))
    }

    func testNonJSONErrorBodyBecomesMessage() async throws {
        MockURLProtocol.stub(Fixture.scenePath, MockURLProtocol.Stub(
            statusCode: 502,
            body: Data("Bad Gateway".utf8),
            headers: ["Content-Type": "text/plain"]
        ))

        let error = await expectSplatError { try await self.makeClient().getScene(id: Fixture.sceneID) }

        XCTAssertEqual(error?.apiError?.statusCode, 502)
        XCTAssertNil(error?.apiError?.code)
        XCTAssertEqual(error?.apiError?.message, "Bad Gateway")
    }

    func testNonHTTPErrorsHaveNoAPIError() {
        XCTAssertNil(SplatError.timeout.apiError)
        XCTAssertNil(SplatError.processingFailed("x").apiError)
    }

    func testSceneIDIsEncodedAsOnePathSegment() async throws {
        _ = try? await makeClient().getScene(id: "a/b c")

        let url = try XCTUnwrap(MockURLProtocol.capturedRequests.first?.url)
        XCTAssertEqual(url.absoluteString, "https://api.splat-3d.com/v1/scenes/a%2Fb%20c")
    }
}

// MARK: - Messages shown to users

extension SplatClientTests {

    func testQuotaErrorShowsTheServersMessage() async throws {
        // The upgrade prompt from enforceSceneCreateQuota (api/src/middleware/quota.ts).
        MockURLProtocol.stub("/v1/scenes", .json(429, Fixture.quotaExceeded))

        let error = await expectSplatError { try await self.makeClient().createScene() }

        XCTAssertEqual(
            error?.errorDescription,
            "Monthly scene creation limit reached (10 scenes per month). Upgrade your plan for higher limits. Request ID: \(Fixture.requestID)."
        )
    }

    func testEdgeRateLimitSaysWhenToRetry() async throws {
        MockURLProtocol.stub("/v1/scenes", MockURLProtocol.Stub(statusCode: 429, body: Data(), headers: ["Retry-After": "60"]))

        let error = await expectSplatError { try await self.makeClient().createScene() }

        XCTAssertEqual(error?.errorDescription, "Rate limited. Retry after 60 seconds.")
    }

    func testHTMLErrorPageIsNotShownVerbatim() async throws {
        // An edge or proxy error page, not an API response.
        let page = "<html><head><title>502 Bad Gateway</title></head><body>" + String(repeating: "x", count: 4000) + "</body></html>"
        MockURLProtocol.stub(Fixture.scenePath, MockURLProtocol.Stub(
            statusCode: 502,
            body: Data(page.utf8),
            headers: ["Content-Type": "text/html"]
        ))

        let error = await expectSplatError { try await self.makeClient().getScene(id: Fixture.sceneID) }

        XCTAssertEqual(error?.apiError?.message, "Bad Gateway")
    }
}

// MARK: - 0.1.0 compatibility

extension SplatClientTests {

    func testInterpolatedAPIErrorReadsAsItsMessage() async throws {
        // 0.1.0 bound `.notFound(let message)` to a String; code that still
        // interpolates the binding must show the message, not a struct dump.
        MockURLProtocol.stub(Fixture.scenePath, .json(404, Fixture.sceneNotFound))

        let error = await expectSplatError { try await self.makeClient().getScene(id: Fixture.sceneID) }

        guard case .notFound(let message) = error else {
            return XCTFail("Expected .notFound, got \(String(describing: error))")
        }
        XCTAssertEqual("Not found: \(message)", "Not found: Scene not found.")
    }
}
