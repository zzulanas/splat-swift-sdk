import Foundation

// MARK: - Timing

/// Clock, sleep and jitter for retries and polling. Tests replace it so
/// nothing actually waits.
struct Timing: Sendable {

    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let jitter: @Sendable (ClosedRange<TimeInterval>) -> TimeInterval

    private static let nanosecondsPerSecond: TimeInterval = 1_000_000_000

    static let live = Timing(
        now: { Date() },
        sleep: { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * nanosecondsPerSecond))
        },
        jitter: { range in TimeInterval.random(in: range) }
    )
}

// MARK: - Retries
//
//   attempt ──ok──> result
//      │
//      └─fails─> repeatable request?   (GET, or carries Idempotency-Key)
//                  └─> transient?       (network, 429, 5xx)
//                        └─> retries left and Retry-After ≤ 60 s?
//                              └─> sleep (Retry-After, or jittered backoff) ──> attempt

extension APIClient {

    /// Backoff ceiling before the first retry; it doubles with each retry.
    static let baseBackoff: TimeInterval = 1

    /// Largest backoff ceiling between attempts.
    static let maxBackoff: TimeInterval = 30

    /// Longest `Retry-After` waited out automatically. A longer one is
    /// thrown so the caller decides instead of the call blocking.
    static let maxRetryAfter: TimeInterval = 60

    /// Transport failures where the network, not the request, failed.
    static let transientURLErrors: Set<URLError.Code> = [
        .timedOut,
        .networkConnectionLost,
        .notConnectedToInternet,
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
    ]

    /// Run `attempt`, repeating transient failures if `request` is safe to repeat.
    func withRetries<T>(for request: URLRequest, _ attempt: () async throws -> T) async throws -> T {
        let limit = Self.isRepeatable(request) ? maxRetries : 0
        var retries = 0

        while true {
            do {
                return try await attempt()
            } catch {
                guard retries < limit, let delay = retryDelay(after: error, retries: retries) else {
                    throw error
                }
                try await timing.sleep(delay)
                retries += 1
            }
        }
    }

    /// Reads, and writes the API deduplicates by `Idempotency-Key` (only
    /// `process` today). Create, retrain, update, delete and cancel have no
    /// server-side deduplication, so repeating them could act twice.
    static func isRepeatable(_ request: URLRequest) -> Bool {
        request.httpMethod == HTTPMethod.get.rawValue
            || request.value(forHTTPHeaderField: HTTPHeader.idempotencyKey) != nil
    }

    /// Seconds to wait before the next attempt, or `nil` when `error` is final.
    func retryDelay(after error: Error, retries: Int) -> TimeInterval? {
        if let urlError = error as? URLError {
            return Self.transientURLErrors.contains(urlError.code) ? backoff(retries) : nil
        }

        // 4xx other than 429 means the request itself is wrong, e.g. a 409
        // for an idempotency key reused with a different body.
        guard let apiError = (error as? SplatError)?.apiError else {
            return nil
        }
        let status = apiError.statusCode
        guard status == HTTPStatus.tooManyRequests || HTTPStatus.serverError.contains(status) else {
            return nil
        }

        guard let retryAfter = apiError.retryAfter else {
            return backoff(retries)
        }
        return retryAfter <= Self.maxRetryAfter ? retryAfter : nil
    }

    /// Full-jitter exponential backoff: a random delay up to
    /// `baseBackoff × 2^retries`, capped at `maxBackoff`.
    private func backoff(_ retries: Int) -> TimeInterval {
        let ceiling = min(Self.maxBackoff, Self.baseBackoff * pow(2, Double(retries)))
        return timing.jitter(0...ceiling)
    }
}
