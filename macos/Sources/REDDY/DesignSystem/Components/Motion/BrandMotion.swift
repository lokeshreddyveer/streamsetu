import SwiftUI
import Observation
#if os(macOS)
import AppKit
#endif

// The branded motion kit: the pieces every screen uses to move the same way. A loader (the television's dot breathing, a thin ribbon arc
// circling it), skeleton shimmer, drawn empty states, success and failure feedback, a sliding selection, and the press and hover feel.
// Everything takes its colours from the active theme (the accent at low opacity for glows), stands still with Reduce Motion (the
// system's or the app's own "Reduce animation"), and stops its loops when it leaves the screen. Shared by the Mac and iPhone/iPad apps.

enum BrandMotion {
    /// Hover and highlight.
    static let quick = Animation.easeOut(duration: 0.12)
    /// Press release, selection and focus.
    static let standard = Animation.spring(response: 0.32, dampingFraction: 0.82)
    /// Sheets, page changes and reveals.
    static let emphasized = Animation.easeOut(duration: 0.38)

    /// The delay for the `index`-th item of a list or grid appearing for the first time: 30 ms apart, and only the first screenful
    /// (`cap` items) is staggered; later items (scrolled to) appear at once. Nil means "no delay, no rise".
    static func staggerDelay(index: Int, step: Double = 0.03, cap: Int = 12) -> Double? {
        guard index >= 0, index < cap else { return nil }
        return Double(index) * step
    }

    /// Reduce Motion: the system setting, or the app's own "Reduce animation".
    static func reduced(_ system: Bool) -> Bool { system || UserDefaults.standard.bool(forKey: DefaultsKey.reduceMotion) }
}

/// The accent the person sees elsewhere: on the Mac the app's own accent, on the iPhone the tint set from the same setting.
struct BrandAccent: DynamicProperty {
    #if os(macOS)
    @Environment(\.reddyAccent) private var accent
    var color: Color { accent }
    #else
    var color: Color { ColorTokens.accent }
    #endif
}

/// Whether the app is in front and on screen, so the endless loops (spinners, shimmers, pulses) can stand still when nobody can see them:
/// the app is in the background, hidden, or every window is covered or minimised. The Mac updates it from AppKit's notifications; on
/// the iPhone and iPad it is always true (those loops stop with the screen instead). Loops read `isLive` in their body.
@MainActor @Observable
final class AppActivity {
    static let shared = AppActivity()
    private(set) var isLive = true
    /// For tests and measurements: pins `isLive` regardless of the app's state.
    var forced: Bool? { didSet { refresh() } }

    #if os(macOS)
    private init() {
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification, NSApplication.didChangeOcclusionStateNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { AppActivity.shared.refresh() } }
        }
        refresh()
    }
    func refresh() {
        let app = NSApplication.shared
        let live = forced ?? (app.isActive && !app.isHidden && app.occlusionState.contains(.visible))
        if live != isLive { isLive = live }
    }
    #else
    private init() {}
    func refresh() { isLive = forced ?? true }
    #endif
}

/// Tracks whether a view is on screen, so its loop can stop when it is not.
private struct OnScreen: ViewModifier {
    @Binding var visible: Bool
    func body(content: Content) -> some View { content.onAppear { visible = true }.onDisappear { visible = false } }
}

// MARK: - Loader

/// The loader for screens and sections: the television's dot breathing, with a thin ribbon arc circling it. Small inline spinners
/// may stay the system's. Still with Reduce Motion (the dot and a quarter arc, at rest).
struct BrandLoader: View {
    var size: CGFloat = 44
    var label: String?
    var tint: Color?
    private let accent = BrandAccent()
    @Environment(\.accessibilityReduceMotion) private var systemReduce
    @State private var visible = false

    var body: some View {
        let still = BrandMotion.reduced(systemReduce)
        let live = AppActivity.shared.isLive
        VStack(spacing: 12) {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: still || !visible || !live)) { context in
                Canvas { ctx, s in draw(&ctx, s, t: still ? 0 : context.date.timeIntervalSinceReferenceDate) }
            }
            .frame(width: size, height: size)
            if let label { Text(label.loc).font(.system(size: 13)).foregroundStyle(ColorTokens.textSecondary) }
        }
        .modifier(OnScreen(visible: $visible))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text((label ?? "Loading").loc))
    }

    private func draw(_ ctx: inout GraphicsContext, _ s: CGSize, t: Double) {
        let c = CGPoint(x: s.width / 2, y: s.height / 2), r = min(s.width, s.height) / 2
        let colour = tint ?? accent.color
        let breathe = 1 + 0.14 * sin(t * 2 * .pi / 1.6)
        // The ring the ribbon runs on, faint.
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r * 0.78, y: c.y - r * 0.78, width: r * 1.56, height: r * 1.56)), with: .color(colour.opacity(0.14)), lineWidth: max(1.5, r * 0.09))
        // The ribbon arc, a little more than a quarter turn, travelling once every 1.1 s.
        var arc = Path()
        let start = Angle.radians(t * 2 * .pi / 1.1)
        arc.addArc(center: c, radius: r * 0.78, startAngle: start, endAngle: start + .degrees(110), clockwise: false)
        ctx.stroke(arc, with: .linearGradient(Gradient(colors: [colour.opacity(0.15), colour]), startPoint: CGPoint(x: c.x - r, y: c.y), endPoint: CGPoint(x: c.x + r, y: c.y)),
                   style: StrokeStyle(lineWidth: max(2, r * 0.12), lineCap: .round))
        // The dot, with its glow breathing.
        let glow = r * 0.42 * breathe
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - glow, y: c.y - glow, width: glow * 2, height: glow * 2)),
                 with: .radialGradient(Gradient(colors: [colour.opacity(0.45), .clear]), center: c, startRadius: 0, endRadius: glow))
        let dot = r * 0.13 * (0.9 + 0.1 * breathe)
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2)), with: .color(Color(hex: 0xF2EEE6)))
    }
}

// MARK: - Skeletons

/// A soft highlight sweeping across a placeholder while its content loads. Still with Reduce Motion; stops when off screen.
struct BrandShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduce
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content.overlay {
            if !BrandMotion.reduced(systemReduce) && AppActivity.shared.isLive {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.09), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.6)
                        .offset(x: phase * g.size.width * 1.6)
                }
                .clipped().allowsHitTesting(false)
                .onAppear { withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 } }
                .onDisappear { phase = -1 }
            }
        }
    }
}

extension View {
    func brandShimmer() -> some View { modifier(BrandShimmer()) }
}

struct SkeletonLine: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous).fill(ColorTokens.card).frame(width: width, height: height).brandShimmer()
            .accessibilityHidden(true)
    }
}

// MARK: - Empty states

/// The drawn art of an empty state: a television tuning (faint snow settling to a dot), a magnifier sweeping, a bookmark, a heart, a
/// tray catching a download, Wi-Fi arcs searching, a warning that shakes once in a while, or a ribbon coiling. It moves slowly while on
/// screen and is still with Reduce Motion.
struct BrandEmptyArt: View {
    enum Kind { case tuning, search, bookmark, heart, downloads, noConnection, error, ribbon }
    let kind: Kind
    var size: CGFloat = 88
    private let accent = BrandAccent()
    @Environment(\.accessibilityReduceMotion) private var systemReduce
    @State private var visible = false

    /// The art for a screen that used an SF Symbol before, so every existing empty state gets drawn art without changing its call.
    init(symbol: String, size: CGFloat = 88) { self.kind = Self.kind(for: symbol); self.size = size }
    init(kind: Kind, size: CGFloat = 88) { self.kind = kind; self.size = size }

    static func kind(for symbol: String) -> Kind {
        switch symbol {
        case let s where s.contains("magnifyingglass") || s.contains("line.3.horizontal.decrease"): .search
        case let s where s.contains("bookmark"): .bookmark
        case let s where s.contains("heart") || s.contains("star"): .heart
        case let s where s.contains("arrow.down") || s.contains("tray"): .downloads
        case let s where s.contains("wifi") || s.contains("network") || s.contains("antenna"): .noConnection
        case let s where s.contains("exclamationmark") || s.contains("xmark"): .error
        case let s where s.contains("list") || s.contains("folder") || s.contains("square.stack") || s.contains("slider"): .ribbon
        default: .tuning
        }
    }

    var body: some View {
        let still = BrandMotion.reduced(systemReduce)
        let live = AppActivity.shared.isLive
        Group {
            if kind == .ribbon {
                RibbonDrawMark(animated: !still && visible && live)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still || !visible || !live)) { context in
                    Canvas { ctx, s in draw(&ctx, s, t: still ? 0 : context.date.timeIntervalSinceReferenceDate) }
                }
            }
        }
        .frame(width: size, height: size)
        .modifier(OnScreen(visible: $visible))
        .accessibilityHidden(true)
    }

    private func draw(_ ctx: inout GraphicsContext, _ s: CGSize, t: Double) {
        // Strokes in the theme's secondary text colour (and the accent for the main shape) with an accent-tinted fill, so the art reads
        // clearly on every theme's page, including Increase Contrast.
        let w = s.width, h = s.height, line = ColorTokens.textSecondary, glow = accent.color
        let stroke = StrokeStyle(lineWidth: max(2, w * 0.035), lineCap: .round, lineJoin: .round)
        switch kind {
        case .tuning:
            // A small television; snow inside it settles into a single dot, every four seconds.
            let body = CGRect(x: w * 0.14, y: h * 0.3, width: w * 0.72, height: h * 0.52)
            ctx.fill(Path(roundedRect: body, cornerRadius: w * 0.1, style: .continuous), with: .color(glow.opacity(0.12)))
            ctx.stroke(Path(roundedRect: body, cornerRadius: w * 0.1, style: .continuous), with: .color(line), style: stroke)
            var ant = Path(); ant.move(to: CGPoint(x: w * 0.4, y: h * 0.12)); ant.addLine(to: CGPoint(x: w * 0.5, y: h * 0.3)); ant.addLine(to: CGPoint(x: w * 0.6, y: h * 0.12))
            ctx.stroke(ant, with: .color(line), style: stroke)
            let cycle = (t / 4).truncatingRemainder(dividingBy: 1), settle = OpeningEasing.smoothstep(cycle / 0.6)
            let screen = body.insetBy(dx: w * 0.08, dy: h * 0.08)
            var snow = ctx
            snow.clip(to: Path(roundedRect: screen, cornerRadius: w * 0.06))
            let frame = Int(t * 12)
            for i in 0..<36 {
                let hx = sin(Double(i * 37 + frame * 13)) * 43758.5453, hy = sin(Double(i * 91 + frame * 7)) * 12543.123
                let x = screen.minX + screen.width * CGFloat(hx - floor(hx)), y = screen.minY + screen.height * CGFloat(hy - floor(hy))
                snow.fill(Path(CGRect(x: x, y: y, width: 2, height: 2)), with: .color(line.opacity(0.5 * (1 - settle))))
            }
            let d = w * 0.03 * (0.6 + 0.4 * settle)
            ctx.fill(Path(ellipseIn: CGRect(x: w / 2 - d * 4, y: body.midY - d * 4, width: d * 8, height: d * 8)), with: .radialGradient(Gradient(colors: [glow.opacity(0.4 * settle), .clear]), center: CGPoint(x: w / 2, y: body.midY), startRadius: 0, endRadius: d * 4))
            ctx.fill(Path(ellipseIn: CGRect(x: w / 2 - d, y: body.midY - d, width: d * 2, height: d * 2)), with: .color(Color(hex: 0xF2EEE6).opacity(settle)))
        case .search:
            // A magnifier sweeping slowly from side to side.
            let x = w * 0.45 + w * 0.12 * CGFloat(sin(t * 2 * .pi / 3)), r = w * 0.2
            ctx.stroke(Path(ellipseIn: CGRect(x: x - r, y: h * 0.42 - r, width: r * 2, height: r * 2)), with: .color(line), style: stroke)
            var handle = Path(); handle.move(to: CGPoint(x: x + r * 0.72, y: h * 0.42 + r * 0.72)); handle.addLine(to: CGPoint(x: x + r * 1.5, y: h * 0.42 + r * 1.5))
            ctx.stroke(handle, with: .color(line), style: StrokeStyle(lineWidth: max(3, w * 0.06), lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: x - r * 0.8, y: h * 0.42 - r * 0.8, width: r * 1.6, height: r * 1.6)), with: .color(glow.opacity(0.2)))
        case .bookmark, .heart:
            // A bookmark (or a heart) that rises and settles gently, its inside lighting in the accent.
            let bob = CGFloat(sin(t * 2 * .pi / 2.6)) * h * 0.03
            var p = Path()
            if kind == .bookmark {
                p.move(to: CGPoint(x: w * 0.32, y: h * 0.2 + bob)); p.addLine(to: CGPoint(x: w * 0.68, y: h * 0.2 + bob))
                p.addLine(to: CGPoint(x: w * 0.68, y: h * 0.8 + bob)); p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.66 + bob))
                p.addLine(to: CGPoint(x: w * 0.32, y: h * 0.8 + bob)); p.closeSubpath()
            } else {
                let cx = w / 2, cy = h * 0.5 + bob, k = w * 0.3
                p.move(to: CGPoint(x: cx, y: cy + k * 0.9))
                p.addCurve(to: CGPoint(x: cx - k, y: cy - k * 0.2), control1: CGPoint(x: cx - k * 0.4, y: cy + k * 0.55), control2: CGPoint(x: cx - k, y: cy + k * 0.3))
                p.addArc(center: CGPoint(x: cx - k * 0.5, y: cy - k * 0.25), radius: k * 0.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                p.addArc(center: CGPoint(x: cx + k * 0.5, y: cy - k * 0.25), radius: k * 0.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                p.addCurve(to: CGPoint(x: cx, y: cy + k * 0.9), control1: CGPoint(x: cx + k, y: cy + k * 0.3), control2: CGPoint(x: cx + k * 0.4, y: cy + k * 0.55))
            }
            ctx.fill(p, with: .color(glow.opacity(0.24 + 0.1 * (1 + sin(t * 2 * .pi / 2.6)) / 2)))
            ctx.stroke(p, with: .color(glow), style: stroke)
        case .downloads:
            // A tray, and an arrow dropping into it again and again.
            var tray = Path()
            tray.move(to: CGPoint(x: w * 0.18, y: h * 0.62)); tray.addLine(to: CGPoint(x: w * 0.18, y: h * 0.8)); tray.addLine(to: CGPoint(x: w * 0.82, y: h * 0.8)); tray.addLine(to: CGPoint(x: w * 0.82, y: h * 0.62))
            ctx.stroke(tray, with: .color(line), style: stroke)
            let fall = OpeningEasing.easeOut((t / 1.8).truncatingRemainder(dividingBy: 1))
            let y = h * 0.14 + h * 0.36 * CGFloat(fall)
            var arrow = Path()
            arrow.move(to: CGPoint(x: w / 2, y: y)); arrow.addLine(to: CGPoint(x: w / 2, y: y + h * 0.22))
            arrow.move(to: CGPoint(x: w * 0.4, y: y + h * 0.13)); arrow.addLine(to: CGPoint(x: w / 2, y: y + h * 0.23)); arrow.addLine(to: CGPoint(x: w * 0.6, y: y + h * 0.13))
            var a = ctx; a.opacity = 1 - 0.7 * fall
            a.stroke(arrow, with: .color(glow), style: stroke)
        case .noConnection:
            // Wi-Fi arcs lighting one after another, as if searching.
            let c = CGPoint(x: w / 2, y: h * 0.74)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - w * 0.04, y: c.y - w * 0.04, width: w * 0.08, height: w * 0.08)), with: .color(line))
            for i in 1...3 {
                var arc = Path()
                arc.addArc(center: c, radius: w * 0.13 * CGFloat(i), startAngle: .degrees(225), endAngle: .degrees(315), clockwise: false)
                let lit = (t * 1.2).truncatingRemainder(dividingBy: 4) >= Double(i) && (t * 1.2).truncatingRemainder(dividingBy: 4) < Double(i) + 1
                ctx.stroke(arc, with: .color(lit ? glow : line.opacity(0.6)), style: stroke)
            }
        case .error:
            // A warning sign that gives a small shake every three seconds.
            let shake = (t / 3).truncatingRemainder(dividingBy: 1) < 0.12 ? sin(t * 60) * w * 0.02 : 0
            var tri = Path()
            tri.move(to: CGPoint(x: w / 2 + shake, y: h * 0.18)); tri.addLine(to: CGPoint(x: w * 0.85 + shake, y: h * 0.8)); tri.addLine(to: CGPoint(x: w * 0.15 + shake, y: h * 0.8)); tri.closeSubpath()
            ctx.fill(tri, with: .color(ColorTokens.warning.opacity(0.12)))
            ctx.stroke(tri, with: .color(ColorTokens.warning.opacity(0.85)), style: stroke)
            var bang = Path(); bang.move(to: CGPoint(x: w / 2 + shake, y: h * 0.4)); bang.addLine(to: CGPoint(x: w / 2 + shake, y: h * 0.6))
            ctx.stroke(bang, with: .color(ColorTokens.warning), style: stroke)
            ctx.fill(Path(ellipseIn: CGRect(x: w / 2 + shake - w * 0.025, y: h * 0.67, width: w * 0.05, height: w * 0.05)), with: .color(ColorTokens.warning))
        case .ribbon:
            break
        }
    }
}

// MARK: - Hero

/// The slow drift of a hero picture: it grows by 3 % over nine seconds after it appears (a new slide starts again), then rests. Still
/// with Reduce Motion.
struct KenBurns: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduce
    @State private var drift = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(drift ? 1.03 : 1, anchor: .center)
            .onAppear { if !BrandMotion.reduced(systemReduce) { withAnimation(.linear(duration: 9)) { drift = true } } }
    }
}

extension View {
    func kenBurns() -> some View { modifier(KenBurns()) }
}

// MARK: - Live

/// A dot with a soft halo that swells and fades every 2.4 s: "now" on the guide's time line, "live" elsewhere. Still with Reduce Motion;
/// the halo stops when the dot leaves the screen.
struct PulsingDot: View {
    var color: Color
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var systemReduce
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .background {
                // The halo exists only while it can be seen: not with Reduce Motion, and not while the app is in the background or covered.
                if !BrandMotion.reduced(systemReduce) && AppActivity.shared.isLive { PulseHalo(color: color, size: size) }
            }
            .accessibilityHidden(true)
    }
}

private struct PulseHalo: View {
    var color: Color
    var size: CGFloat
    @State private var pulse = false
    var body: some View {
        Circle().fill(color.opacity(pulse ? 0 : 0.45)).frame(width: size, height: size).scaleEffect(pulse ? 2.6 : 1)
            .onAppear { withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) { pulse = true } }
    }
}

// MARK: - Progress

/// How much of a progress bar is drawn: 0 at first, then the real fraction, filled in over 0.6 s when the bar appears (at once with
/// Reduce Motion), so "how far you watched" reads as a small motion rather than a static stripe.
struct ProgressFillIn: ViewModifier {
    let fraction: Double
    let draw: (Double) -> AnyView
    @Environment(\.accessibilityReduceMotion) private var systemReduce
    @State private var shown = 0.0
    func body(content: Content) -> some View {
        draw(shown)
            .onAppear {
                if BrandMotion.reduced(systemReduce) { shown = fraction } else { withAnimation(.easeOut(duration: 0.6).delay(0.15)) { shown = fraction } }
            }
            .onChange(of: fraction) { _, f in withAnimation(BrandMotion.standard) { shown = f } }
    }
}

// MARK: - Press

/// The one press feel for any tappable surface (it replaces the five near-identical styles): a little smaller and dimmer while held, springing back. With Reduce Motion (the system setting or
/// the app's own) it only dims, and the tap haptic still plays when asked for. `dim` also lowers the opacity (cards on the iPhone), `haptic` adds the light tap (iPhone).
struct BrandPressStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    var dim: Double = 0
    var haptic = false
    func makeBody(configuration: Configuration) -> some View { BrandPressBody(configuration: configuration, scale: scale, dim: dim, haptic: haptic) }
}

private struct BrandPressBody: View {
    let configuration: ButtonStyle.Configuration
    let scale: CGFloat, dim: Double, haptic: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduce
    var body: some View {
        let still = BrandMotion.reduced(systemReduce)
        let label = configuration.label
            .scaleEffect(configuration.isPressed && !still ? scale : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .opacity(configuration.isPressed ? 1 - dim : 1)
            .animation(still ? .linear(duration: 0.1) : BrandMotion.standard, value: configuration.isPressed)
        if haptic { label.sensoryFeedback(.impact(flexibility: .soft, intensity: 0.55), trigger: configuration.isPressed) { _, pressed in pressed } } else { label }
    }
}

extension ButtonStyle where Self == BrandPressStyle {
    static var brandPress: BrandPressStyle { BrandPressStyle() }
    /// Cards, rows and buttons on the iPhone: dip, dim and a light tap.
    static var press: BrandPressStyle { BrandPressStyle(scale: 0.96, dim: 0.12, haptic: true) }
}

extension View {
    /// Rises a little and fades in the first time it appears, `index` places into a list (only the first screenful is staggered).
    /// With Reduce Motion it only fades.
    func staggeredAppear(_ index: Int) -> some View { modifier(StaggeredAppear(index: index)) }
}

private struct StaggeredAppear: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var systemReduce
    @State private var shown = false
    func body(content: Content) -> some View {
        let delay = BrandMotion.staggerDelay(index: index)
        let still = BrandMotion.reduced(systemReduce)
        content
            .opacity(shown || delay == nil ? 1 : 0)
            .offset(y: shown || delay == nil || still ? 0 : 10)
            .onAppear {
                guard let delay, !shown else { shown = true; return }
                withAnimation(still ? .linear(duration: 0.15) : BrandMotion.emphasized.delay(delay)) { shown = true }
            }
    }
}
