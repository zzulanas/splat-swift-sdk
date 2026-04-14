import SwiftUI
import ARKit
import SceneKit
import SplatKit

// MARK: - SplatKit Integration: Configuration
//
// 1. Set your API key here. Get one at https://splat-3d.com/dashboard
// 2. The SDK entry points used in this app:
//    - SplatScanner  — captures video + ARKit poses (see startScan/stopAndUpload)
//    - SplatClient   — uploads and processes via the Splat API (see stopAndUpload)
//    - ARKitPose     — pose format sent to the API (handled internally by SplatScanner)

/// Replace with your actual Splat API key before running on device.
let apiKey = "s3d_8b580d374c3631e010b882143e17a61f"

// MARK: - Mesh Material

/// Shared material for the scanned surface overlay.
private let meshMaterial: SCNMaterial = {
    let mat = SCNMaterial()
    mat.diffuse.contents = UIColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 0.5)
    mat.isDoubleSided = true
    mat.fillMode = .fill
    mat.lightingModel = .constant
    mat.writesToDepthBuffer = true
    mat.readsFromDepthBuffer = true
    mat.blendMode = .alpha
    return mat
}()

private let meshWireframeMaterial: SCNMaterial = {
    let mat = SCNMaterial()
    mat.diffuse.contents = UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.95)
    mat.isDoubleSided = true
    mat.fillMode = .lines
    mat.lightingModel = .constant
    mat.writesToDepthBuffer = false
    return mat
}()

// MARK: - ARMeshAnchor -> SCNGeometry

extension ARMeshGeometry {
    /// Convert ARKit mesh geometry to a SceneKit geometry for rendering.
    func toSCNGeometry() -> SCNGeometry {
        // Vertices
        let vertexSource = SCNGeometrySource(
            buffer: vertices.buffer,
            vertexFormat: vertices.format,
            semantic: .vertex,
            vertexCount: vertices.count,
            dataOffset: vertices.offset,
            dataStride: vertices.stride
        )

        // Triangle indices — ARKit uses uint32 per index, 3 per face
        let indexData = Data(
            bytesNoCopy: faces.buffer.contents(),
            count: faces.buffer.length,
            deallocator: .none
        )

        // Two elements sharing the same triangles: fill + wireframe edges
        let fillElement = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: faces.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let wireElement = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: faces.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(
            sources: [vertexSource],
            elements: [fillElement, wireElement]
        )
        // First material = filled surface, second = wireframe edges
        geometry.materials = [meshMaterial, meshWireframeMaterial]
        return geometry
    }
}

// MARK: - ARCameraView

/// Wraps an ARSCNView with live mesh overlay showing scanned surfaces.
struct ARCameraView: UIViewRepresentable {

    let session: ARSession

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = true
        view.rendersContinuously = true
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        if uiView.session !== session {
            uiView.session = session
        }
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {

        private let meshHaptic = UIImpactFeedbackGenerator(style: .medium)
        private var meshAnchorCount = 0

        func renderer(_ renderer: any SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }

            // Haptic pulse when a new mesh chunk is discovered
            meshAnchorCount += 1
            if meshAnchorCount % 2 == 0 {
                meshHaptic.impactOccurred(intensity: 0.7)
            }

            let node = SCNNode(geometry: meshAnchor.geometry.toSCNGeometry())
            return node
        }

        func renderer(_ renderer: any SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return }
            node.geometry = meshAnchor.geometry.toSCNGeometry()
        }
    }
}

// MARK: - ContentView

struct ContentView: View {

    @StateObject private var viewModel = ScanViewModel()

    var body: some View {
        ZStack {
            // Camera preview fills the screen during scanning
            if case .scanning = viewModel.state,
               let session = viewModel.arSession {
                ARCameraView(session: session)
                    .ignoresSafeArea()

                // Overlay UI
                VStack {
                    // Top bar: timer + counters
                    HStack {
                        Label(viewModel.scanDuration, systemImage: "timer")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.6), in: Capsule())

                        Spacer()

                        // Poses + frames stacked
                        VStack(alignment: .trailing, spacing: 4) {
                            Label("\(viewModel.frameCount) poses", systemImage: "record.circle")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.red.opacity(0.85), in: Capsule())

                            Label("\(viewModel.videoFrameCount) frames", systemImage: "film.stack")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.6), in: Capsule())
                        }
                    }
                    .padding()

                    Spacer()

                    // Tracking quality indicator
                    if let quality = viewModel.trackingQuality {
                        Text(quality)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(viewModel.trackingColor.opacity(0.8), in: Capsule())
                            .padding(.bottom, 8)
                    }

                    // Bottom: stop button
                    Button("Stop & Upload") {
                        Task { await viewModel.stopAndUpload() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)
                    .padding(.bottom, 40)
                }
            } else {
                // Non-scanning states: standard UI
                NavigationStack {
                    VStack(spacing: 24) {
                        Spacer()
                        statusSection
                        Spacer()
                        actionButton
                    }
                    .padding()
                    .navigationTitle("Splat Capture")
                    .alert("Error", isPresented: $viewModel.showError) {
                        Button("OK") {}
                    } message: {
                        Text(viewModel.errorMessage ?? "An unknown error occurred.")
                    }
                }
            }
        }
    }

    // MARK: - Status Section

    @ViewBuilder
    private var statusSection: some View {
        switch viewModel.state {
        case .idle:
            VStack(spacing: 8) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                Text("Point your iPhone at a scene and tap Start Scan")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

        case .scanning:
            EmptyView()

        case .uploading:
            VStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Uploading video...")
                    .font(.headline)
            }

        case .processing(let status, let pct):
            VStack(spacing: 8) {
                ProgressView(value: pct.map { $0 / 100 })
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 200)
                Text(status)
                    .font(.headline)
                if let pct {
                    Text("\(Int(pct))%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

        case .complete(let viewerURL):
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("Scene Ready!")
                    .font(.headline)
                Text(viewerURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open in Safari") {
                    UIApplication.shared.open(viewerURL)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Action Button

    @ViewBuilder
    private var actionButton: some View {
        switch viewModel.state {
        case .idle:
            Button("Start Scan") {
                Task { await viewModel.startScan() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

        case .scanning:
            EmptyView()

        case .uploading, .processing:
            EmptyView()

        case .complete:
            Button("New Scan") {
                viewModel.reset()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

// MARK: - ScanState

enum ScanState {
    case idle
    case scanning
    case uploading
    case processing(status: String, pct: Double?)
    case complete(viewerURL: URL)
}

// MARK: - ScanViewModel

@MainActor
final class ScanViewModel: ObservableObject {

    @Published var state: ScanState = .idle
    @Published var frameCount: Int = 0
    @Published var videoFrameCount: Int = 0
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var scanDuration: String = "0:00"
    @Published var trackingQuality: String?
    @Published var trackingColor: Color = .green

    /// Exposed so the view can attach an ARSCNView to the session.
    var arSession: ARSession? { scanner.session }

    // MARK: - SplatKit Integration: Client & Scanner Setup
    private let client = SplatClient(apiKey: apiKey)
    private let scanner = SplatScanner()
    private let haptics = UIImpactFeedbackGenerator(style: .medium)
    private var durationTimer: Timer?
    private var scanStartDate: Date?
    private var lastPoseCount: Int = 0

    func startScan() async {
        // Check for LiDAR support
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            errorMessage = "This device doesn't have a LiDAR scanner. SplatCapture requires iPhone 12 Pro or newer (or iPad Pro with LiDAR)."
            showError = true
            return
        }

        do {
            haptics.prepare()
            lastPoseCount = 0

            scanner.onFrameCountUpdated = { [weak self] count in
                self?.frameCount = count
                self?.videoFrameCount = self?.scanner.totalFrameCount ?? 0

                // Haptic tick every 5 poses
                if let self, count > self.lastPoseCount, count % 5 == 0 {
                    self.haptics.impactOccurred(intensity: 0.7)
                    self.lastPoseCount = count
                }
            }

            // MARK: - SplatKit Integration: Start Capture
            // scanner.start() begins the ARKit session and video recording.
            // Access scanner.session to connect your own ARSCNView for preview.
            try await scanner.start()
            state = .scanning
            scanStartDate = Date()

            // Update duration + frame count every second
            durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.scanStartDate else { return }
                    let elapsed = Int(Date().timeIntervalSince(start))
                    self.scanDuration = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
                    self.videoFrameCount = self.scanner.totalFrameCount
                }
            }

            startTrackingMonitor()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            showError(error)
        }
    }

    func stopAndUpload() async {
        durationTimer?.invalidate()
        durationTimer = nil
        UINotificationFeedbackGenerator().notificationOccurred(.warning)

        do {
            // MARK: - SplatKit Integration: Stop & Upload
            // scanner.stop() finalizes the video and returns poses + video URL.
            // client.createAndProcess() handles the full flow: create scene,
            // upload video, trigger processing, and poll until complete.
            let result = try await scanner.stop()
            state = .uploading

            let scene = try await client.createAndProcess(
                videoURL: result.videoURL,
                title: "Captured Scene",
                preset: .standard,
                arkitPoses: result.poses,
                lidarPoints: result.lidarPoints
            ) { [weak self] status, pct in
                Task { @MainActor in
                    self?.state = .processing(
                        status: status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized,
                        pct: pct
                    )
                }
            }

            UINotificationFeedbackGenerator().notificationOccurred(.success)

            if let viewerURL = scene.viewerURL {
                state = .complete(viewerURL: viewerURL)
            } else {
                state = .complete(
                    viewerURL: URL(string: "https://splat-3d.com/s/\(scene.id)")!
                )
            }
        } catch {
            showError(error)
        }
    }

    func reset() {
        state = .idle
        frameCount = 0
        videoFrameCount = 0
        errorMessage = nil
        scanDuration = "0:00"
        trackingQuality = nil
        lastPoseCount = 0
    }

    private func showError(_ error: Error) {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        errorMessage = error.localizedDescription
        showError = true
        state = .idle
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private func startTrackingMonitor() {
        Task {
            while case .scanning = state {
                if let frame = scanner.session?.currentFrame {
                    switch frame.camera.trackingState {
                    case .normal:
                        trackingQuality = "Tracking: Good"
                        trackingColor = .green
                    case .limited(let reason):
                        trackingColor = .yellow
                        switch reason {
                        case .initializing:
                            trackingQuality = "Initializing..."
                        case .excessiveMotion:
                            trackingQuality = "Slow down"
                            haptics.impactOccurred(intensity: 0.8)
                        case .insufficientFeatures:
                            trackingQuality = "Need more detail"
                        case .relocalizing:
                            trackingQuality = "Relocalizing..."
                        @unknown default:
                            trackingQuality = "Limited tracking"
                        }
                    case .notAvailable:
                        trackingQuality = "Tracking lost"
                        trackingColor = .red
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
}
