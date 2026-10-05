import SwiftUI
import UIKit
import Splat3D

// MARK: - Splat3D Integration: Recent Scenes
//
// SplatClient.listScenePage lists the account's scenes, newest first. Only a
// complete scene has a model to download, so the list keeps those, each one
// tap from SplatKit's viewer. Each row's thumbnail comes from
// SplatClient.getSceneThumbnail, which sends the API key.

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
                    SceneRow(scene: scene, thumbnails: model.thumbnails)
                }
            }
        }
    }
}

/// One scene: thumbnail, title, age and size, and where the tap goes.
private struct SceneRow: View {
    let scene: SplatScene
    let thumbnails: ThumbnailStore

    private static let thumbnailSize: CGFloat = 56

    var body: some View {
        HStack(spacing: 12) {
            SceneThumbnail(scene: scene, store: thumbnails)
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

// MARK: - SceneThumbnail

/// A scene's thumbnail, loaded with the API key. The grey placeholder shows
/// while it loads, and stays when the scene has none or the load fails.
private struct SceneThumbnail: View {
    let scene: SplatScene
    let store: ThumbnailStore

    @State private var image: UIImage?

    init(scene: SplatScene, store: ThumbnailStore) {
        self.scene = scene
        self.store = store
        // A row scrolled back into view starts with its image, with no
        // flash of the placeholder.
        _image = State(initialValue: store.cached(scene.id))
    }

    var body: some View {
        Color.secondary.opacity(0.2)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            // Runs while the row is on screen. SwiftUI cancels it when the row
            // goes away, and the cancellation stops the request.
            .task(id: scene.id) {
                image = await store.image(for: scene)
            }
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

    private let client: SplatClient?

    /// The rows' thumbnails, loaded through the same client, so with the same key.
    fileprivate let thumbnails: ThumbnailStore

    init() {
        let client = apiKey.map { SplatClient(apiKey: $0) }
        self.client = client
        thumbnails = ThumbnailStore(client: client)
    }

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

// MARK: - ThumbnailStore

/// Loads scene thumbnails with the API key, and keeps the decoded images for
/// as long as the list lives, so scrolling back doesn't fetch them again.
///
/// AsyncImage can't send the key, which the API wants for a private scene's
/// thumbnail. NSCache is thread-safe and SplatClient is Sendable, so the
/// rows' tasks can share one store.
private final class ThumbnailStore: @unchecked Sendable {

    private let client: SplatClient?
    private let images = NSCache<NSString, UIImage>()

    init(client: SplatClient?) {
        self.client = client
    }

    /// The image of a scene loaded before, if memory still holds it.
    func cached(_ sceneID: String) -> UIImage? {
        images.object(forKey: sceneID as NSString)
    }

    /// The scene's thumbnail, from memory or from the API. `nil` when the
    /// scene has none, the request fails or the calling task is cancelled.
    /// Only a loaded image is kept, so a row that failed tries again the next
    /// time it appears.
    func image(for scene: SplatScene) async -> UIImage? {
        if let image = cached(scene.id) {
            return image
        }

        // No thumbnail yet: the request could only answer 404.
        guard scene.thumbnailURL != nil, let client else {
            return nil
        }

        do {
            let data = try await client.getSceneThumbnail(id: scene.id)
            guard let image = UIImage(data: data) else {
                return nil
            }
            images.setObject(image, forKey: scene.id as NSString)
            return image
        } catch {
            return nil
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
