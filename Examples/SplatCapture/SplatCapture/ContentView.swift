import SwiftUI
import ARKit
import SplatKit

// MARK: - Configuration

/// Replace with your actual Splat API key before running on device.
let apiKey = "s3d_REPLACE_ME"

// MARK: - ARCameraView

/// Wraps an ARSCNView to display the live camera feed from an ARSession.
struct ARCameraView: UIViewRepresentable {

    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = true
        view.rendersContinuously = true
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        if uiView.session !== session {
            uiView.session = session
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

                // Overlay: pose counter + stop button
                VStack {
                    // Top: pose counter pill
                    HStack {
                        Spacer()
                        Label("\(viewModel.frameCount) poses", systemImage: "record.circle")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.red.opacity(0.85), in: Capsule())
                    }
                    .padding()

                    Spacer()

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
            EmptyView() // Handled by the camera overlay

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
            EmptyView() // Handled by the camera overlay

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
    @Published var errorMessage: String?
    @Published var showError: Bool = false

    /// Exposed so the view can attach an ARSCNView to the session.
    var arSession: ARSession? { scanner.session }

    private let client = SplatClient(apiKey: apiKey)
    private let scanner = SplatScanner()

    func startScan() async {
        do {
            scanner.onFrameCountUpdated = { [weak self] count in
                self?.frameCount = count
            }
            try await scanner.start()
            state = .scanning
        } catch {
            showError(error)
        }
    }

    func stopAndUpload() async {
        do {
            let result = try await scanner.stop()
            state = .uploading

            let scene = try await client.createAndProcess(
                videoURL: result.videoURL,
                title: "Captured Scene",
                preset: .standard,
                arkitPoses: result.poses
            ) { [weak self] status, pct in
                Task { @MainActor in
                    self?.state = .processing(
                        status: status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized,
                        pct: pct
                    )
                }
            }

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
        errorMessage = nil
    }

    private func showError(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
        state = .idle
    }
}
