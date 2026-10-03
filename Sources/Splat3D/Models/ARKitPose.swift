import Foundation

#if canImport(simd)
import simd
#endif

#if canImport(CoreGraphics)
import CoreGraphics
#endif

#if os(iOS)
import ARKit
#endif

// MARK: - ARKitPose

/// A single camera pose captured from ARKit LiDAR.
///
/// Each pose records the camera's 4x4 transform matrix (as a flat 16-element array),
/// 3x3 intrinsics matrix (as a flat 9-element array), image dimensions, and the
/// filename of the corresponding image in the uploaded zip.
///
/// ```swift
/// // Create from an ARFrame
/// let pose = ARKitPose(from: frame, filePath: "frame_000042.jpg")
/// ```
public struct ARKitPose: Codable, Sendable, Equatable {

    /// Capture timestamp in seconds (from ARFrame.timestamp).
    public let timestamp: Double

    /// Image filename in the uploaded zip (e.g. "IMG_0001.jpg").
    /// Must match the actual filename in the zip uploaded to R2.
    public let filePath: String

    /// 4x4 camera-to-world matrix, column-major order (16 elements).
    /// Matches ARKit's simd_float4x4 memory layout directly.
    public let transform: [Float]

    /// 3x3 camera intrinsics matrix, row-major order (9 elements).
    /// Layout: [fx, 0, cx, 0, fy, cy, 0, 0, 1]
    public let intrinsics: [Float]

    /// Image width in pixels.
    public let width: Int

    /// Image height in pixels.
    public let height: Int

    enum CodingKeys: String, CodingKey {
        case timestamp
        case filePath = "file_path"
        case transform
        case intrinsics
        case width
        case height
    }

    // MARK: - Direct memberwise init (for tests)

    public init(
        timestamp: Double,
        filePath: String,
        transform: [Float],
        intrinsics: [Float],
        width: Int,
        height: Int
    ) {
        self.timestamp = timestamp
        self.filePath = filePath
        self.transform = transform
        self.intrinsics = intrinsics
        self.width = width
        self.height = height
    }

    // MARK: - Convenience init from ARKit types

    #if os(iOS)
    /// Create a pose from native ARKit types.
    /// - Parameters:
    ///   - frame: The ARFrame to capture pose from.
    ///   - filePath: The image filename this pose corresponds to in the zip.
    @available(iOS 16.0, *)
    public init(from frame: ARFrame, filePath: String) {
        self.timestamp = frame.timestamp
        self.filePath = filePath

        // simd_float4x4 is column-major. Extract all 16 floats in column-major order.
        let t = frame.camera.transform
        self.transform = [
            t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w,
            t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w,
            t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w,
            t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w,
        ]

        // simd_float3x3 intrinsics, extract row-major as [fx, 0, cx, 0, fy, cy, 0, 0, 1]
        let K = frame.camera.intrinsics
        self.intrinsics = [
            K.columns.0.x, K.columns.1.x, K.columns.2.x,  // row 0: fx, 0, cx
            K.columns.0.y, K.columns.1.y, K.columns.2.y,  // row 1: 0, fy, cy
            K.columns.0.z, K.columns.1.z, K.columns.2.z,  // row 2: 0, 0, 1
        ]

        self.width = Int(frame.camera.imageResolution.width)
        self.height = Int(frame.camera.imageResolution.height)
    }
    #endif

    // MARK: - Convenience init from simd types

    #if canImport(simd) && canImport(CoreGraphics)
    /// Create a pose from simd matrix types and a CGSize resolution.
    ///
    /// - Parameters:
    ///   - timestamp: Capture timestamp in seconds.
    ///   - filePath: Image filename in the uploaded zip.
    ///   - transform: `simd_float4x4` camera-to-world transform (column-major).
    ///   - intrinsics: `simd_float3x3` camera intrinsics (column-major).
    ///   - imageResolution: `CGSize` image dimensions.
    public init(
        timestamp: Double,
        filePath: String,
        transform: simd_float4x4,
        intrinsics: simd_float3x3,
        imageResolution: CGSize
    ) {
        self.timestamp = timestamp
        self.filePath = filePath

        // Column-major: extract all 16 floats in column order
        let t = transform
        self.transform = [
            t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w,
            t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w,
            t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w,
            t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w,
        ]

        // Row-major intrinsics: [fx, 0, cx, 0, fy, cy, 0, 0, 1]
        let K = intrinsics
        self.intrinsics = [
            K.columns.0.x, K.columns.1.x, K.columns.2.x,
            K.columns.0.y, K.columns.1.y, K.columns.2.y,
            K.columns.0.z, K.columns.1.z, K.columns.2.z,
        ]

        self.width = Int(imageResolution.width)
        self.height = Int(imageResolution.height)
    }
    #endif
}

// MARK: - Flat Array <-> simd Conversion Helpers

extension ARKitPose {

    #if canImport(simd)
    /// Convert a flat 16-element column-major `[Float]` to `simd_float4x4`.
    public static func flatToSimd4x4(_ flat: [Float]) -> simd_float4x4 {
        precondition(flat.count == 16)
        return simd_float4x4(columns: (
            simd_float4(flat[0], flat[1], flat[2], flat[3]),
            simd_float4(flat[4], flat[5], flat[6], flat[7]),
            simd_float4(flat[8], flat[9], flat[10], flat[11]),
            simd_float4(flat[12], flat[13], flat[14], flat[15])
        ))
    }

    /// Convert a `simd_float4x4` to a flat 16-element column-major `[Float]`.
    public static func simd4x4ToFlat(_ m: simd_float4x4) -> [Float] {
        let c = m.columns
        return [
            c.0.x, c.0.y, c.0.z, c.0.w,
            c.1.x, c.1.y, c.1.z, c.1.w,
            c.2.x, c.2.y, c.2.z, c.2.w,
            c.3.x, c.3.y, c.3.z, c.3.w,
        ]
    }

    /// Convert a flat 9-element row-major `[Float]` to `simd_float3x3`.
    ///
    /// Input layout: `[fx, 0, cx, 0, fy, cy, 0, 0, 1]` (row-major).
    /// simd_float3x3 stores column-major, so columns become:
    ///   col0 = [flat[0], flat[3], flat[6]]
    ///   col1 = [flat[1], flat[4], flat[7]]
    ///   col2 = [flat[2], flat[5], flat[8]]
    public static func flatToSimd3x3(_ flat: [Float]) -> simd_float3x3 {
        precondition(flat.count == 9)
        return simd_float3x3(columns: (
            simd_float3(flat[0], flat[3], flat[6]),
            simd_float3(flat[1], flat[4], flat[7]),
            simd_float3(flat[2], flat[5], flat[8])
        ))
    }

    /// Convert a `simd_float3x3` to a flat 9-element row-major `[Float]`.
    ///
    /// Output layout: `[fx, 0, cx, 0, fy, cy, 0, 0, 1]` (row-major).
    public static func simd3x3ToFlat(_ m: simd_float3x3) -> [Float] {
        let c = m.columns
        return [
            c.0.x, c.1.x, c.2.x,
            c.0.y, c.1.y, c.2.y,
            c.0.z, c.1.z, c.2.z,
        ]
    }
    #endif
}

// MARK: - CaptureResult

/// Result from an ARKit capture session.
///
/// Contains the recorded video, all sampled camera poses, the capture duration,
/// and an optional LiDAR point cloud from ARMeshAnchor (nil on non-LiDAR devices).
public struct CaptureResult: Sendable {

    /// File URL of the recorded H.264 video in the temporary directory.
    public let videoURL: URL

    /// Camera poses sampled during recording (typically ~10fps).
    public let poses: [ARKitPose]

    /// Total capture duration in seconds.
    public let duration: TimeInterval

    /// LiDAR point cloud sampled from ARMeshAnchor, or nil on non-LiDAR devices.
    /// Each entry is [x, y, z] in ARKit world coordinates.
    public let lidarPoints: [[Float]]?

    public init(videoURL: URL, poses: [ARKitPose], duration: TimeInterval, lidarPoints: [[Float]]? = nil) {
        self.videoURL = videoURL
        self.poses = poses
        self.duration = duration
        self.lidarPoints = lidarPoints
    }
}
