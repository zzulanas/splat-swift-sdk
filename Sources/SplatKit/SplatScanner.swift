import Foundation

#if os(iOS)
@preconcurrency import ARKit
import AVFoundation

// MARK: - FrameRelay

/// Thread-safe relay for forwarding ARKit frames from the nonisolated delegate
/// callback to the main-actor-isolated scanner. Uses an `AsyncStream.Continuation`
/// which is `Sendable`.
@available(iOS 16.0, *)
private final class FrameRelay: Sendable {

    private let continuation: AsyncStream<ARFrame>.Continuation

    init(continuation: AsyncStream<ARFrame>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ frame: ARFrame) {
        continuation.yield(frame)
    }

    func finish() {
        continuation.finish()
    }
}

// MARK: - SplatScanner

/// Captures video and ARKit camera poses simultaneously for 3D scene reconstruction.
///
/// `SplatScanner` coordinates an `ARSession` with an `AVAssetWriter` to produce
/// a video file and matching camera poses. The poses are sampled at ~10fps
/// (every 3rd frame at 30fps) to keep payload sizes reasonable.
///
/// ## Usage
///
/// ```swift
/// let scanner = SplatScanner()
///
/// // Start capturing
/// try await scanner.start()
///
/// // ... user walks around the scene ...
///
/// // Stop and get results
/// let result = try await scanner.stop()
/// // result.videoURL  — H.264 video file
/// // result.poses     — ARKit camera poses
/// // result.duration  — capture duration
/// ```
///
/// ## Requirements
///
/// - iOS 16.0+
/// - Camera and motion permissions must be granted before calling ``start()``.
/// - Must be used from the main actor (ARSession requires the main thread).
///
/// ## LiDAR Support
///
/// On devices with LiDAR (iPhone 12 Pro+, iPad Pro), the scanner automatically
/// enables scene mesh reconstruction for improved depth estimation.
@available(iOS 16.0, *)
@MainActor
public final class SplatScanner: NSObject {

    // MARK: - Public Properties

    /// Whether the scanner is currently recording video and poses.
    public private(set) var isRecording: Bool = false

    /// Called on the main actor each time a new pose is captured.
    ///
    /// The parameter is the total number of poses captured so far.
    public var onFrameCountUpdated: ((Int) -> Void)?

    // MARK: - Private Properties

    private var arSession: ARSession?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private var capturedPoses: [ARKitPose] = []
    private var frameCount: Int = 0
    private var startTime: TimeInterval = 0
    private var outputURL: URL?

    /// Sample every Nth frame. At 30fps, sampling every 3rd gives ~10fps.
    private let sampleInterval: Int = 3

    /// Running index of sampled poses, used to generate filePath names.
    private var poseIndex: Int = 0

    // MARK: - Frame Relay

    /// Sendable relay for bridging the nonisolated ARSessionDelegate callback
    /// to the main-actor-isolated frame processing. Accessed from the nonisolated
    /// delegate method, but only written on the main actor (start/stop).
    private var frameRelay: FrameRelay?
    private var processingTask: Task<Void, Never>?

    // MARK: - Start

    /// Start the ARKit session and begin recording video with pose capture.
    ///
    /// - Throws: An error if the ARKit session cannot be started or the
    ///   video writer cannot be initialized.
    public func start() async throws {
        guard !isRecording else { return }

        // Reset state
        capturedPoses = []
        frameCount = 0
        poseIndex = 0

        // Create output file URL in temp directory
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        self.outputURL = outputURL

        // Set up the async stream for frame processing
        let (stream, continuation) = AsyncStream<ARFrame>.makeStream()
        let relay = FrameRelay(continuation: continuation)
        self.frameRelay = relay

        // Configure ARKit session
        let session = ARSession()
        session.delegate = self
        self.arSession = session

        let configuration = ARWorldTrackingConfiguration()
        configuration.videoFormat = Self.preferredVideoFormat(for: configuration)

        // Enable LiDAR mesh if available
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }

        configuration.isAutoFocusEnabled = true

        // Start AR session
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        // Wait for the first frame to determine video dimensions
        var firstFrame: ARFrame?
        for await frame in stream {
            firstFrame = frame
            break
        }

        guard let frame = firstFrame else {
            throw SplatError.serverError(0, "Failed to receive first ARKit frame.")
        }

        // Set up AVAssetWriter with the frame dimensions
        let width = CVPixelBufferGetWidth(frame.capturedImage)
        let height = CVPixelBufferGetHeight(frame.capturedImage)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,  // 10 Mbps
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ] as [String: Any],
        ]

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings
        )
        input.expectsMediaDataInRealTime = true

        // ARKit delivers frames in landscape-right orientation;
        // apply a 90-degree clockwise rotation so the video plays upright in portrait.
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        self.assetWriter = writer
        self.videoInput = input
        self.pixelBufferAdaptor = adaptor
        self.startTime = frame.timestamp

        isRecording = true

        // Process the first frame
        processFrame(frame, width: width, height: height)

        // Start background processing of remaining frames
        processingTask = Task { [weak self, stream] in
            for await arFrame in stream {
                guard let self, self.isRecording else { break }
                self.processFrame(arFrame, width: width, height: height)
            }
        }
    }

    // MARK: - Stop

    /// Stop recording and return the captured video and poses.
    ///
    /// Finalizes the H.264 video file and collects all sampled camera poses.
    ///
    /// - Returns: A ``CaptureResult`` containing the video URL, poses, and duration.
    /// - Throws: An error if the video could not be finalized.
    public func stop() async throws -> CaptureResult {
        guard isRecording else {
            throw SplatError.serverError(0, "Scanner is not recording.")
        }

        isRecording = false

        // Stop the frame relay
        frameRelay?.finish()
        frameRelay = nil
        processingTask?.cancel()
        await processingTask?.value

        // Pause the AR session
        arSession?.pause()

        // Finalize the video
        videoInput?.markAsFinished()
        if let writer = assetWriter {
            await writer.finishWriting()

            if writer.status == .failed, let error = writer.error {
                throw SplatError.uploadFailed(error)
            }
        }

        let duration = capturedPoses.last.map { $0.timestamp - startTime } ?? 0

        guard let url = outputURL else {
            throw SplatError.serverError(0, "No output URL available.")
        }

        let result = CaptureResult(
            videoURL: url,
            poses: capturedPoses,
            duration: duration
        )

        // Clean up references
        arSession = nil
        assetWriter = nil
        videoInput = nil
        pixelBufferAdaptor = nil

        return result
    }

    // MARK: - Frame Processing

    private func processFrame(_ frame: ARFrame, width: Int, height: Int) {
        frameCount += 1

        // Write every frame to the video
        let presentationTime = CMTime(
            seconds: frame.timestamp - startTime,
            preferredTimescale: 600
        )

        if let adaptor = pixelBufferAdaptor,
           let input = videoInput,
           input.isReadyForMoreMediaData {
            adaptor.append(frame.capturedImage, withPresentationTime: presentationTime)
        }

        // Sample poses at ~10fps (every Nth frame)
        guard frameCount % sampleInterval == 0 else { return }
        guard frame.camera.trackingState == .normal else { return }

        let filePath = "frame_\(String(format: "%06d", poseIndex)).jpg"
        poseIndex += 1

        let pose = ARKitPose(
            from: frame,
            filePath: filePath
        )

        capturedPoses.append(pose)
        onFrameCountUpdated?(capturedPoses.count)
    }

    // MARK: - Video Format Selection

    /// Select the best video format -- prefer 1920x1440 at 30fps if available.
    private static func preferredVideoFormat(
        for config: ARWorldTrackingConfiguration
    ) -> ARConfiguration.VideoFormat {
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats

        // Prefer 1920x1440 @ 30fps (4:3 at high resolution)
        if let preferred = formats.first(where: {
            $0.imageResolution.width == 1920
                && $0.imageResolution.height == 1440
                && $0.framesPerSecond == 30
        }) {
            return preferred
        }

        // Fall back to highest resolution at 30fps
        let thirtyFpsFormats = formats.filter { $0.framesPerSecond == 30 }
        if let best = thirtyFpsFormats.max(by: {
            $0.imageResolution.width * $0.imageResolution.height
                < $1.imageResolution.width * $1.imageResolution.height
        }) {
            return best
        }

        // Last resort: first available format
        return formats.first ?? config.videoFormat
    }
}

// MARK: - ARSessionDelegate

@available(iOS 16.0, *)
extension SplatScanner: ARSessionDelegate {

    nonisolated public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Forward frames via the Sendable FrameRelay to the async stream.
        // The stream is consumed on the main actor by the processing task.
        //
        // Note: Accessing frameRelay from a nonisolated context produces a
        // concurrency warning in Swift 5.9. This is safe because:
        // 1. frameRelay is only written on the main actor (start/stop)
        // 2. ARSession delegates are called on an internal serial queue
        // 3. The relay itself is Sendable (thread-safe continuation)
        // For Swift 6, use nonisolated(unsafe) or extract into a separate delegate object.
        frameRelay?.yield(frame)
    }
}

#endif // os(iOS)
