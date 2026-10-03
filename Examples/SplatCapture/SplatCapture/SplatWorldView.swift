import SwiftUI
import UIKit
import simd
import SplatKit

// MARK: - SplatKit Integration: Native Viewer
//
// SplatKit (https://github.com/Xget7/splatkit-ios, MIT) draws Gaussian splats
// with Metal in a UIKit view, SplatMetalView. This file puts it in SwiftUI:
//
//   SwiftUI state ──> updateUIView ──> Coordinator ──> resume/pause, mode, walking
//                                 └──> SplatContainerView ──> flip
//   SplatMetalView ──> SplatViewDelegate ──> Coordinator ──> onEvent ──> SwiftUI
//   pan + pinch on the view ──> Coordinator ──> cameraPose (Orbit mode)
//
// SplatKit's own one-finger drag turns the camera on the spot: that is Look
// mode. It ships no orbit gesture, so Orbit mode places the camera itself.

/// How a drag moves the camera.
enum NavigationMode: String, CaseIterable, Identifiable {
    /// Circle the scene's centre; pinch to move in or out.
    case orbit
    /// Turn on the spot; hold the arrows to move.
    case look

    var id: Self { self }
}

/// What the view tells SwiftUI.
enum WorldEvent {
    /// SplatKit couldn't bring up Metal, so this view will never draw: the
    /// Simulator, a GPU before Apple family 7 (A14, M1), or a failed shader
    /// compile, command queue or buffer.
    case unavailable
    /// The world's first frame is on screen.
    case ready(splats: Int)
    /// SplatKit couldn't read the file, or the GPU refused the world.
    case failed(String)
    /// Frame rate and splat counts, once a second.
    case stats(SplatStats)
}

/// SplatKit's Metal view, with Orbit and Look navigation.
struct SplatWorldView: UIViewRepresentable {

    /// The `.spz` to show. SplatKit maps the file rather than copying it.
    let file: URL
    var mode: NavigationMode
    /// Turn the picture half a turn. See "Which way is up" in the README.
    var flipped: Bool
    /// Scene units per second forward while a move arrow is held; 0 stops.
    var walkSpeed: Float
    /// Bump to put the camera back where it started.
    var resetCount: Int
    /// False while the app is in the background.
    var isActive: Bool
    var onEvent: (WorldEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEvent: onEvent)
    }

    func makeUIView(context: Context) -> SplatContainerView {
        let container = SplatContainerView()

        // Without Metal, every SplatKit call is a no-op and no event ever
        // arrives: waiting for the first frame would wait forever.
        guard container.splatView.isAvailable else {
            context.coordinator.reportUnavailable()
            return container
        }

        context.coordinator.attach(to: container.splatView)
        container.splatView.loadWorld(file: file)
        return container
    }

    func updateUIView(_ container: SplatContainerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onEvent = onEvent
        coordinator.setActive(isActive)
        coordinator.setMode(mode)
        coordinator.setWalkSpeed(walkSpeed)
        coordinator.reset(to: resetCount)
        container.flipped = flipped
    }

    /// SplatKit's lifecycle: `release()` once the view is gone for good.
    static func dismantleUIView(_ container: SplatContainerView, coordinator: Coordinator) {
        coordinator.detach()
        container.splatView.release()
    }
}

// MARK: - SplatContainerView

/// Holds SplatKit's view so it can be turned. SwiftUI sets the frame of the
/// view it hosts, and a frame is undefined under a transform, so the
/// transform goes on this child, laid out by bounds and center instead.
final class SplatContainerView: UIView {

    let splatView = SplatMetalView()

    /// Half a turn on screen. Touches turn with the view, so drags still
    /// follow the picture.
    var flipped = false {
        didSet {
            splatView.transform = flipped ? CGAffineTransform(rotationAngle: .pi) : .identity
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        addSubview(splatView)
    }

    required init?(coder: NSCoder) {
        fatalError("SplatContainerView is built in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        splatView.bounds = CGRect(origin: .zero, size: bounds.size)
        splatView.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

// MARK: - Orbit

/// A camera circling the origin: angles in radians, distance in scene units.
struct Orbit {
    var azimuth: Float
    var elevation: Float
    var distance: Float

    /// Splat3D normalizes scenes so the capture cameras sit about 1 unit from
    /// the origin, their median position: around the subject of an object
    /// capture, mid-room in a walkthrough. Start a little further out.
    static let start = Orbit(azimuth: 0, elevation: 0, distance: 1.5)

    static let distances: ClosedRange<Float> = 0.05...50
    /// Short of SplatKit's 85° pitch limit.
    static let elevations: ClosedRange<Float> = -1.4...1.4

    /// Where the camera stands.
    var position: SIMD3<Float> {
        let horizontal = cos(elevation) * distance
        return SIMD3(horizontal * sin(azimuth), sin(elevation) * distance, horizontal * cos(azimuth))
    }

    /// The camera at `position`, looking at the origin. SplatKit's yaw turns
    /// about +Y from looking down -Z (yawOf and pitchOf in its WalkCamera.cpp).
    var cameraPose: CameraPose {
        let p = position
        let forward = simd_normalize(-p)
        return CameraPose(x: p.x, y: p.y, z: p.z, yaw: atan2(-forward.x, -forward.z), pitch: asin(forward.y))
    }
}

// MARK: - Coordinator

extension SplatWorldView {

    /// Keeps the camera state and forwards SplatKit's callbacks. On the main
    /// actor, like the view it drives.
    @MainActor
    final class Coordinator: NSObject, SplatViewDelegate, UIGestureRecognizerDelegate {

        var onEvent: (WorldEvent) -> Void

        /// Radians the camera circles per point dragged.
        private static let orbitSensitivity: Float = 0.008
        private static let statsInterval: TimeInterval = 1

        private weak var view: SplatMetalView?
        private var orbit = Orbit.start
        private var mode: NavigationMode?
        private var isActive: Bool?
        private var walkSpeed: Float = 0
        private var resetCount = 0
        private var statsTimer: Timer?

        private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))

        init(onEvent: @escaping (WorldEvent) -> Void) {
            self.onEvent = onEvent
        }

        func attach(to view: SplatMetalView) {
            self.view = view
            view.delegate = self
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            pinch.delegate = self
            view.addGestureRecognizer(pan)
            view.addGestureRecognizer(pinch)
            place()
        }

        func detach() {
            statsTimer?.invalidate()
            statsTimer = nil
            view = nil
        }

        /// Tells SwiftUI once this view update is over: makeUIView runs
        /// inside it, where state mustn't change.
        func reportUnavailable() {
            Task {
                onEvent(.unavailable)
            }
        }

        // MARK: SwiftUI state

        /// SplatKit draws only while resumed; pause it in the background.
        func setActive(_ active: Bool) {
            guard active != isActive, let view else {
                return
            }
            isActive = active
            if active {
                view.resume()
            } else {
                view.pause()
            }
        }

        func setMode(_ newMode: NavigationMode) {
            guard newMode != mode, let view else {
                return
            }
            mode = newMode

            // Look mode is SplatKit's own drag; Orbit mode is ours.
            view.touchLookEnabled = newMode == .look
            pan.isEnabled = newMode == .orbit
            pinch.isEnabled = newMode == .orbit

            // Every switch starts still, and before the camera is placed, so
            // no frame walks it off the orbit.
            walkSpeed = 0
            view.setWalkVelocity(forward: 0, right: 0)

            // Back to orbiting from wherever Look mode walked to.
            if newMode == .orbit {
                place()
            }
        }

        func setWalkSpeed(_ speed: Float) {
            guard speed != walkSpeed else {
                return
            }
            walkSpeed = speed
            view?.setWalkVelocity(forward: speed, right: 0)
        }

        func reset(to count: Int) {
            guard count != resetCount else {
                return
            }
            resetCount = count
            orbit = .start
            place()
        }

        // MARK: Orbit gestures

        /// Puts the camera on the orbit. Setting `cameraPose` returns at once;
        /// SplatKit's own `orbit(...)` waits for the render thread on every touch.
        private func place() {
            view?.cameraPose = orbit.cameraPose
        }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            guard let view else {
                return
            }
            let drag = pan.translation(in: view)
            pan.setTranslation(.zero, in: view)

            // A second finger turns the drag into a pinch until it lifts.
            guard pinch.state != .began, pinch.state != .changed else {
                return
            }

            // Drag right and the scene turns right: the camera circles left.
            // Drag down and the camera rises to look down on it.
            orbit.azimuth -= Float(drag.x) * Self.orbitSensitivity
            orbit.elevation = (orbit.elevation + Float(drag.y) * Self.orbitSensitivity).clamped(to: Orbit.elevations)
            place()
        }

        @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
            guard pinch.scale > 0 else {
                return
            }
            // Spread the fingers to move in, proportionally to the distance.
            orbit.distance = (orbit.distance / Float(pinch.scale)).clamped(to: Orbit.distances)
            pinch.scale = 1
            place()
        }

        /// Lets a pinch start while a one-finger drag is under way.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            let pair: Set<UIGestureRecognizer> = [gestureRecognizer, other]
            return pair == [pan, pinch]
        }

        // MARK: SplatViewDelegate
        //
        // SplatKit calls its delegate on the main thread, but its protocol
        // doesn't say so to the compiler: assert it, then act on the main actor.

        nonisolated func splatView(_ view: SplatMetalView, worldFrameReady splatCount: Int) {
            MainActor.assumeIsolated {
                onEvent(.ready(splats: splatCount))
                statsTimer?.invalidate()
                statsTimer = Timer.scheduledTimer(
                    timeInterval: Self.statsInterval,
                    target: self,
                    selector: #selector(publishStats),
                    userInfo: nil,
                    repeats: true
                )
            }
        }

        nonisolated func splatView(_ view: SplatMetalView, worldFailed message: String) {
            MainActor.assumeIsolated {
                onEvent(.failed(message))
            }
        }

        @objc private func publishStats() {
            guard let view else {
                return
            }
            onEvent(.stats(view.readStats()))
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
