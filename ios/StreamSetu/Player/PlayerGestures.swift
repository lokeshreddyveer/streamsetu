import SwiftUI
import UIKit

/// What the touch layer over the picture reports. Everything is a callback, so the player decides what each gesture does.
struct PlayerGestureActions {
    enum Side { case left, right }
    var tap: () -> Void = {}
    /// A double tap; `fraction` is where across the screen it landed (0 = left edge, 1 = right edge).
    var doubleTap: (_ fraction: CGFloat) -> Void = { _ in }
    var holdChanged: (_ holding: Bool) -> Void = { _ in }
    /// A vertical drag on the left (brightness) or right (volume) third. `delta` is the change as a fraction of the full range, up is positive.
    var adjust: (_ side: Side, _ delta: CGFloat) -> Void = { _, _ in }
    var adjustEnded: () -> Void = {}
    /// A swipe in the middle of the screen on live TV: +1 for the next channel, -1 for the previous.
    var zap: (_ step: Int) -> Void = { _ in }
    /// A drag down from the top of the screen. `ended` is true when the finger lifts.
    var pull: (_ distance: CGFloat, _ ended: Bool) -> Void = { _, _ in }
    var pinchEnded: (_ scale: CGFloat) -> Void = { _ in }
    /// A drag on a zoomed picture moves it. `delta` is the movement since the last report.
    var panVideo: (_ delta: CGSize) -> Void = { _ in }
    /// A horizontal swipe across the middle of a movie or episode. `dx` is how far, in points; `ended` when the finger lifts.
    var scrub: (_ dx: CGFloat, _ ended: Bool) -> Void = { _, _ in }
    var screenWidth: () -> CGFloat = { 400 }
}

/// A transparent UIKit layer that recognises all the player's gestures together. SwiftUI's own gestures cannot combine a single tap, a double
/// tap, a hold, a drag with regions and a pinch reliably. It ignores touches that start at the screen edges, so the system's own edge
/// swipes (Home, Control Center) never trigger anything here.
struct GestureSurface: UIViewRepresentable {
    /// False while the controls are locked: only a tap is reported (to show the unlock button).
    var enabled: Bool
    var isLive: Bool
    /// True while the picture is zoomed in: a drag in the middle then moves the picture instead of changing channel.
    var zoomed = false
    var actions: PlayerGestureActions

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let c = context.coordinator
        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        let hold = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.5
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        for g in [single, double, hold, pan, pinch] as [UIGestureRecognizer] { g.delegate = c; v.addGestureRecognizer(g) }
        v.isAccessibilityElement = false
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: GestureSurface
        private enum Region { case pull, left, right, middle }
        private var region = Region.middle
        private var lastY: CGFloat = 0
        private var lastPoint = CGPoint.zero
        private var scrubbing = false

        init(_ parent: GestureSurface) { self.parent = parent }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let v = g.view else { return true }
            let p = touch.location(in: v), b = v.bounds
            return p.x > 22 && p.x < b.width - 22 && p.y < b.height - 34        // leave the screen edges to the system
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }

        @objc func tap(_ g: UITapGestureRecognizer) { parent.actions.tap() }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard parent.enabled, let v = g.view, v.bounds.width > 0 else { return }
            parent.actions.doubleTap(g.location(in: v).x / v.bounds.width)
        }

        @objc func hold(_ g: UILongPressGestureRecognizer) {
            guard parent.enabled else { return }
            switch g.state {
            case .began: parent.actions.holdChanged(true)
            case .ended, .cancelled, .failed: parent.actions.holdChanged(false)
            default: break
            }
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard parent.enabled, g.state == .ended else { return }
            parent.actions.pinchEnded(g.scale)
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard parent.enabled, let v = g.view else { return }
            let t = g.translation(in: v), b = v.bounds
            switch g.state {
            case .began:
                let start = CGPoint(x: g.location(in: v).x - t.x, y: g.location(in: v).y - t.y)
                if start.y < b.height * 0.14 { region = .pull }
                else if start.x < b.width * 0.3 { region = .left }
                else if start.x > b.width * 0.7 { region = .right }
                else { region = .middle }
                lastY = t.y; lastPoint = CGPoint(x: t.x, y: t.y)
            case .changed:
                switch region {
                case .pull: if t.y > 0, abs(t.y) > abs(t.x) { parent.actions.pull(t.y, false) }
                case .left, .right:
                    let delta = -(t.y - lastY) / max(1, b.height * 0.7)
                    lastY = t.y
                    parent.actions.adjust(region == .left ? .left : .right, delta)
                case .middle:
                    if parent.zoomed {
                        parent.actions.panVideo(CGSize(width: t.x - lastPoint.x, height: t.y - lastPoint.y))
                        lastPoint = CGPoint(x: t.x, y: t.y)
                    } else if !parent.isLive, abs(t.x) > 14, abs(t.x) > abs(t.y) * 1.2 {
                        scrubbing = true
                        parent.actions.scrub(t.x, false)
                    }
                }
            case .ended, .cancelled:
                switch region {
                case .pull: parent.actions.pull(t.y, true)
                case .left, .right: parent.actions.adjustEnded()
                case .middle:
                    if scrubbing { scrubbing = false; parent.actions.scrub(t.x, g.state == .ended); break }
                    guard parent.isLive, !parent.zoomed, g.state == .ended else { break }
                    if abs(t.x) > 80, abs(t.x) > abs(t.y) * 1.3 { parent.actions.zap(t.x < 0 ? 1 : -1) }
                    else if abs(t.y) > 80, abs(t.y) > abs(t.x) * 1.3 { parent.actions.zap(t.y < 0 ? 1 : -1) }
                }
            default: break
            }
        }
    }
}

/// The screen's brightness, adjusted from the player and put back when it closes.
@MainActor enum ScreenBrightness {
    private static var original: CGFloat?

    private static var screen: UIScreen? { (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?.screen }

    static var value: CGFloat {
        get { screen?.brightness ?? 0.5 }
        set {
            if original == nil { original = screen?.brightness }
            screen?.brightness = max(0.02, min(1, newValue))
        }
    }

    static func restore() {
        if let original { screen?.brightness = original }
        original = nil
    }
}
