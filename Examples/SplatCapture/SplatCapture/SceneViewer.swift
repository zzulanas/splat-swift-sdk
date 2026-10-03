import SwiftUI
import Splat3D
import SplatKit

// MARK: - Splat3D + SplatKit Integration: View in 3D
//
//   SplatClient.downloadScene(format: spz) ──> scene-<id>.spz in tmp/
//        │   (the session's delegate watches the bytes arrive)
//        └──> SplatWorldView ──> SplatKit's SplatMetalView
//
// Both modules import side by side: Splat3D was named SplatKit before 1.0 and
// was renamed so it wouldn't clash with this renderer.

/// SPZ, the compressed format SplatKit reads. Built from its raw value: the
/// SDK names a format once the API documents it, and today's API doesn't yet.
let spzFormat = ModelFormat(rawValue: "spz")

/// Downloads a scene's SPZ and shows it with SplatKit.
struct SceneViewerScreen: View {

    let title: String

    @StateObject private var model: SceneViewerModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var mode = NavigationMode.orbit
    // Splat3D scenes are +Y up. SplatKit reads SPZ as +Y down (World Labs'
    // convention) and flips it, so start with the picture turned back.
    @State private var flipped = true
    @State private var walkSpeed: Float = 0
    @State private var resetCount = 0

    /// Scene units per second while a move arrow is held.
    private static let walkingSpeed: Float = 0.6

    init(sceneID: String, title: String) {
        self.title = title
        _model = StateObject(wrappedValue: SceneViewerModel(sceneID: sceneID))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await model.load() }
        .onDisappear { model.close() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .downloading(let received, let expected):
            DownloadProgress(received: received, expected: expected)

        case .showing(let file, let bytes):
            world(file)
                .overlay {
                    if !model.worldReady {
                        Notice(symbol: nil, title: "Loading into SplatKit…", detail: bytes.formatted(.byteCount(style: .file)))
                    }
                }

        case .undrawable(let bytes):
            Notice(
                symbol: "iphone.slash",
                title: "Downloaded, but not drawn here",
                detail: "Got \(bytes.formatted(.byteCount(style: .file))) of SPZ, but SplatKit couldn't start Metal. "
                    + "It needs a physical device with an A14 or M1 chip or newer (Apple GPU family 7), so the "
                    + "Simulator never draws; on such a device, its Metal setup failed."
            )

        case .failed(let failure):
            VStack(spacing: 16) {
                Notice(symbol: "exclamationmark.triangle", title: failure.title, detail: failure.detail)
                Button("Try Again") {
                    Task { await model.retry() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func world(_ file: URL) -> some View {
        SplatWorldView(
            file: file,
            mode: mode,
            flipped: flipped,
            walkSpeed: walkSpeed,
            resetCount: resetCount,
            isActive: scenePhase == .active,
            onEvent: { model.handle($0) }
        )
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            if let stats = model.stats {
                StatsLine(stats: stats)
            }
        }
        .overlay(alignment: .bottom) {
            if model.worldReady {
                controls
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 12) {
            if mode == .look {
                HStack(spacing: 24) {
                    holdToMove(symbol: "arrow.up", label: "Move forward", speed: Self.walkingSpeed)
                    holdToMove(symbol: "arrow.down", label: "Move back", speed: -Self.walkingSpeed)
                }
            }

            HStack(spacing: 12) {
                Picker("Navigation", selection: modeSelection) {
                    Text("Orbit").tag(NavigationMode.orbit)
                    Text("Look").tag(NavigationMode.look)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 160)

                Toggle(isOn: $flipped) {
                    Label("Flip", systemImage: "arrow.up.arrow.down")
                }
                .toggleStyle(.button)

                Button {
                    resetCount += 1
                } label: {
                    Label("Reset", systemImage: "scope")
                }
                .labelStyle(.iconOnly)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }

    /// The mode picker's selection. A switch hides the move arrows, so one held
    /// through it never reports its release: stop walking in the same update.
    private var modeSelection: Binding<NavigationMode> {
        Binding(
            get: { mode },
            set: { newMode in
                walkSpeed = 0
                mode = newMode
            }
        )
    }

    /// Walks while held: SplatKit moves the camera along where it looks.
    private func holdToMove(symbol: String, label: String, speed: Float) -> some View {
        Button {} label: {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
        }
        .buttonStyle(HoldButtonStyle { held in
            walkSpeed = held ? speed : 0
        })
        .accessibilityLabel(label)
    }
}

// MARK: - SceneViewerModel

/// Downloads a scene's SPZ for SplatKit and follows it onto the screen.
@MainActor
final class SceneViewerModel: ObservableObject {

    enum Phase {
        /// Bytes so far, and the total when the server sent one.
        case downloading(received: Int64, expected: Int64?)
        /// The file is on disk, and SplatKit is loading or showing it.
        case showing(file: URL, bytes: Int64)
        /// The file is on disk, but SplatKit can't draw on this device.
        case undrawable(bytes: Int64)
        case failed(ViewerFailure)
    }

    @Published private(set) var phase = Phase.downloading(received: 0, expected: nil)
    /// The world's first frame is on screen.
    @Published private(set) var worldReady = false
    @Published private(set) var stats: SplatStats?

    private static let progressInterval: Duration = .milliseconds(250)

    private let sceneID: String
    private var file: URL?
    /// Bumped by every load and by the screen closing. A download that lands
    /// after a bump is stale, and is deleted at once.
    private var generation = 0

    init(sceneID: String) {
        self.sceneID = sceneID
    }

    /// Try Again. A file still on disk is one SplatKit refused: hand it over
    /// again, since a new download would bring the same bytes.
    func retry() async {
        guard let file else {
            await load()
            return
        }
        worldReady = false
        stats = nil
        phase = .showing(file: file, bytes: Self.size(of: file))
    }

    /// The screen went away. A retry's download may still land later.
    func close() {
        generation += 1
        discardFile()
    }

    func load() async {
        generation += 1
        let current = generation
        discardFile()
        worldReady = false
        stats = nil
        phase = .downloading(received: 0, expected: nil)

        guard let apiKey else {
            phase = .failed(.noAPIKey)
            return
        }

        // The SDK takes any URLSession; this one's delegate sees the download task.
        let watcher = DownloadWatcher()
        let session = URLSession(configuration: .default, delegate: watcher, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let client = SplatClient(apiKey: apiKey, session: session)

        let progress = Task { [weak self] in
            while !Task.isCancelled {
                if let bytes = watcher.bytes {
                    self?.showProgress(received: bytes.received, expected: bytes.expected)
                }
                try? await Task.sleep(for: SceneViewerModel.progressInterval)
            }
        }
        defer { progress.cancel() }

        do {
            let downloaded = try await client.downloadScene(id: sceneID, format: spzFormat)

            // A retry outlives its screen: once it closed, or a newer load
            // began, nothing will show this file.
            guard current == generation else {
                try? FileManager.default.removeItem(at: downloaded)
                return
            }

            // The extension is the format the server actually sent.
            guard downloaded.pathExtension == spzFormat.rawValue else {
                try? FileManager.default.removeItem(at: downloaded)
                phase = .failed(.otherFormat(downloaded.pathExtension))
                return
            }

            file = downloaded
            phase = .showing(file: downloaded, bytes: Self.size(of: downloaded))
        } catch is CancellationError {
            // The screen went away mid-download.
        } catch {
            phase = .failed(ViewerFailure(error))
        }
    }

    func handle(_ event: WorldEvent) {
        switch event {
        case .unavailable:
            guard case .showing(_, let bytes) = phase else {
                return
            }
            phase = .undrawable(bytes: bytes)
        case .ready:
            worldReady = true
        case .failed(let message):
            phase = .failed(.unreadable(message))
        case .stats(let latest):
            stats = latest
        }
    }

    /// Deletes the download. Safe while SplatKit still maps it: the mapping
    /// keeps the bytes until it lets go.
    private func discardFile() {
        guard let file else {
            return
        }
        try? FileManager.default.removeItem(at: file)
        self.file = nil
    }

    private func showProgress(received: Int64, expected: Int64?) {
        guard case .downloading = phase else {
            return
        }
        phase = .downloading(received: received, expected: expected)
    }

    private static func size(of file: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

// MARK: - DownloadWatcher

/// Remembers the newest task the SDK starts on its session, to read its bytes.
/// Retries start new tasks, so the newest one is the live one.
final class DownloadWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var task: URLSessionTask?

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { self.task = task }
    }

    /// Bytes received so far, and the total when the response gave a length.
    var bytes: (received: Int64, expected: Int64?)? {
        lock.withLock {
            guard let task else {
                return nil
            }
            // -1 (NSURLSessionTransferSizeUnknown) until a Content-Length arrives.
            let length = task.countOfBytesExpectedToReceive
            let expected: Int64? = length > 0 ? length : nil
            return (received: task.countOfBytesReceived, expected: expected)
        }
    }
}

// MARK: - ViewerFailure

/// Why a scene can't be shown, worded for whoever is testing.
struct ViewerFailure {
    let title: String
    let detail: String

    /// RFC 9110 §15.5.1.
    private static let badRequest = 400

    static let noAPIKey = ViewerFailure(title: "No API key", detail: missingAPIKeyMessage)

    /// The server answered with another format, so this scene has no SPZ.
    static func otherFormat(_ served: String) -> ViewerFailure {
        ViewerFailure(
            title: "This scene has no SPZ",
            detail: "The server sent \(served.isEmpty ? "another format" : served.uppercased()) instead, which SplatKit can't read."
        )
    }

    /// SplatKit refused the file it was given.
    static func unreadable(_ message: String) -> ViewerFailure {
        ViewerFailure(title: "SplatKit couldn't load this scene", detail: message)
    }

    init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    init(_ error: Error) {
        switch error {
        case SplatError.requestFailed(let apiError) where Self.rejectsFormat(apiError):
            self.init(
                title: "SPZ download not available on this server yet",
                detail: "The API doesn't accept format=spz yet. It said: \(apiError.message)"
            )
        case SplatError.notFound(let apiError):
            self.init(
                title: "This scene has no SPZ",
                detail: "\(apiError.message) Scenes processed before SPZ export, or whose SPZ conversion failed, have none."
            )
        case SplatError.unauthorized:
            self.init(title: "API key rejected", detail: "Check SPLAT_API_KEY in Secrets.xcconfig.")
        case let urlError as URLError:
            self.init(title: "Network error", detail: urlError.localizedDescription)
        default:
            self.init(title: "Download failed", detail: error.localizedDescription)
        }
    }

    /// The route's validator answers a format it doesn't know with a 400 that
    /// isn't an API error envelope, so it has no code, and names the field:
    /// "format: Invalid enum value. Expected 'sog' | 'ply', received 'spz'".
    private static func rejectsFormat(_ error: SplatError.APIError) -> Bool {
        error.statusCode == badRequest && error.code == nil && error.message.hasPrefix("format")
    }
}

// MARK: - Small views

/// Bytes downloaded so far, as a bar once the total is known.
private struct DownloadProgress: View {
    let received: Int64
    let expected: Int64?

    var body: some View {
        VStack(spacing: 12) {
            if let expected {
                ProgressView(value: Double(min(received, expected)), total: Double(expected))
                    .frame(maxWidth: 240)
                Text("Downloading SPZ… \(Self.format(received)) of \(Self.format(expected))")
            } else {
                ProgressView()
                Text(received > 0 ? "Downloading SPZ… \(Self.format(received))" : "Requesting SPZ…")
            }
        }
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(.white)
        .tint(.white)
    }

    private static func format(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}

/// A centred message: optional symbol, title and detail.
private struct Notice: View {
    let symbol: String?
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.largeTitle)
            } else {
                ProgressView()
            }
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .tint(.white)
        .padding(32)
    }
}

/// Frame rate and splats drawn, as SplatKit measures them.
private struct StatsLine: View {
    let stats: SplatStats

    var body: some View {
        Text("\(Int(stats.fps.rounded())) fps · \(Self.count(stats.drawnSplatCount)) of \(Self.count(stats.splatCount)) splats")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(.top, 8)
    }

    private static func count(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }
}

/// Reports presses: `onHold(true)` while held, `onHold(false)` on release.
private struct HoldButtonStyle: ButtonStyle {
    let onHold: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .background(.white.opacity(configuration.isPressed ? 0.35 : 0.15), in: Circle())
            .onChange(of: configuration.isPressed) { _, pressed in
                onHold(pressed)
            }
    }
}
