import SwiftUI
import Splat3D

// MARK: - Splat3D Integration: Recent Scenes
//
// SplatClient.listScenePage lists the account's scenes, newest first. Only a
// complete scene has a model to download, so the list keeps those, each one
// tap from SplatKit's viewer.

/// The account's latest completed scenes, to view in 3D without capturing.
struct RecentScenesView: View {

    @StateObject private var model = RecentScenesModel()

    var body: some View {
        content
            .navigationTitle("Recent Scenes")
            .task { await model.load() }
            .refreshable { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("Loading scenes…")

        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load scenes", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    Task { await model.load() }
                }
            }

        case .loaded(let scenes) where scenes.isEmpty:
            ContentUnavailableView {
                Label("No completed scenes", systemImage: "cube.transparent")
            } description: {
                Text("Capture one, or process one at splat-3d.com.")
            } actions: {
                Button("Refresh") {
                    Task { await model.load() }
                }
            }

        case .loaded(let scenes):
            List(scenes) { scene in
                NavigationLink(value: Route.viewer(sceneID: scene.id, title: scene.displayTitle)) {
                    SceneRow(scene: scene)
                }
            }
        }
    }
}

/// One scene: thumbnail, title, age and size, and where the tap goes.
private struct SceneRow: View {
    let scene: SplatScene

    private static let thumbnailSize: CGFloat = 56

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnails need no API key, so AsyncImage can fetch them.
            AsyncImage(url: scene.thumbnailURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(scene.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("View in 3D")
                .font(.subheadline)
                .foregroundStyle(.tint)
        }
    }

    /// "2 days ago · 1.9M splats".
    private var details: String {
        let age = scene.createdAt.formatted(.relative(presentation: .named))
        guard let count = scene.numGaussians else {
            return age
        }
        return "\(age) · \(count.formatted(.number.notation(.compactName))) splats"
    }
}

// MARK: - RecentScenesModel

@MainActor
final class RecentScenesModel: ObservableObject {

    enum State {
        case loading
        case loaded([SplatScene])
        case failed(String)
    }

    @Published private(set) var state = State.loading

    /// The API's largest page: recent enough, in one request.
    private static let pageSize = 100

    private let client = apiKey.map { SplatClient(apiKey: $0) }

    func load() async {
        guard let client else {
            state = .failed(missingAPIKeyMessage)
            return
        }

        do {
            let page = try await client.listScenePage(limit: Self.pageSize)
            state = .loaded(page.scenes.filter(\.isComplete))
        } catch is CancellationError {
            // The list went away, or a refresh replaced this load.
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

extension SplatScene {
    /// The title, or a stand-in for scenes without one.
    var displayTitle: String {
        guard let title, !title.isEmpty else {
            return "Untitled scene"
        }
        return title
    }
}
