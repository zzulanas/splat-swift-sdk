import Foundation

// MARK: - SplatError

/// Errors thrown by SplatKit API operations.
public enum SplatError: Error, LocalizedError, Sendable {

    /// The API key is missing, invalid, or revoked (HTTP 401).
    case unauthorized

    /// The requested resource was not found (HTTP 404).
    case notFound(String)

    /// Too many requests — back off and retry (HTTP 429).
    case rateLimited

    /// The server returned an unexpected error.
    ///
    /// - Parameters:
    ///   - statusCode: HTTP status code.
    ///   - message: Error message from the API.
    case serverError(Int, String)

    /// The response body could not be decoded.
    case decodingError(Error)

    /// The video upload failed.
    case uploadFailed(Error)

    /// Scene processing failed on the server.
    case processingFailed(String)

    /// A polling operation exceeded the maximum wait time.
    case timeout

    /// The request was cancelled (e.g., `Task.cancel()`).
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Invalid or missing API key."
        case .notFound(let message):
            return "Not found: \(message)"
        case .rateLimited:
            return "Rate limited. Please wait before retrying."
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .uploadFailed(let error):
            return "Upload failed: \(error.localizedDescription)"
        case .processingFailed(let message):
            return "Processing failed: \(message)"
        case .timeout:
            return "Operation timed out."
        case .cancelled:
            return "Operation was cancelled."
        }
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

/// Error envelope returned by the API on non-2xx responses.
struct APIErrorResponse: Decodable {
    let error: APIErrorBody
    let meta: APIResponseMeta?

    struct APIErrorBody: Decodable {
        let code: String
        let message: String
    }
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

    init(apiKey: String, baseURL: URL, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session

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
    func buildRequest(
        path: String,
        method: String,
        body: (any Encodable)? = nil,
        contentType: String = "application/json"
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw SplatError.serverError(0, "Invalid URL path: \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("SplatKit/1.0", forHTTPHeaderField: "User-Agent")

        if let body {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }

        return request
    }

    // MARK: - Request Execution

    /// Execute a request and decode the response envelope, returning `data`.
    func request<T: Decodable>(_ type: T.Type, path: String, method: String, body: (any Encodable)? = nil) async throws -> T {
        let urlRequest = try buildRequest(path: path, method: method, body: body)
        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SplatError.serverError(0, "Non-HTTP response received.")
        }

        try validateStatusCode(httpResponse.statusCode, data: data)

        do {
            let envelope = try decoder.decode(APIResponse<T>.self, from: data)
            return envelope.data
        } catch {
            throw SplatError.decodingError(error)
        }
    }

    /// Execute a request that returns an array in the `data` envelope.
    func requestArray<T: Decodable>(_ type: T.Type, path: String, method: String) async throws -> [T] {
        let urlRequest = try buildRequest(path: path, method: method)
        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SplatError.serverError(0, "Non-HTTP response received.")
        }

        try validateStatusCode(httpResponse.statusCode, data: data)

        do {
            let envelope = try decoder.decode(APIResponse<[T]>.self, from: data)
            return envelope.data
        } catch {
            throw SplatError.decodingError(error)
        }
    }

    /// Execute a request that returns no body (e.g., 204).
    func requestVoid(path: String, method: String) async throws {
        let urlRequest = try buildRequest(path: path, method: method)
        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SplatError.serverError(0, "Non-HTTP response received.")
        }

        // 204 No Content is expected for delete
        if httpResponse.statusCode == 204 { return }

        try validateStatusCode(httpResponse.statusCode, data: data)
    }

    // MARK: - Upload

    /// Upload a file to a presigned URL with a raw PUT request.
    func uploadFile(from fileURL: URL, to uploadURL: URL, contentType: String = "video/mp4") async throws {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("SplatKit/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await session.upload(for: request, fromFile: fileURL)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SplatError.serverError(0, "Non-HTTP response received.")
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw SplatError.serverError(
                    httpResponse.statusCode,
                    "Upload returned status \(httpResponse.statusCode)."
                )
            }
        } catch let error as SplatError {
            throw error
        } catch {
            throw SplatError.uploadFailed(error)
        }
    }

    // MARK: - Status Code Validation

    private func validateStatusCode(_ statusCode: Int, data: Data) throws {
        guard !(200...299).contains(statusCode) else { return }

        // Try to decode the API error envelope
        let message: String
        if let errorResponse = try? decoder.decode(APIErrorResponse.self, from: data) {
            message = errorResponse.error.message
        } else if let bodyString = String(data: data, encoding: .utf8), !bodyString.isEmpty {
            message = bodyString
        } else {
            message = "Unknown error."
        }

        switch statusCode {
        case 401:
            throw SplatError.unauthorized
        case 404:
            throw SplatError.notFound(message)
        case 429:
            throw SplatError.rateLimited
        default:
            throw SplatError.serverError(statusCode, message)
        }
    }
}
