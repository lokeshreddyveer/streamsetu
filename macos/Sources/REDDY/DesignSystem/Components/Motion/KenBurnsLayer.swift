#if os(macOS)
import SwiftUI
import AppKit
import QuartzCore

// The Mac hero drift as a Core Animation layer animation. SwiftUI animating a scale re-renders the hosting view every frame (a full
// layout pass of the window's view tree at 60 Hz); a CABasicAnimation on a layer runs on the render server and costs the app nothing
// per frame. Same look as the SwiftUI version the iPhone keeps: 3 % growth, linear, nine seconds, then rest; plus a hair of sideways
// drift. Still with Reduce Motion (the system's or the app's own "Reduce animation").

enum KenBurnsMotion {
    static let duration: CFTimeInterval = 9
    static let endScale: CGFloat = 1.03
    /// The sideways drift at the end, as a fraction of the width. Half of what the growth leaves spare on each side, so no edge shows.
    static let driftFraction: CGFloat = (endScale - 1) / 2 * 0.5
    static let key = "kenBurns"

    static func animation(width: CGFloat) -> CAAnimationGroup {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1; scale.toValue = endScale
        let drift = CABasicAnimation(keyPath: "transform.translation.x")
        drift.fromValue = 0; drift.toValue = -width * driftFraction
        let group = CAAnimationGroup()
        group.animations = [scale, drift]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .linear)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        return group
    }
}

/// A layer-backed view that shows one picture, aspect-filled, and runs the drift on its picture layer.
final class KenBurnsLayerView: NSView {
    /// The layer holding the picture; the animation runs on it.
    let artLayer = CALayer()
    private(set) var animated = true
    private var fadeIn = false

    override init(frame: NSRect) { super.init(frame: frame); setUp() }
    required init?(coder: NSCoder) { super.init(coder: coder); setUp() }

    private func setUp() {
        wantsLayer = true
        layer?.masksToBounds = true
        artLayer.contentsGravity = .resizeAspectFill
        artLayer.masksToBounds = true
        artLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(artLayer)
    }

    var isAnimating: Bool { artLayer.animation(forKey: KenBurnsMotion.key) != nil }

    func configure(image: CGImage?, animated: Bool, fadeIn: Bool) {
        self.animated = animated; self.fadeIn = fadeIn
        let had = artLayer.contents != nil
        artLayer.contents = image
        if image != nil, !had, fadeIn {
            let f = CABasicAnimation(keyPath: "opacity"); f.fromValue = 0; f.toValue = 1; f.duration = 0.35
            artLayer.add(f, forKey: "fade")
        }
        syncAnimation(restart: false)
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        artLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        artLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        // The drift's sideways distance was set for the width at the start; a resize leaves the running animation alone (it stays inside the spare edge).
        if window != nil, !isAnimating { syncAnimation(restart: false) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        artLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        artLayer.contentsScale = window?.backingScaleFactor ?? 2
        if window != nil { syncAnimation(restart: true) } else { artLayer.removeAnimation(forKey: KenBurnsMotion.key) }
    }

    private func syncAnimation(restart: Bool) {
        guard window != nil, animated, bounds.width > 0 else { artLayer.removeAnimation(forKey: KenBurnsMotion.key); return }
        if isAnimating, !restart { return }
        artLayer.add(KenBurnsMotion.animation(width: bounds.width), forKey: KenBurnsMotion.key)
    }
}

private struct KenBurnsRepresentable: NSViewRepresentable {
    let image: CGImage?
    let animated: Bool
    let fadeIn: Bool
    func makeNSView(context: Context) -> KenBurnsLayerView { KenBurnsLayerView(frame: .zero) }
    func updateNSView(_ view: KenBurnsLayerView, context: Context) { view.configure(image: image, animated: animated, fadeIn: fadeIn) }
}

/// A hero picture that loads like `ArtworkImage` (the app's cache, aspect fill, nothing shown until it arrives) and drifts on a layer.
struct KenBurnsArtwork: View {
    let url: String?
    var kind: ArtworkKind = .backdrop
    @Environment(\.artwork) private var artwork
    @Environment(\.accessibilityReduceMotion) private var systemReduce
    @State private var loaded: CGImage?
    @State private var loadedURL: String?
    @State private var fades = false

    private var image: CGImage? {
        if loadedURL == url, let loaded { return loaded }
        return url.nilIfEmpty == nil ? nil : artwork?.cachedImage(url, kind: kind)
    }

    var body: some View {
        KenBurnsRepresentable(image: image, animated: !BrandMotion.reduced(systemReduce), fadeIn: fades)
            .task(id: url) {
                guard let artwork, url.nilIfEmpty != nil else { loaded = nil; loadedURL = nil; return }
                if let hit = artwork.cachedImage(url, kind: kind) { fades = false; loaded = hit; loadedURL = url; return }
                loaded = nil; loadedURL = nil; fades = true
                let img = await artwork.image(url, kind: kind)
                if Task.isCancelled { return }
                loaded = img; loadedURL = url
            }
    }
}
#endif
