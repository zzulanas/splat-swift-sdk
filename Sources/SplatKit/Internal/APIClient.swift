import Foundation

// MARK: - SplatError

/// Errors thrown by SplatKit API operations.
///
/// A failed HTTP response is ``unauthorized(_:)``, ``notFound(_:)``,
/// ``rateLimited(_:)`` or ``requestFailed(_:)``, each carrying an
/// ``APIError`` with the API's error code, message, HTTP status and request
/// ID. Network failures are thrown as `URLError`, and a cancelled task throws
/// `CancellationError`.
public enum SplatError: Error, LocalizedError, Sendable {

    /// The API key is missing, invalid, or revoked (HTTP 401).
    case unauthorized(APIError)

    /// The requested resource was not found (HTTP 404).
    case notFound(APIError)

    /// Too many requests (HTTP 429).
    ///
    /// A ``APIError/code`` of `quota_exceeded` means the plan's monthly limit
    /// is used up, so retrying won't help until the next period. Otherwise it
    /// is a rate limit: wait ``APIError/retryAfter`` when the server sent it.
    case rateLimited(APIError)

    /// Any other failed response, 4xx or 5xx: e.g. `conflict` (409),
    /// `insufficient_credits` (402) or `internal_error` (500). Branch on
    /// ``APIError/code`` or ``APIError/statusCode``.
    case requestFailed(APIError)

    /// The response body could not be decoded.
    case decodingError(Error)

    /// The video upload failed without a response, e.g. the connection
    /// dropped. An upload rejected with an error status is ``requestFailed(_:)``.
    case uploadFailed(Error)

    /// ``SplatScanner`` could not record. No request was made.
    case captureFailed(String)

    /// Processing failed on the server.
    ///
    /// Usually final. Rarely, the pipeline completes a scene the stale-job
    /// sweep had failed, so ``SplatClient/getScene(id:)`` has the last word.
    case processingFailed(String)

    /// This client stopped waiting for processing after
    /// ``SplatClient/Configuration/pollingTimeout``.
    ///
    /// Not a server-side failure: the job may still finish. Check again with
    /// ``SplatClient/waitForScene(id:onProgress:)`` or ``SplatClient/getScene(id:)``.
    case timeout

    /// The scene was cancelled on the server, e.g. by ``SplatClient/cancelScene(id:)``.
    /// A cancelled task throws `CancellationError` instead.
    case cancelled

    /// Processing never started for this scene: its source was not uploaded,
    /// or no ``SplatClient/processScene(id:arkitPoses:lidarPoints:enableLOD:idempotencyKey:)``
    /// call went through. There is no job to wait for.
    case notStarted

    /// ``SplatClient/createAndProcess(videoURL:title:preset:arkitPoses:lidarPoints:onProgress:)``
    /// failed after creating its scene. The ``Interruption`` says which step
    /// failed, what was charged, and how to resume.
    case interrupted(Interruption)

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let error):
            return "Invalid or missing API key." + error.requestSuffix
        case .notFound(let error):
            return "Not found: \(error.message)" + error.requestSuffix
        case .rateLimited(let error):
            return error.rateLimitSummary + error.requestSuffix
        case .requestFailed(let error):
            let kind = HTTPStatus.serverError.contains(error.statusCode) ? "Server error" : "Request failed"
            return "\(kind) (\(error.statusCode)): \(error.message)" + error.requestSuffix
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .uploadFailed(let error):
            return "Upload failed: \(error.localizedDescription)"
        case .captureFailed(let message):
            return "Capture failed: \(message)"
        case .processingFailed(let message):
            return "Processing failed: \(message)"
        case .timeout:
            return "Timed out waiting for processing. The scene may still finish."
        case .cancelled:
            return "The scene was cancelled."
        case .notStarted:
            return "Processing hasn't started for this scene."
        case .interrupted(let interruption):
            return interruption.summary
        }
    }

    /// The failed HTTP response behind this error, if there was one.
    ///
    /// ```swift
    /// } catch let error as SplatError {
    ///     if let apiError = error.apiError {
    ///         print(apiError.code ?? "", apiError.requestID ?? "")
    ///     }
    /// }
    /// ```
    public var apiError: APIError? {
        switch self {
        case .unauthorized(let error), .notFound(let error), .rateLimited(let error), .requestFailed(let error):
            return error
        case .interrupted(let interruption):
            return (interruption.underlying as? SplatError)?.apiError
        case .decodingError, .uploadFailed, .captureFailed, .processingFailed, .timeout, .cancelled, .notStarted:
            return nil
        }
    }
}

// MARK: - SplatError.APIError

extension SplatError {

    /// A failed HTTP response.
    public struct APIError: Sendable, Equatable {

        /// HTTP status code, e.g. `409`.
        public let statusCode: Int

        /// The API's machine-readable error code: `invalid_input`,
        /// `unauthorized`, `forbidden`, `not_found`, `conflict`,
        /// `payload_too_large`, `insufficient_credits`, `rate_limited`,
        /// `quota_exceeded`, `internal_error` or `upstream_error`.
        ///
        /// `nil` when the body was not an API error envelope: a request that
        /// failed schema validation, an edge rate limit, or a storage upload
        /// error.
        public let code: String?

        /// Human-readable description of the failure.
        public let message: String

        /// ID of the request in Splat's logs. Include it when contacting support.
        public let requestID: String?

        /// Seconds the server asked clients to wait before retrying, from the
        /// `Retry-After` header. `nil` when the response did not include one.
        public let retryAfter: TimeInterval?

        /// Create an API error, e.g. for a test double.
        public init(
            statusCode: Int,
            code: String? = nil,
            message: String,
            requestID: String? = nil,
            retryAfter: TimeInterval? = nil
        ) {
            self.statusCode = statusCode
            self.code = code
            self.message = message
            self.requestID = requestID
            self.retryAfter = retryAfter
        }

        /// The server's own words when it sent an API error (e.g. a quota's
        /// upgrade prompt), otherwise a generic note with the requested delay.
        var rateLimitSummary: String {
            if code != nil {
                return message
            }
            guard let retryAfter else {
                return "Rate limited. Please wait before retrying."
            }
            let seconds = Int(retryAfter)
            return "Rate limited. Retry after \(seconds) \(seconds == 1 ? "second" : "seconds")."
        }

        /// Appended to error descriptions so support requests carry the ID.
        var requestSuffix: String {
            guard let requestID else {
                return ""
            }
            return " Request ID: \(requestID)."
        }
    }
}

// MARK: - Failed Response Parsing

extension SplatError.APIError {

    /// Longest plain-text body used as a message. Longer bodies, and HTML
    /// pages from an edge proxy, become the status's reason phrase instead.
    static let maxTextMessageLength = 200

    /// RFC 9110 §15 reason phrases for statuses the API or its edge return.
    static let reasonPhrases: [Int: String] = [
        400: "Bad Request",
        401: "Unauthorized",
        402: "Payment Required",
        403: "Forbidden",
        404: "Not Found",
        409: "Conflict",
        413: "Content Too Large",
        422: "Unprocessable Content",
        429: "Too Many Requests",
        500: "Internal Server Error",
        502: "Bad Gateway",
        503: "Service Unavailable",
        504: "Gateway Timeout",
    ]

    /// Read a failed response: the API's error envelope when present,
    /// otherwise a validation failure or the raw body text.
    init(response: HTTPURLResponse, body: Data, decoder: JSONDecoder, now: Date = Date()) {
        let headerRequestID = response.value(forHTTPHeaderField: HTTPHeader.requestID)
        let retryAfter = Self.retryAfter(response.value(forHTTPHeaderField: HTTPHeader.retryAfter), now: now)

        // The body's request ID wins; the header carries the same value and
        // is the fallback for bodies that are not envelopes.
        if let envelope = try? decoder.decode(APIErrorResponse.self, from: body) {
            self.init(
                statusCode: response.statusCode,
                code: envelope.error.code,
                message: envelope.error.message,
                requestID: envelope.meta?.requestId ?? headerRequestID,
                retryAfter: retryAfter
            )
            return
        }

        self.init(
            statusCode: response.statusCode,
            message: Self.message(from: body, statusCode: response.statusCode, decoder: decoder),
            requestID: headerRequestID,
            retryAfter: retryAfter
        )
    }

    /// Message for a body that is not an error envelope.
    private static func message(from body: Data, statusCode: Int, decoder: JSONDecoder) -> String {
        if let failure = try? decoder.decode(ValidationFailure.self, from: body), !failure.error.issues.isEmpty {
            return failure.error.issues.map(\.summary).joined(separator: "; ")
        }

        // A short plain-text body is the best message available; an empty
        // body or an HTML error page is not something to show a user.
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let isReadable = !text.isEmpty && !text.hasPrefix("<") && text.count <= maxTextMessageLength
        guard !isReadable else {
            return text
        }
        return reasonPhrases[statusCode] ?? "HTTP \(statusCode)"
    }

    /// Delay from a `Retry-After` value: delay-seconds (`"60"`) or an
    /// HTTP-date (RFC 9110 §10.2.3). Dates in the past mean "now".
    static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        if let seconds = Int(value) {
            return seconds < 0 ? nil : TimeInterval(seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else {
            return nil
        }
        return max(0, date.timeIntervalSince(now))
    }
}

// MARK: - API Response Envelope

/// The standard `{ data: T, meta: { request_id, ... } }` envelope.
struct APIResponse<T: Decodable>: Decodable {
    let data: T
    let meta: APIResponseMeta
}

struct APIResponseMeta: Decodable {
    let requestId: String

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
    }
}

/// The paginated `{ data: [T], meta: { request_id, next_cursor, has_more, count } }`
/// envelope returned by `GET /v1/scenes`.
struct APIPageResponse<T: Decodable>: Decodable {
    let data: [T]
    let meta: Meta

    struct Meta: Decodable {
        let nextCursor: String?
        let hasMore: Bool

        enum CodingKeys: String, CodingKey {
            case nextCursor = "next_cursor"
            case hasMore = "has_more"
        }
    }
}

/// Error envelope returned by the API on non-2xx responses:
/// `{ error: { code, message, details? }, meta: { request_id, ... } }`.
struct APIErrorResponse: Decodable {
    let error: APIErrorBody
    let meta: Meta?

    struct APIErrorBody: Decodable {
        let code: String
        let message: String
    }

    struct Meta: Decodable {
        let requestId: String?

        enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
        }
    }
}

/// Body of a request that failed schema validation. These 400s bypass the
/// error envelope: the API's validator returns
/// `{ success: false, error: { issues: [{ message, path, ... }], name: "ZodError" } }`.
struct ValidationFailure: Decodable {
    let error: Issues

    struct Issues: Decodable {
        let issues: [Issue]
    }

    struct Issue: Decodable {
        let message: String
        let path: [PathComponent]

        /// `"limit: Number must be greater than or equal to 1"`.
        var summary: String {
            guard !path.isEmpty else {
                return message
            }
            return path.map(\.name).joined(separator: ".") + ": " + message
        }
    }

    /// A field name or array index.
    struct PathComponent: Decodable {
        let name: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let key = try? container.decode(String.self) {
                name = key
                return
            }
            name = String(try container.decode(Int.self))
        }
    }
}

// MARK: - HTTP Constants

/// HTTP methods the API uses.
enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case put = "PUT"
    case delete = "DELETE"
}

/// HTTP status codes the client branches on (RFC 9110 §15).
enum HTTPStatus {
    static let success = 200...299
    static let unauthorized = 401
    static let notFound = 404
    static let tooManyRequests = 429
    static let serverError = 500...599
}

/// Header names and values the client sends or reads.
enum HTTPHeader {
    static let authorization = "Authorization"
    static let contentType = "Content-Type"
    static let userAgent = "User-Agent"
    static let requestID = "X-Request-Id"
    static let retryAfter = "Retry-After"
    /// Lets the API replay a paid `process` call instead of charging twice.
    static let idempotencyKey = "Idempotency-Key"
    /// Format the download endpoint actually served: `sog` or `ply`.
    static let splatFormat = "X-Splat-Format"

    static let jsonContentType = "application/json"
    static let userAgentValue = "SplatKit/1.0"
}

// MARK: - API Paths

/// API routes. Scene IDs are percent-encoded as a single path segment, so an
/// ID can never change which route a request reaches.
enum APIPath {
    static let scenes = "/v1/scenes"
    static let usage = "/v1/usage"

    /// Sub-resources of `/v1/scenes/{id}`.
    enum SceneAction: String {
        case process
        case retrain
        case cancel
        case download
        case thumbnail
    }

    static func scene(_ id: String, _ action: SceneAction? = nil) -> String {
        let segment = id.addingPercentEncoding(withAllowedCharacters: unreserved) ?? id
        let path = "\(scenes)/\(segment)"
        guard let action else {
            return path
        }
        return "\(path)/\(action.rawValue)"
    }

    /// RFC 3986 §2.3 unreserved characters: safe anywhere in a URL.
    static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}

// MARK: - APIClient

/// Internal HTTP client for the Splat REST API.
///
/// Handles authentication, request construction, response envelope unwrapping,
/// and error mapping. All public API methods on ``SplatClient`` delegate here.
final class APIClient: Sendable {

    let baseURL: URL
    let apiKey: String
    let session: URLSession
    let decoder: JSONDecoder
    let encoder: JSONEncoder
    let requestTimeout: TimeInterval
    let maxRetries: Int
    let timing: Timing

    init(
        apiKey: String,
        baseURL: URL,
        session: URLSession = .shared,
        configuration: SplatClient.Configuration = .init(),
        timing: Timing = .live
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.requestTimeout = configuration.requestTimeout
        self.maxRetries = configuration.maxRetries
        self.timing = timing

        let decoder = JSONDecoder()
        // Note: we do NOT use .convertFromSnakeCase here because Scene and other
        // models define explicit CodingKeys with the exact JSON key strings.
        // Using both would cause a double-conversion mismatch.

        // ISO 8601 with fractional seconds support
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = formatter.date(from: string) {
                return date
            }
            if let date = fallbackFormatter.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode date: \(string)"
            )
        }
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    // MARK: - Request Building

    /// Build a `URLRequest` for the given path and method.
    ///
    /// Query values are percent-encoded strictly: the list cursor is a
    /// timestamp like `2026-09-28T12:00:00.123456+00:00`, and the API decodes
    /// a bare `+` in a query string as a space.
    func buildRequest(
        path: String,
        method: HTTPMethod,
        query: [URLQueryItem] = [],
        body: (any Encodable)? = nil,
        idempotencyKey: String? = nil
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw URLError(.badURL)
        }

        if !query.isEmpty {
            components.percentEncodedQueryItems = query.map { item in
                URLQueryItem(
                    name: item.name,
                    value: item.value?.addingPercentEncoding(withAllowedCharacters: APIPath.unreserved)
                )
            }
        }

        guard let resolved = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: resolved, timeoutInterval: requestTimeout)
        request.httpMethod = method.rawValue
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: HTTPHeader.authorization)
        request.setValue(HTTPHeader.userAgentValue, forHTTPHeaderField: HTTPHeader.userAgent)
        request.setValue(idempotencyKey, forHTTPHeaderField: HTTPHeader.idempotencyKey)

        if let body {
            request.setValue(HTTPHeader.jsonContentType, forHTTPHeaderField: HTTPHeader.contentType)
            request.httpBody = try encoder.encode(body)
        }

        return request
    }

    // MARK: - Request Execution

    /// Execute a request and decode the response envelope, returning `data`.
    ///
    /// GETs, and requests with an `idempotencyKey`, are retried on transient
    /// failures (see ``withRetries(for:_:)``).
    func request<T: Decodable>(
        _ type: T.Type,
        path: String,
        method: HTTPMethod,
        body: (any Encodable)? = nil,
        idempotencyKey: String? = nil
    ) async throws -> T {
        let urlRequest = try buildRequest(path: path, method: method, body: body, idempotencyKey: idempotencyKey)
        let (data, _) = try await send(urlRequest)
        return try decode(APIResponse<T>.self, from: data).data
    }

    /// Fetch one page of a paginated list endpoint.
    func requestPage<T: Decodable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem]
    ) async throws -> APIPageResponse<T> {
        let urlRequest = try buildRequest(path: path, method: .get, query: query)
        let (data, _) = try await send(urlRequest)
        return try decode(APIPageResponse<T>.self, from: data)
    }

    /// Execute a request whose response body is not needed (e.g., 204).
    func requestVoid(path: String, method: HTTPMethod) async throws {
        let urlRequest = try buildRequest(path: path, method: method)
        _ = try await send(urlRequest)
    }

    /// Execute a GET and return the raw response body, e.g. image bytes.
    func requestData(path: String) async throws -> Data {
        let urlRequest = try buildRequest(path: path, method: .get)
        let (data, _) = try await send(urlRequest)
        return data
    }

    /// Stream a GET response body to a temporary file the caller must move.
    func download(path: String, query: [URLQueryItem]) async throws -> (URL, HTTPURLResponse) {
        let urlRequest = try buildRequest(path: path, method: .get, query: query)

        return try await withRetries(for: urlRequest) {
            let (fileURL, response) = try await session.download(for: urlRequest)
            let httpResponse = try httpResponse(response)

            guard HTTPStatus.success.contains(httpResponse.statusCode) else {
                // Error bodies land in the file too; read the envelope, then discard it.
                let body = (try? Data(contentsOf: fileURL)) ?? Data()
                try? FileManager.default.removeItem(at: fileURL)
                throw failure(for: httpResponse, body: body)
            }

            return (fileURL, httpResponse)
        }
    }

    /// Send a request and return the body of a 2xx response, retrying
    /// transient failures when the request is safe to repeat.
    ///
    /// - Throws: ``SplatError`` for any other status; `URLError` when the
    ///   request never got a response.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withRetries(for: request) {
            let (data, response) = try await session.data(for: request)
            let httpResponse = try httpResponse(response)

            guard HTTPStatus.success.contains(httpResponse.statusCode) else {
                throw failure(for: httpResponse, body: data)
            }

            return (data, httpResponse)
        }
    }

    // MARK: - Upload

    /// Upload a file to a presigned URL with a raw PUT request.
    func uploadFile(from fileURL: URL, to uploadURL: URL, contentType: String = "video/mp4") async throws {
        var request = URLRequest(url: uploadURL, timeoutInterval: requestTimeout)
        request.httpMethod = HTTPMethod.put.rawValue
        request.setValue(contentType, forHTTPHeaderField: HTTPHeader.contentType)
        request.setValue(HTTPHeader.userAgentValue, forHTTPHeaderField: HTTPHeader.userAgent)

        do {
            let (_, response) = try await session.upload(for: request, fromFile: fileURL)
            let httpResponse = try httpResponse(response)

            // Storage answered, not the API: there is no envelope or request ID.
            guard HTTPStatus.success.contains(httpResponse.statusCode) else {
                throw SplatError.requestFailed(SplatError.APIError(
                    statusCode: httpResponse.statusCode,
                    message: "Upload returned status \(httpResponse.statusCode)."
                ))
            }
        } catch let error as SplatError {
            throw error
        } catch {
            // A cancelled task stops the upload; report it as Swift reports cancellation.
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw SplatError.uploadFailed(error)
        }
    }

    // MARK: - Response Handling

    /// Decode a successful response body.
    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw SplatError.decodingError(error)
        }
    }

    private func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return httpResponse
    }

    /// Map a non-2xx response to the ``SplatError`` case for its status.
    private func failure(for response: HTTPURLResponse, body: Data) -> SplatError {
        let error = SplatError.APIError(response: response, body: body, decoder: decoder, now: timing.now())

        switch response.statusCode {
        case HTTPStatus.unauthorized:
            return .unauthorized(error)
        case HTTPStatus.notFound:
            return .notFound(error)
        case HTTPStatus.tooManyRequests:
            return .rateLimited(error)
        default:
            return .requestFailed(error)
        }
    }
}
