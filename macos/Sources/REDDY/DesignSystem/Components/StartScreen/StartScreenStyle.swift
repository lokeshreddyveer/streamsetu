import SwiftUI
import AppKit

/// Colours, surfaces and motion shared by the welcome screen and the add-connection form.
///
/// The first-run welcome appears before the person has chosen a theme, so it uses the fixed brand palette (dark backdrop, teal).
/// The same form opened from inside the app (the Add Source sheet) follows the active theme: its surfaces, text, focus and primary
/// button use the theme tokens and the accent, and glows are the accent at low opacity. Only the brand symbol and the tile icon art
/// keep their own colours everywhere.
enum StartStyle {
    static let base = Color(hex: 0x05080C)
    /// Brand teal: tile icon art, and on the welcome the hover hairline, glows and the primary button.
    static let teal = Color(hex: 0x3CC6D6)
    static let glowTeal = Color(hex: 0x1FA7B8)
    static let glowSilver = Color(hex: 0x8FA7C0)
    static let radius: CGFloat = 16

    private static var contrast: Bool { ThemeStore.state.highContrast }

    static var textPrimary: Color { ColorTokens.textPrimary }
    /// On the brand backdrop the theme's secondary colour is used, but never darker than #9AA4AE, so it stays readable on the dark
    /// backdrop (WCAG AA). Inside a theme it is the theme's own colour.
    static func textSecondary(_ branded: Bool) -> Color { branded ? readable(ThemeStore.palette.textSecondary) : ColorTokens.textSecondary }
    /// Quiet lines (the legal line). Some themes' tertiary colour is too dark for small text on the brand backdrop, so it gets the same
    /// floor there; inside a theme the secondary colour is used, as small text in the tertiary colour is too faint in several themes.
    static func textTertiary(_ branded: Bool) -> Color { branded ? readable(ThemeStore.palette.textTertiary) : ColorTokens.textSecondary }

    /// The colour of hover hairlines and glows: teal on the welcome, the accent inside a theme.
    static func glow(_ branded: Bool, accent: Color) -> Color { branded ? teal : accent }

    static func surfaceFill(_ branded: Bool, lit: Bool) -> Color {
        branded ? Color.white.opacity(lit ? 0.09 : 0.05) : (lit ? ColorTokens.elevated : ColorTokens.card.opacity(0.85))
    }
    static func surfaceEdge(_ branded: Bool) -> Color {
        branded ? Color.white.opacity(contrast ? 0.35 : 0.10) : ColorTokens.borderStrong
    }
    static func fieldFill(_ branded: Bool) -> Color { branded ? Color.black.opacity(0.28) : ColorTokens.surface }

    /// True for light accents (yellow, lime, pale blue) where white text would be hard to read on the button, so it gets dark text.
    static func isLight(_ color: Color) -> Bool {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return false }
        func channel(_ v: CGFloat) -> Double { let d = Double(v); return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent) > 0.4
    }

    private static func readable(_ hex: UInt32) -> Color {
        if contrast { return ColorTokens.textSecondary }
        let floor: UInt32 = 0x9AA4AE
        return luminance(hex) >= luminance(floor) ? Color(hex: hex) : Color(hex: floor)
    }

    private static func luminance(_ hex: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }
}

private struct StartBrandedKey: EnvironmentKey { static let defaultValue = false }
private struct StartMotionKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    /// True on the first-run welcome, which uses the brand palette; false where the form follows the active theme.
    var startBranded: Bool { get { self[StartBrandedKey.self] } set { self[StartBrandedKey.self] = newValue } }
    /// False while the start screen's window is hidden, or when Reduce Motion is on: the looping animations then stand still.
    var startMotion: Bool { get { self[StartMotionKey.self] } set { self[StartMotionKey.self] = newValue } }
}

/// Decides whether the start screens may move: not with Reduce Motion (the system's or the app's own setting), and not while the
/// window is hidden or minimised, so an idle welcome screen costs nothing.
struct StartMotionGate: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduce
    @Environment(\.container) private var container
    @State private var visible = true

    func body(content: Content) -> some View {
        content
            .environment(\.startMotion, visible && !systemReduce && !(container?.settings.reduceMotion ?? false))
            .background(WindowVisibilityReader(visible: $visible).frame(width: 0, height: 0))
    }
}

/// Reports whether the hosting window is on screen (not minimised, hidden or fully covered).
private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> ProbeView { ProbeView(onChange: { v in if visible != v { visible = v } }) }
    func updateNSView(_ view: ProbeView, context: Context) { view.onChange = { v in if visible != v { visible = v } } }

    final class ProbeView: NSView {
        var onChange: (Bool) -> Void
        private var observer: NSObjectProtocol?
        init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        // The observer is removed when the view leaves its window (viewDidMoveToWindow runs with no window then).
        private func report() { onChange(window.map { $0.occlusionState.contains(.visible) } ?? false) }
    }
}

/// The dark backdrop behind the welcome screen: a near-black base, a slow aurora (a teal glow behind the TV symbol and a faint
/// silver-blue one towards the opposite top corner, drifting on long loops), a faint ribbon of light that sweeps across every
/// eight seconds, and a gentle vignette. No images. Still when motion is off.
struct StartBackdrop: View {
    /// Where the teal glow rests, as a fraction of the screen (it follows the symbol).
    var glowCenter = UnitPoint(x: 0.24, y: 0.36)
    @Environment(\.startMotion) private var motion

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !motion)) { context in
                let t = motion ? context.date.timeIntervalSinceReferenceDate : 0
                layers(size: geo.size, t: t)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func layers(size: CGSize, t: Double) -> some View {
        let short = min(size.width, size.height)
        let long = max(size.width, size.height)
        // The glows drift on 24 s and 29 s loops; the amounts are small so the text over them keeps its contrast.
        let a = t * 2 * .pi
        let teal = UnitPoint(x: glowCenter.x + 0.035 * sin(a / 24), y: glowCenter.y + 0.03 * cos(a / 24))
        let silver = UnitPoint(x: 1 - glowCenter.x * 0.2 + 0.04 * sin(a / 29 + 1), y: 0.02 * cos(a / 29))
        let breathe = 1 + 0.06 * sin(a / 19)
        return ZStack {
            StartStyle.base
            RadialGradient(colors: [StartStyle.glowTeal.opacity(0.18), StartStyle.glowTeal.opacity(0.06), .clear],
                           center: teal, startRadius: 0, endRadius: short * 0.69 * breathe)
            RadialGradient(colors: [StartStyle.glowSilver.opacity(0.07), .clear], center: silver, startRadius: 0, endRadius: short * 0.7)
            ribbon(size: size, t: t)
            RadialGradient(colors: [.clear, .black.opacity(0.45)], center: .center, startRadius: short * 0.45, endRadius: long * 0.78)
        }
    }

    /// A soft diagonal band of light that crosses the screen in about 2.6 s, then rests until the next 8 s cycle.
    private func ribbon(size: CGSize, t: Double) -> some View {
        let cycle = t.truncatingRemainder(dividingBy: 8)
        let progress = min(1, cycle / 2.6)
        let visible = t > 0 && cycle < 2.6
        let width = size.width * 0.5
        return LinearGradient(colors: [.clear, StartStyle.glowTeal.opacity(0.05), Color.white.opacity(0.035), StartStyle.glowTeal.opacity(0.05), .clear],
                              startPoint: .leading, endPoint: .trailing)
            .frame(width: width, height: size.height * 2)
            .rotationEffect(.degrees(24))
            .blur(radius: 30)
            .offset(x: -size.width * 0.5 - width + (size.width * 2 + width) * progress)
            .opacity(visible ? sin(progress * .pi) : 0)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }
}

/// A start-screen surface. Branded: white at 5% with a 10% hairline. Inside a theme: the theme's card colour and border. Hovered,
/// it lifts: the fill brightens, the hairline takes the glow colour and a soft glow grows under it. Keyboard focus draws a ring in
/// the accent, inside the edge so a scroll view or grid around it never clips it.
struct StartSurface: ViewModifier {
    var hovered = false
    var focused = false
    var radius = StartStyle.radius
    @Environment(\.reddyAccent) private var accent
    @Environment(\.startBranded) private var branded

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let lit = hovered || focused
        let glow = StartStyle.glow(branded, accent: accent)
        content
            .background(shape.fill(StartStyle.surfaceFill(branded, lit: lit)))
            .overlay(shape.strokeBorder(focused ? accent : (hovered ? glow.opacity(0.6) : StartStyle.surfaceEdge(branded)), lineWidth: focused ? 2 : 1))
            .shadow(color: glow.opacity(lit ? (branded ? 0.22 : 0.18) : 0), radius: lit ? 16 : 6, y: lit ? 4 : 0)
            .animation(.easeOut(duration: 0.12), value: lit)
    }
}

/// The start screens' primary button (Connect). On the welcome it is brand teal; inside a theme it is the accent. White text, a
/// glow that grows on hover, a soft light sweep across the fill every four seconds while idle, the press spring of the tiles, and a
/// ring in the accent for keyboard focus.
struct StartPrimaryButtonStyle: ButtonStyle {
    /// While busy the button is disabled but keeps its full colour, so "Connecting…" stays readable.
    var busy = false
    func makeBody(configuration: Configuration) -> some View { StartPrimaryButtonBody(configuration: configuration, busy: busy) }
}

private struct StartPrimaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let busy: Bool
    @Environment(\.isEnabled) private var isEnabled
    private var enabled: Bool { isEnabled || busy }
    @Environment(\.isFocused) private var focused
    @Environment(\.reddyAccent) private var accent
    @Environment(\.startBranded) private var branded
    @Environment(\.startMotion) private var motion
    @State private var hovering = false

    var body: some View {
        let lit = enabled && hovering
        let fill = branded ? StartStyle.glowTeal : accent
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 26).padding(.vertical, 10)
            // Disabled, the fill fades, so the label turns light grey on every accent to stay readable.
            .foregroundStyle(!enabled ? Color.white.opacity(0.7) : (branded || !StartStyle.isLight(accent) ? Color.white : Color(hex: 0x0B0D12)))
            .background(Capsule().fill(fill.opacity(enabled ? 1 : 0.35)))
            .overlay(Capsule().fill(LinearGradient(colors: [Color.white.opacity(lit ? 0.2 : 0.14), .clear], startPoint: .top, endPoint: .center)).allowsHitTesting(false))
            .overlay { if isEnabled && motion { sweep } }
            .overlay(Capsule().strokeBorder(focused ? StartStyle.textPrimary : Color.white.opacity(0.18), lineWidth: focused ? 2 : 1))
            .shadow(color: fill.opacity(enabled ? (lit ? 0.5 : 0.25) : 0), radius: lit ? 16 : 9, y: lit ? 5 : 3)
            .scaleEffect(configuration.isPressed && motion ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: lit)
            .animation(motion ? .spring(response: 0.32, dampingFraction: 0.82) : .linear(duration: 0.1), value: configuration.isPressed)
    }

    /// A narrow band of light that crosses the button in 0.9 s, once every four seconds.
    private var sweep: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4)
                let p = min(1, cycle / 0.9)
                LinearGradient(colors: [.clear, Color.white.opacity(0.32), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.35)
                    .rotationEffect(.degrees(18))
                    .offset(x: -geo.size.width * 0.4 + geo.size.width * 1.45 * p)
                    .opacity(cycle < 0.9 ? 1 : 0)
            }
        }
        .clipShape(Capsule())
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

/// A small spinning ring for busy buttons ("Connecting…"); a still ring when motion is off.
struct StartBusyRing: View {
    @Environment(\.startMotion) private var motion
    @State private var spinning = false

    var body: some View {
        Circle().trim(from: 0, to: 0.7)
            .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear { if motion { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinning = true } } }
            .accessibilityHidden(true)
    }
}

/// A short horizontal shake, used on the form card when connecting fails.
struct StartShake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 7 * sin(animatableData * .pi * 4), y: 0))
    }
}

extension View {
    func startSurface(hovered: Bool = false, focused: Bool = false, radius: CGFloat = StartStyle.radius) -> some View {
        modifier(StartSurface(hovered: hovered, focused: focused, radius: radius))
    }

    /// Shows the pointing-hand cursor while the pointer is over a clickable tile.
    func startPointingHand() -> some View {
        onHover { inside in if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
    }

    /// Rises 14pt and fades in when it appears, after `delay` seconds. With motion off it only fades, without moving.
    func startRiseIn(delay: Double = 0) -> some View { modifier(StartRiseIn(delay: delay)) }

    /// Lets the start screen's looping animations run only while they should (see StartMotionGate).
    func startMotionGate() -> some View { modifier(StartMotionGate()) }
}

private struct StartRiseIn: ViewModifier {
    let delay: Double
    @Environment(\.startMotion) private var motion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || !motion ? 0 : 14)
            .onAppear {
                withAnimation(motion ? .easeOut(duration: 0.45).delay(delay) : .linear(duration: 0.12)) { shown = true }
            }
    }
}

/// How a tile's icon moves when the tile is hovered, focused or pressed (and once when it first appears).
enum StartIconMotion {
    /// A single hop (chain link, key, document, play button).
    case bounce
    /// A slow pulse while active (media server rack, set-top box status light).
    case pulse
    /// Radio waves rippling outward while active (tuner).
    case ripple
}

/// A symbol in a rounded square with a teal-to-transparent wash, as used on the tiles and the form header. The icon art keeps its
/// teal in every theme. It animates while `active`, and once when `trigger` changes; it stays still when motion is off.
struct StartIconTile: View {
    let symbol: String
    var size: CGFloat = 44
    var motionKind: StartIconMotion = .bounce
    var active = false
    var trigger = 0
    @Environment(\.startMotion) private var motion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        icon
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(StartStyle.teal)
            .frame(width: size, height: size)
            .background(shape.fill(LinearGradient(colors: [StartStyle.teal.opacity(active ? 0.34 : 0.26), StartStyle.teal.opacity(0.02)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(shape.strokeBorder(StartStyle.teal.opacity(active ? 0.4 : 0.22), lineWidth: 1))
            .animation(.easeOut(duration: 0.12), value: active)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var icon: some View {
        let image = Image(systemName: symbol)
        switch motionKind {
        case .bounce:
            image.symbolEffect(.bounce, options: .speed(1.2), value: motion ? trigger + (active ? 1 : 0) : 0)
        case .pulse:
            image.symbolEffect(.pulse, options: .repeating, isActive: motion && active)
                .symbolEffect(.bounce, value: motion ? trigger : 0)
        case .ripple:
            image.symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: motion && active)
                .symbolEffect(.bounce, value: motion ? trigger : 0)
        }
    }
}

/// A chooser between a tile's kinds (Plex, Jellyfin, Emby). The selected pill slides between the options.
struct StartSegmented<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    @Environment(\.reddyAccent) private var accent
    @Environment(\.startBranded) private var branded
    @Environment(\.startMotion) private var motion
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let selected = item == selection
                Button {
                    withAnimation(motion ? .spring(response: 0.32, dampingFraction: 0.82) : nil) { selection = item }
                } label: {
                    Text(title(item).loc).font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? StartStyle.textPrimary : StartStyle.textSecondary(branded))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selected {
                                Capsule().fill(StartStyle.glow(branded, accent: accent).opacity(0.22))
                                    .overlay(Capsule().strokeBorder(StartStyle.glow(branded, accent: accent).opacity(0.55)))
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.brandPress)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(StartStyle.fieldFill(branded)))
        .overlay(Capsule().strokeBorder(StartStyle.surfaceEdge(branded)))
    }
}
