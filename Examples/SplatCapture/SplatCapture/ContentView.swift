import SwiftUI
import SplatKit

// MARK: - Configuration

/// Replace with your actual Splat API key before running on device.
let apiKey = "s3d_REPLACE_ME"

// MARK: - ContentView

struct ContentView: View {

    @StateObject private var viewModel = ScanViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                statusSection

                Spacer()

                actionButton

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
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
            VStack(spacing: 8) {
                Image(systemName: "record.circle")
                    .font(.system(size: 64))
                    .foregroundStyle(.red)
                Text("Scanning...")
                    .font(.headline)
                Text("\(viewModel.frameCount) poses captured")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

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
            Button("Stop & Upload") {
                Task { await viewModel.stopAndUpload() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)

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
