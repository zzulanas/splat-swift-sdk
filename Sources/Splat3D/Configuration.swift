import Foundation

// MARK: - Configuration

extension SplatClient {

    /// Timeouts, polling, and automatic retries for a ``SplatClient``.
    ///
    /// ```swift
    /// var configuration = SplatClient.Configuration()
    /// configuration.pollingTimeout = 4 * 60 * 60
    /// let client = SplatClient(apiKey: "s3d_your_api_key", configuration: configuration)
    /// ```
    public struct Configuration: Sendable, Equatable {

        /// Seconds a request may wait for data before failing with
        /// `URLError.timedOut`. Defaults to 60.
        public var requestTimeout: TimeInterval = Defaults.requestTimeout

        /// Seconds between status checks while waiting for processing.
        /// Defaults to 10.
        public var pollingInterval: TimeInterval = Defaults.pollingInterval

        /// Seconds to wait for processing before throwing ``SplatError/timeout``.
        ///
        /// Defaults to 165 minutes. The API fails any job still processing
        /// 150 minutes after it started, checking every 10 minutes, so a
        /// client timeout past that means the server reported no outcome.
        /// A timeout never cancels the job.
        public var pollingTimeout: TimeInterval = Defaults.pollingTimeout

        /// Automatic retries after a failed read or
        /// ``SplatClient/processScene(id:arkitPoses:lidarPoints:enableLOD:idempotencyKey:)``.
        /// `0` turns retries off. Defaults to 3.
        ///
        /// Only network failures, 5xx responses and rate limits are retried,
        /// with exponential backoff and jitter; a used-up quota is not. A
        /// `Retry-After` of up to 60 seconds is waited out; a longer one is
        /// thrown to the caller. Polling does its own waiting: it rides out
        /// failures until ``pollingTimeout``.
        public var maxRetries: Int = Defaults.maxRetries

        /// A configuration with the default values.
        public init() {}
    }
}

// MARK: - Defaults

/// Default ``SplatClient/Configuration`` values.
private enum Defaults {

    static let requestTimeout: TimeInterval = 60
    static let pollingInterval: TimeInterval = 10
    static let maxRetries = 3

    // The API's stale-job sweep fails a scene still processing 150 minutes
    // after it started, and runs every 10 minutes (HARD_CAP_MINUTES and the
    // cron in the API's web/src/app/api/internal/scenes/sweep-stale/route.ts).
    // Waiting for the cap, one more sweep and a margin means a client
    // timeout only fires when the server never reported an outcome.
    static let serverHardCap: TimeInterval = 150 * 60
    static let sweepInterval: TimeInterval = 10 * 60
    static let sweepMargin: TimeInterval = 5 * 60
    static let pollingTimeout = serverHardCap + sweepInterval + sweepMargin
}
