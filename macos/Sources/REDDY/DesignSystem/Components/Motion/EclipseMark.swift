#if os(macOS)
import SwiftUI
import AppKit
import QuartzCore

// The Eclipse symbol in the header: two asymmetrical arcs round a still, rounded play triangle. The arcs turn together once every six seconds (1.5 s of eased motion, 4.5 s of
// rest). Same architecture as the hero drift (`KenBurnsLayer`): a layer-backed view whose one animation runs in the render server, so the app does no work per frame. Unlike it,
// the geometry is built once as static vector layers, one parent layer carries the rotation, and colours are the only thing that ever changes afterwards.
//
// Colours come from the app's accent (`ColorTokens.accent`, passed in by the wrapper); the second arc is the same colour at reduced opacity. Nothing here has a colour of its own.

enum EclipseGeometry {
    /// The canonical square the symbol is drawn in.
    static let canvas: CGFloat = 64
    static let center = CGPoint(x: 32, y: 32)
    static let radius: CGFloat = 25
    static let lineWidth: CGFloat = 4
    /// Degrees. The arcs are 149° and 64° long, with unequal gaps (55° and 92°) between them.
    static let primary: (start: CGFloat, sweep: CGFloat) = (-120, 149)
    static let secondary: (start: CGFloat, sweep: CGFloat) = (84, 64)
    /// The second arc is the accent at this opacity.
    static let secondaryOpacity: CGFloat = 0.5

    static func arc(_ a: (start: CGFloat, sweep: CGFloat)) -> CGPath {
        let p = CGMutablePath()
        let s = a.start * .pi / 180, e = (a.start + a.sweep) * .pi / 180
        p.addArc(center: center, radius: radius, startAngle: s, endAngle: e, clockwise: false)
        return p
    }

    /// M25 20 Q25 18 28 20 L43 30 Q46 32 43 34 L28 44 Q25 46 25 43 Z
    static func play() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 25, y: 20))
        p.addQuadCurve(to: CGPoint(x: 28, y: 20), control: CGPoint(x: 25, y: 18))
        p.addLine(to: CGPoint(x: 43, y: 30))
        p.addQuadCurve(to: CGPoint(x: 43, y: 34), control: CGPoint(x: 46, y: 32))
        p.addLine(to: CGPoint(x: 28, y: 44))
        p.addQuadCurve(to: CGPoint(x: 25, y: 43), control: CGPoint(x: 25, y: 46))
        p.closeSubpath()
        return p
    }
}

enum EclipseMotion {
    static let motion: CFTimeInterval = 1.5
    static let rest: CFTimeInterval = 4.5
    static var cycle: CFTimeInterval { motion + rest }
    static let key = "eclipse"

    /// One keyframe animation for the whole cycle: a full turn with ease-in and ease-out, then a hold. The hold's end value (2π) is the same pose as 0, so the repeat is seamless.
    static func animation() -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        a.values = [NSNumber(value: 0.0), NSNumber(value: Double.pi * 2), NSNumber(value: Double.pi * 2)]
        a.keyTimes = [0, NSNumber(value: motion / cycle), 1]
        a.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear)]
        a.duration = cycle
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        return a
    }
}

/// Layers: root (64×64 canvas, scaled to the view) > orbit (rotates) > two arc shapes; root > play shape (still).
final class EclipseMarkView: NSView {
    let root = CALayer()
    let orbit = CALayer()
    let primaryArc = CAShapeLayer()
    let secondaryArc = CAShapeLayer()
    let playShape = CAShapeLayer()
    private var accent: NSColor?
    private(set) var wantsMotion = false

    override init(frame: NSRect) { super.init(frame: frame); setUp() }
    required init?(coder: NSCoder) { super.init(coder: coder); setUp() }

    private func setUp() {
        wantsLayer = true
        let c = EclipseGeometry.canvas
        root.bounds = CGRect(x: 0, y: 0, width: c, height: c)
        root.anchorPoint = .zero
        root.isGeometryFlipped = true                    // the symbol is specified in y-down coordinates
        orbit.bounds = root.bounds
        orbit.position = EclipseGeometry.center
        for (shape, arc) in [(primaryArc, EclipseGeometry.primary), (secondaryArc, EclipseGeometry.secondary)] {
            shape.path = EclipseGeometry.arc(arc)
            shape.fillColor = nil
            shape.lineWidth = EclipseGeometry.lineWidth
            shape.lineCap = .round
            orbit.addSublayer(shape)
        }
        playShape.path = EclipseGeometry.play()
        root.addSublayer(orbit)
        root.addSublayer(playShape)
        layer?.addSublayer(root)
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let s = min(bounds.width, bounds.height) / EclipseGeometry.canvas
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.position = CGPoint(x: (bounds.width - EclipseGeometry.canvas * s) / 2, y: (bounds.height - EclipseGeometry.canvas * s) / 2)
        root.setAffineTransform(CGAffineTransform(scaleX: s, y: s))
        CATransaction.commit()
    }

    var isAnimating: Bool { orbit.animation(forKey: EclipseMotion.key) != nil }

    /// Applies the colours and the run state. Idempotent: a repeat with the same values does nothing, so SwiftUI may call it whenever it likes.
    func apply(accent new: NSColor, run: Bool) {
        if accent != new { accent = new; applyColors() }
        wantsMotion = run
        syncAnimation()
    }

    /// Only the colours of the existing layers change; no geometry, no animation, no parent invalidation.
    private func applyColors() {
        guard let accent else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            primaryArc.strokeColor = accent.cgColor
            secondaryArc.strokeColor = accent.withAlphaComponent(accent.alphaComponent * EclipseGeometry.secondaryOpacity).cgColor
            playShape.fillColor = accent.cgColor
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }

    // The animation runs only while the view is in a window, shown, and the caller says motion is wanted (the app is live, Reduce Motion and Low Power are off).
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); syncAnimation() }
    override func viewDidHide() { super.viewDidHide(); syncAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); syncAnimation() }

    private func syncAnimation() {
        let should = wantsMotion && window != nil && !isHiddenOrHasHiddenAncestor
        if should {
            if !isAnimating { orbit.add(EclipseMotion.animation(), forKey: EclipseMotion.key) }
        } else if isAnimating {
            orbit.removeAnimation(forKey: EclipseMotion.key)
        }
    }
}

struct EclipseMark: NSViewRepresentable {
    let size: CGFloat
    /// The app is live, the header shows it, and neither Reduce Motion nor Low Power Mode asks for stillness.
    let run: Bool
    @Environment(\.reddyAccent) private var accent

    func makeNSView(context: Context) -> EclipseMarkView { EclipseMarkView(frame: NSRect(x: 0, y: 0, width: size, height: size)) }
    func updateNSView(_ view: EclipseMarkView, context: Context) { view.apply(accent: NSColor(accent), run: run) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EclipseMarkView, context: Context) -> CGSize? { CGSize(width: size, height: size) }
}

enum EclipseLayout {
    static let size: CGFloat = 22
    static let gap: CGFloat = 6
    static var width: CGFloat { size + gap }
}
#endif
