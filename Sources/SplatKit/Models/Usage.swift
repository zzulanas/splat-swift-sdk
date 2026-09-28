import Foundation

// MARK: - Usage

/// Usage for the current billing period, from ``SplatClient/getUsage()``.
public struct Usage: Decodable, Sendable, Equatable {

    /// Billing period as `YYYY-MM` (UTC), e.g. `"2026-09"`.
    public let period: String

    /// Scenes created this period.
    public let scenesCreated: Int

    /// Scenes processed this period.
    public let scenesProcessed: Int

    /// GPU seconds recorded this period.
    public let gpuSecondsUsed: Int

    /// Storage bytes recorded this period.
    public let storageBytes: Int64

    /// Your plan's limits for this period.
    public let limits: Limits

    enum CodingKeys: String, CodingKey {
        case period
        case scenesCreated = "scenes_created"
        case scenesProcessed = "scenes_processed"
        case gpuSecondsUsed = "gpu_seconds_used"
        case storageBytes = "storage_bytes"
        case limits
    }

    // MARK: - Limits

    /// Plan limits that ``Usage`` counts against.
    public struct Limits: Decodable, Sendable, Equatable {

        /// Scenes you can create per period, or `nil` for unlimited.
        public let scenesCreated: Int?

        /// Scenes you can process per period, or `nil` for unlimited.
        public let scenesProcessed: Int?

        /// GPU seconds per period.
        public let gpuSeconds: Int

        /// Storage quota in bytes.
        public let storageBytes: Int64

        enum CodingKeys: String, CodingKey {
            case scenesCreated = "scenes_created"
            case scenesProcessed = "scenes_processed"
            case gpuSeconds = "gpu_seconds"
            case storageBytes = "storage_bytes"
        }
    }
}
