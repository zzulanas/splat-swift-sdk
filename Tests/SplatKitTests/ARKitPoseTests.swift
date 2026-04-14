import XCTest
@testable import SplatKit

#if canImport(simd)
import simd
#endif

final class ARKitPoseTests: XCTestCase {

    // MARK: - Flat Array Construction

    func testManualConstructionPreservesValues() throws {
        // Column-major identity with translation tx=0.5, ty=1.0, tz=0.3
        let transform: [Float] = [
            1, 0, 0, 0,   // col 0
            0, 1, 0, 0,   // col 1
            0, 0, 1, 0,   // col 2
            0.5, 1.0, 0.3, 1.0,  // col 3 (translation)
        ]
        // Row-major intrinsics: [fx, 0, cx, 0, fy, cy, 0, 0, 1]
        let intrinsics: [Float] = [
            1440, 0, 960,
            0, 1440, 720,
            0, 0, 1,
        ]

        let pose = ARKitPose(
            timestamp: 1.5,
            filePath: "frame_000001.jpg",
            transform: transform,
            intrinsics: intrinsics,
            width: 1920,
            height: 1440
        )

        XCTAssertEqual(pose.timestamp, 1.5)
        XCTAssertEqual(pose.filePath, "frame_000001.jpg")
        XCTAssertEqual(pose.width, 1920)
        XCTAssertEqual(pose.height, 1440)
        XCTAssertEqual(pose.transform.count, 16)
        XCTAssertEqual(pose.intrinsics.count, 9)

        // Translation is in the last 4 elements (col 3, column-major)
        XCTAssertEqual(pose.transform[12], 0.5, "tx should be 0.5")
        XCTAssertEqual(pose.transform[13], 1.0, "ty should be 1.0")
        XCTAssertEqual(pose.transform[14], 0.3, "tz should be 0.3")
        XCTAssertEqual(pose.transform[15], 1.0, "w should be 1.0")

        // Intrinsics in row-major: [fx, 0, cx, 0, fy, cy, 0, 0, 1]
        XCTAssertEqual(pose.intrinsics[0], 1440, "fx")
        XCTAssertEqual(pose.intrinsics[4], 1440, "fy")
        XCTAssertEqual(pose.intrinsics[2], 960, "cx")
        XCTAssertEqual(pose.intrinsics[5], 720, "cy")
    }

    // MARK: - simd Conversion

    #if canImport(simd)
    func testSimd4x4ToFlatConversion() throws {
        // A translation matrix with tx=1, ty=2, tz=3
        let m = simd_float4x4(columns: (
            simd_float4(1, 0, 0, 0),
            simd_float4(0, 1, 0, 0),
            simd_float4(0, 0, 1, 0),
            simd_float4(1, 2, 3, 1)
        ))

        let flat = ARKitPose.simd4x4ToFlat(m)

        XCTAssertEqual(flat.count, 16)
        // Column 0
        XCTAssertEqual(flat[0], 1); XCTAssertEqual(flat[1], 0)
        XCTAssertEqual(flat[2], 0); XCTAssertEqual(flat[3], 0)
        // Column 1
        XCTAssertEqual(flat[4], 0); XCTAssertEqual(flat[5], 1)
        XCTAssertEqual(flat[6], 0); XCTAssertEqual(flat[7], 0)
        // Column 2
        XCTAssertEqual(flat[8], 0); XCTAssertEqual(flat[9], 0)
        XCTAssertEqual(flat[10], 1); XCTAssertEqual(flat[11], 0)
        // Column 3 (translation)
        XCTAssertEqual(flat[12], 1); XCTAssertEqual(flat[13], 2)
        XCTAssertEqual(flat[14], 3); XCTAssertEqual(flat[15], 1)
    }

    func testSimd3x3ToFlatConversion() throws {
        // Intrinsics: col0=[fx, 0, 0], col1=[0, fy, 0], col2=[cx, cy, 1]
        let fx: Float = 1440
        let fy: Float = 1440
        let cx: Float = 960
        let cy: Float = 720

        let m = simd_float3x3(columns: (
            simd_float3(fx, 0, 0),
            simd_float3(0, fy, 0),
            simd_float3(cx, cy, 1)
        ))

        let flat = ARKitPose.simd3x3ToFlat(m)

        XCTAssertEqual(flat.count, 9)
        // Row-major: [fx, 0, cx, 0, fy, cy, 0, 0, 1]
        XCTAssertEqual(flat[0], fx)
        XCTAssertEqual(flat[1], 0)
        XCTAssertEqual(flat[2], cx)
        XCTAssertEqual(flat[3], 0)
        XCTAssertEqual(flat[4], fy)
        XCTAssertEqual(flat[5], cy)
        XCTAssertEqual(flat[6], 0)
        XCTAssertEqual(flat[7], 0)
        XCTAssertEqual(flat[8], 1)
    }

    func testRoundTripSimd4x4() throws {
        let angle: Float = .pi / 4
        let cosA = cos(angle)
        let sinA = sin(angle)

        let original = simd_float4x4(columns: (
            simd_float4(cosA, sinA, 0, 0),
            simd_float4(-sinA, cosA, 0, 0),
            simd_float4(0, 0, 1, 0),
            simd_float4(2.5, -1.3, 0.7, 1)
        ))

        let flat = ARKitPose.simd4x4ToFlat(original)
        let roundTripped = ARKitPose.flatToSimd4x4(flat)

        for col in 0..<4 {
            for row in 0..<4 {
                XCTAssertEqual(
                    original[col][row],
                    roundTripped[col][row],
                    accuracy: 1e-6,
                    "Mismatch at [\(col)][\(row)]"
                )
            }
        }
    }

    func testRoundTripSimd3x3() throws {
        let original = simd_float3x3(columns: (
            simd_float3(1500, 0, 0),
            simd_float3(0, 1500, 0),
            simd_float3(1000, 750, 1)
        ))

        let flat = ARKitPose.simd3x3ToFlat(original)
        let roundTripped = ARKitPose.flatToSimd3x3(flat)

        for col in 0..<3 {
            for row in 0..<3 {
                XCTAssertEqual(
                    original[col][row],
                    roundTripped[col][row],
                    accuracy: 1e-6,
                    "Mismatch at [\(col)][\(row)]"
                )
            }
        }
    }

    func testIdentityMatrixConversion() throws {
        let identity = matrix_identity_float4x4

        let flat = ARKitPose.simd4x4ToFlat(identity)

        // Column-major identity: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
        let expected: [Float] = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
        XCTAssertEqual(flat, expected)
    }
    #endif

    // MARK: - JSON Encoding/Decoding

    func testFilepathCodingKey() throws {
        let pose = ARKitPose(
            timestamp: 0.5,
            filePath: "frame_042.jpg",
            transform: Array(repeating: Float(0), count: 16),
            intrinsics: Array(repeating: Float(0), count: 9),
            width: 1920, height: 1440
        )
        let data = try JSONEncoder().encode(pose)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["file_path"] as? String, "frame_042.jpg")
        XCTAssertNil(json["filePath"], "Should encode as snake_case file_path, not filePath")
    }

    func testTransformIsFlatArray() throws {
        let identity: [Float] = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
        let pose = ARKitPose(timestamp: 0, filePath: "f.jpg", transform: identity,
                             intrinsics: [1674,0,960, 0,1674,720, 0,0,1],
                             width: 1920, height: 1440)
        let data = try JSONEncoder().encode(pose)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let t = json["transform"] as? [NSNumber]
        XCTAssertNotNil(t, "transform should encode as flat array, not nested")
        XCTAssertEqual(t?.count, 16)
    }

    func testCodableRoundTrip() throws {
        let pose = ARKitPose(
            timestamp: 2.5,
            filePath: "frame_000010.jpg",
            transform: [
                0.707, 0.707, 0, 0,   // col 0
                -0.707, 0.707, 0, 0,  // col 1
                0, 0, 1, 0,           // col 2
                1.0, 2.0, 3.0, 1,     // col 3
            ],
            intrinsics: [
                1440, 0, 960,
                0, 1440, 720,
                0, 0, 1,
            ],
            width: 1920,
            height: 1440
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(pose)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ARKitPose.self, from: data)

        XCTAssertEqual(pose, decoded)
    }

    func testJSONOutputMatchesAPIFormat() throws {
        let pose = ARKitPose(
            timestamp: 1.234,
            filePath: "frame_000000.jpg",
            transform: [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0.5, 1.0, 0.3, 1,
            ],
            intrinsics: [
                1440, 0, 960,
                0, 1440, 720,
                0, 0, 1,
            ],
            width: 1920,
            height: 1440
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(pose)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Verify snake_case keys match the API expected format
        XCTAssertNotNil(json?["timestamp"])
        XCTAssertNotNil(json?["file_path"])
        XCTAssertNotNil(json?["transform"])
        XCTAssertNotNil(json?["intrinsics"])
        XCTAssertNotNil(json?["width"])
        XCTAssertNotNil(json?["height"])

        XCTAssertEqual(json?["timestamp"] as? Double, 1.234)
        XCTAssertEqual(json?["file_path"] as? String, "frame_000000.jpg")
        XCTAssertEqual(json?["width"] as? Int, 1920)
        XCTAssertEqual(json?["height"] as? Int, 1440)

        // Transform should be a flat 16-element array
        let transform = json?["transform"] as? [NSNumber]
        XCTAssertEqual(transform?.count, 16)

        // Intrinsics should be a flat 9-element array
        let intrinsics = json?["intrinsics"] as? [NSNumber]
        XCTAssertEqual(intrinsics?.count, 9)
    }

    // MARK: - CaptureResult

    func testCaptureResultStoresAllFields() {
        let url = URL(fileURLWithPath: "/tmp/test.mp4")
        let poses = [
            ARKitPose(
                timestamp: 0,
                filePath: "frame_000000.jpg",
                transform: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1],
                intrinsics: [1440,0,960, 0,1440,720, 0,0,1],
                width: 1920,
                height: 1440
            ),
        ]
        let result = CaptureResult(videoURL: url, poses: poses, duration: 15.5)

        XCTAssertEqual(result.videoURL, url)
        XCTAssertEqual(result.poses.count, 1)
        XCTAssertEqual(result.duration, 15.5)
    }
}
