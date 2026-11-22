import SwiftUI

/// Sizes and the fixed brand colours of the start screens.
enum StartLook {
    /// Phone corner radius for the paste field, the tiles and the form card.
    static let radius: CGFloat = 14
    /// Tile icon art keeps its own colour in every theme, like the brand symbol.
    static let teal = Color(hex: 0x3CC6D6)
}

/// The colours of the start screens. The first-run welcome uses the brand's own (it comes before any theme choice); the Add Playlist
/// sheet opened from inside the app follows the active theme, with the theme's accent at low opacity for the glows.
struct StartPalette {
    var base: Color
    var glow: Color
    var glow2: Color
    /// Focus rings, the lit hairline and the press glow.
    var focus: Color
    var fill: Color
    var fillLit: Color
    var hairline: Color
    var text: Color
    var textSecondary: Color
    /// The darker well behind a text field.
    var well: Color

    static let brand = StartPalette(
        base: Color(hex: 0x05080C), glow: Color(hex: 0x1FA7B8), glow2: Color(hex: 0x8FA7C0), focus: Color(hex: 0x3CC6D6),
        fill: .white.opacity(0.05), fillLit: .white.opacity(0.09), hairline: .white.opacity(0.1),
        text: Color(hex: 0xF4F6F8), textSecondary: Color(hex: 0xA9B3BD), well: .black.opacity(0.25))

    /// Read each time it is used, so a theme changed while the sheet is open is followed (the tokens include Increase Contrast).
    static var theme: StartPalette {
        StartPalette(
            base: ColorTokens.background, glow: ColorTokens.accentDefault, glow2: ColorTokens.textSecondary, focus: ColorTokens.accentDefault,
            fill: ColorTokens.card, fillLit: ColorTokens.elevated, hairline: ColorTokens.lineStrong,
            text: ColorTokens.textPrimary, textSecondary: ColorTokens.textSecondary, well: ColorTokens.surface)
    }
}

private struct StartPaletteKey: EnvironmentKey { static let defaultValue = StartPalette.brand }
extension EnvironmentValues {
    var startPalette: StartPalette { get { self[StartPaletteKey.self] } set { self[StartPaletteKey.self] = newValue } }
}

/// What the Add Playlist sheet starts from when the welcome screen opened it: a tile's type, or an address typed in its paste field.
enum AddPreset: Equatable {
    case kind(AddSourceKind)
    case pasted(String)
}

/// The connection types as the person sees them. Each tile stands for one or more of the app's existing kinds; a tile with several
/// (media servers, tuners) opens the form with a small chooser between them. Only kinds this build offers are shown.
enum StartTile: CaseIterable, Identifiable {
    case playlistLink, xtream, mediaServer, tuner, playlistFile, stalker, stream
    var id: Self { self }

    var title: String {
        switch self {
        case .playlistLink: "Playlist link"
        case .xtream: "Xtream Codes"
        case .mediaServer: "Media server"
        case .tuner: "TV tuner or receiver"
        case .playlistFile: "Playlist file"
        case .stalker: "Stalker portal"
        case .stream: "Single stream"
        }
    }

    var subtitle: String {
        switch self {
        case .playlistLink: "An M3U or M3U8 address"
        case .xtream: "Server, user name and password"
        case .mediaServer: "Plex, Jellyfin or Emby"
        case .tuner: "HDHomeRun, TVHeadend or Enigma2"
        case .playlistFile: "An M3U file on this device"
        case .stalker: "Portal address and MAC"
        case .stream: "One stream address"
        }
    }

    var symbol: String {
        switch self {
        case .playlistLink: "link"
        case .xtream: "server.rack"
        case .mediaServer: "play.rectangle.on.rectangle"
        case .tuner: "antenna.radiowaves.left.and.right"
        case .playlistFile: "folder"
        case .stalker: "tv.badge.wifi"
        case .stream: "waveform.path"
        }
    }

    /// The kinds behind the tile that this build offers, in the order the chooser shows them.
    var kinds: [AddSourceKind] {
        let all: [AddSourceKind] = switch self {
        case .playlistLink: [.m3uURL]
        case .xtream: [.xtream]
        case .mediaServer: [.plex, .jellyfin, .emby]
        case .tuner: [.hdhomerun, .tvheadend, .enigma2]
        case .playlistFile: [.m3uFile]
        case .stalker: [.stalker]
        case .stream: [.stream]
        }
        return all.filter { AddSourceKind.offered.contains($0) }
    }

    static var offered: [StartTile] { allCases.filter { !$0.kinds.isEmpty } }
    static func tile(for kind: AddSourceKind) -> StartTile { allCases.first { $0.kinds.contains(kind) } ?? .playlistLink }
}

/// True while the view is on screen and the app is in front; the slow loops below stop otherwise, so they cost nothing in the background.
private struct LiveLoop: ViewModifier {
    @Binding var running: Bool
    @Environment(\.scenePhase) private var phase
    @State private var onScreen = false
    func body(content: Content) -> some View {
        content
            .onAppear { onScreen = true; running = phase == .active }
            .onDisappear { onScreen = false; running = false }
            .onChange(of: phase) { _, p in running = onScreen && p == .active }
    }
}

/// The backdrop: the base colour, two glows drifting on long loops, a faint ribbon of light sweeping across every 8 seconds, and a
/// vignette. Very low opacity, so text contrast does not change. With Reduce Motion it stands still. `glowAt` is where the main glow rests.
struct StartBackdrop: View {
    var glowAt = UnitPoint(x: 0.5, y: 0.16)
    @Environment(\.startPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var running = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !running)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            GeometryReader { g in
                let short = min(g.size.width, g.size.height)
                let drift = UnitPoint(x: glowAt.x + 0.06 * sin(t * 2 * .pi / 26), y: glowAt.y + 0.04 * cos(t * 2 * .pi / 22))
                let far = UnitPoint(x: (glowAt.x < 0.5 ? 0.95 : 0.05) + 0.05 * sin(t * 2 * .pi / 30), y: 0.02 + 0.04 * sin(t * 2 * .pi / 24))
                ZStack {
                    palette.base
                    RadialGradient(colors: [palette.glow.opacity(0.18), .clear], center: drift, startRadius: 0, endRadius: short * 0.88)
                    RadialGradient(colors: [palette.glow2.opacity(0.07), .clear], center: far, startRadius: 0, endRadius: short * 0.9)
                    if !reduceMotion { ribbon(t: t, size: g.size) }
                    RadialGradient(colors: [.clear, .black.opacity(0.45)], center: .center, startRadius: short * 0.45, endRadius: max(g.size.width, g.size.height) * 0.8)
                }
            }
        }
        .modifier(LiveLoop(running: $running))
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// A soft, slightly curved band of light that crosses the screen for two seconds out of every eight.
    private func ribbon(t: TimeInterval, size: CGSize) -> some View {
        let cycle = t.truncatingRemainder(dividingBy: 8) / 2.4          // 0...1 while it crosses, then rests off screen
        let x = -0.4 + 1.8 * min(cycle, 1.2)
        return Capsule()
            .fill(LinearGradient(colors: [.clear, palette.glow.opacity(0.07), .white.opacity(0.035), palette.glow.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing))
            .frame(width: size.width * 0.35, height: max(size.width, size.height) * 1.6)
            .rotationEffect(.degrees(24))
            .blur(radius: 30)
            .position(x: size.width * x, y: size.height * 0.45)
            .opacity(cycle < 1.15 ? 1 : 0)
    }
}

/// The brand symbol on the welcome: it floats up and down by a few points over six seconds, and a soft sheen passes over it every seven.
struct FloatingBrandSymbol: View {
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var running = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !running)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let sheen = (t.truncatingRemainder(dividingBy: 7)) / 1.6           // 0...1 while it passes, then waits
            let symbol = Image("BrandSymbol").resizable().scaledToFit()
            symbol
                .overlay {
                    if !reduceMotion && sheen < 1 {
                        GeometryReader { g in
                            LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: g.size.width * 0.35)
                                .rotationEffect(.degrees(20))
                                .offset(x: g.size.width * (-0.5 + 1.6 * sheen))
                        }
                        .mask(symbol)
                        .blendMode(.plusLighter)
                    }
                }
                .frame(width: size, height: size)
                .offset(y: reduceMotion ? 0 : 2.5 * sin(t * 2 * .pi / 6))
        }
        .modifier(LiveLoop(running: $running))
        .accessibilityHidden(true)
    }
}

/// The glass surface for the paste field, the tiles and the form card. `lit` is the focused or pressed state: a brighter fill, a
/// hairline in the focus colour and a soft glow of it.
struct StartSurface: ViewModifier {
    var lit = false
    var radius = StartLook.radius
    @Environment(\.startPalette) private var palette
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(lit ? palette.fillLit : palette.fill))
            .overlay(shape.strokeBorder(lit ? palette.focus.opacity(0.6) : palette.hairline, lineWidth: 1))
            .shadow(color: palette.focus.opacity(lit ? 0.28 : 0), radius: 12)
            .animation(.easeOut(duration: 0.15), value: lit)
    }
}

extension View {
    func startSurface(lit: Bool = false, radius: CGFloat = StartLook.radius) -> some View { modifier(StartSurface(lit: lit, radius: radius)) }

    /// Rises into place and fades in when the screen appears; with Reduce Motion it only fades, at once. `order` staggers tiles by 40 ms each.
    func startRise(order: Int = 0) -> some View { modifier(StartRise(order: order)) }
}

private struct StartRise: ViewModifier {
    let order: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .onAppear {
                if reduceMotion { shown = true; return }
                withAnimation(.easeOut(duration: 0.45).delay(Double(order) * 0.04)) { shown = true }
            }
    }
}

/// How everything on the start screens answers a finger: it dips to 97 % and dims a little while pressed, then springs back.
/// With Reduce Motion it only dims.
struct StartPress: ViewModifier {
    let pressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .brightness(pressed ? -0.04 : 0)
            .opacity(pressed ? 0.92 : 1)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.82), value: pressed)
    }
}

/// A tile's icon in its rounded square, with a faint teal wash from the top corner. Each type's symbol moves its own way when `trigger`
/// changes: the link bounces, the server's lights run, the play frames pulse, the antenna's waves ripple, the folder and the set-top box
/// wiggle, the wave breathes. Still with Reduce Motion (the caller does not change the trigger then).
struct StartIconBadge: View {
    let symbol: String
    var size: CGFloat = 44
    var trigger = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        animated(Image(systemName: symbol).font(.system(size: size * 0.42, weight: .medium)))
            .foregroundStyle(StartLook.teal)
            .frame(width: size, height: size)
            .background(shape.fill(LinearGradient(colors: [StartLook.teal.opacity(0.26), StartLook.teal.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(shape.strokeBorder(StartLook.teal.opacity(0.18), lineWidth: 1))
            .accessibilityHidden(true)
    }

    @ViewBuilder private func animated(_ image: some View) -> some View {
        switch symbol {
        case "server.rack", "antenna.radiowaves.left.and.right": image.symbolEffect(.variableColor.iterative, options: .nonRepeating, value: trigger)
        case "play.rectangle.on.rectangle": image.symbolEffect(.pulse, options: .nonRepeating, value: trigger)
        case "folder", "tv.badge.wifi": image.symbolEffect(.wiggle, value: trigger)
        case "waveform.path": image.symbolEffect(.breathe, options: .nonRepeating, value: trigger)
        default: image.symbolEffect(.bounce, value: trigger)
        }
    }
}

/// A tile press: the surface lights up under the finger as well.
struct StartTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .startSurface(lit: configuration.isPressed)
            .modifier(StartPress(pressed: configuration.isPressed))
    }
}

/// One connection type: its icon, title and subtitle. VoiceOver reads the title, with the subtitle as the hint. A tap gives a light
/// tap from the haptic engine; an iPad pointer lifts the tile. The icon plays once when the tile first appears, and on a tap or a hover.
struct StartTileButton: View {
    let tile: StartTile
    var order = 0
    let action: () -> Void
    @Environment(\.startPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var taps = 0
    @State private var play = 0

    var body: some View {
        Button { taps += 1; wake(); action() } label: {
            VStack(alignment: .leading, spacing: 12) {
                StartIconBadge(symbol: tile.symbol, trigger: play)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tile.title).appFont(16, .semibold).foregroundStyle(palette.text)
                    Text(tile.subtitle).appFont(13).foregroundStyle(palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: StartLook.radius, style: .continuous))
        }
        .buttonStyle(StartTileStyle())
        .hoverEffect(.lift)
        .onHover { if $0 { wake() } }
        .task {
            try? await Task.sleep(for: .milliseconds(450 + order * 40))
            wake()
        }
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.title)
        .accessibilityHint(tile.subtitle)
        .accessibilityAddTraits(.isButton)
    }

    private func wake() { if !reduceMotion { play += 1 } }
}

/// The grid of tiles: two columns, three when there is room for them, one at the accessibility text sizes so nothing is squeezed.
struct StartTileGrid: View {
    var columns = 2
    let pick: (StartTile) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let count = typeSize.isAccessibilitySize ? 1 : columns
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: count), spacing: 12) {
            ForEach(Array(StartTile.offered.enumerated()), id: \.element) { index, tile in
                StartTileButton(tile: tile, order: index) { pick(tile) }.startRise(order: 3 + index)
            }
        }
    }
}

/// The one field that takes any address. `submit` is Return or the arrow, and is offered only when the text was recognised.
struct StartPasteField: View {
    @Binding var text: String
    /// The live detection note, or nil for the standing explanation.
    var note: String?
    var canSubmit: Bool
    var submit: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.startPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "link").font(.system(size: 16, weight: .medium)).foregroundStyle(focused ? palette.focus : palette.textSecondary).accessibilityHidden(true)
                TextField("Paste a playlist link, server address or stream", text: $text)
                    .appFont(16).foregroundStyle(palette.text)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit { if canSubmit { submit() } }
                if canSubmit {
                    Button(action: submit) { Image(systemName: "arrow.right.circle.fill").font(.system(size: 26)).foregroundStyle(ColorTokens.accentDefault) }
                        .buttonStyle(.borderless).accessibilityLabel("Continue")
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button { if let t = UIPasteboard.general.string { text = t } } label: {
                        Image(systemName: "doc.on.clipboard").font(.system(size: 16, weight: .medium)).foregroundStyle(palette.textSecondary).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.borderless).accessibilityLabel("Paste")
                }
            }
            .padding(.horizontal, 14).frame(minHeight: 54)
            .startSurface(lit: focused)
            .animation(.easeOut(duration: 0.15), value: canSubmit)
            Text(note ?? "StreamSetu works out the type and fills in the rest.")
                .appFont(13).foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: note)
        }
    }
}

/// A small eyebrow: small capitals with wide tracking.
struct StartLabel: View {
    let text: String
    @Environment(\.startPalette) private var palette
    var body: some View {
        Text(text.uppercased()).tracking(1.6).appFont(12, .semibold).foregroundStyle(palette.textSecondary)
            .accessibilityLabel(text).accessibilityAddTraits(.isHeader)
    }
}

/// Three reassurances under the welcome: where logins are kept, that no account is needed, and that nothing is included.
struct StartTrustRow: View {
    var vertical = false
    @Environment(\.startPalette) private var palette
    private let items: [(String, String)] = [
        ("lock.fill", "Logins stay encrypted on this device"),
        ("person.crop.circle.badge.xmark", "No account needed"),
        ("shippingbox", "Nothing is included: you bring your own"),
    ]
    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        layout {
            ForEach(items, id: \.1) { symbol, text in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(StartLook.teal.opacity(0.85)).frame(width: 16).accessibilityHidden(true)
                    Text(text).appFont(13).foregroundStyle(palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: vertical ? nil : .infinity, alignment: .leading)
            }
        }
    }
}

/// A chooser between the members of a tile (Plex, Jellyfin, Emby): the selected pill slides between the options. The options sit
/// side by side when they fit and stack when they do not (large text), so no name is cut off.
struct StartSegments<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    @Namespace private var pill
    @Environment(\.startPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { options }
            VStack(spacing: 4) { options }
        }
        .padding(4)
        .startSurface(radius: 12)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private var options: some View {
        ForEach(items, id: \.self) { item in
            let on = item == selection
            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.82)) { selection = item }
            } label: {
                Text(title(item)).appFont(14, .semibold).lineLimit(1).fixedSize()
                    .foregroundStyle(on ? palette.text : palette.textSecondary)
                    .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.fillLit)
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(palette.focus.opacity(0.55), lineWidth: 1))
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
        }
    }
}

/// A quiet button in the start screens' glass: Restore from iCloud, Find Tuners, Choose a File.
struct StartSecondaryStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.startPalette) private var palette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .appFont(15, .semibold).foregroundStyle(palette.text)
            .padding(.horizontal, 16).padding(.vertical, 6).frame(minHeight: 46)
            .startSurface(lit: configuration.isPressed, radius: 12)
            .modifier(StartPress(pressed: configuration.isPressed))
            .opacity(enabled ? 1 : 0.5)
            .hoverEffect(.highlight)
    }
}

/// The main button: the theme's accent, full width, with a soft light sweeping across it every four seconds while it waits for a press.
struct StartPrimaryStyle: ButtonStyle {
    var busy = false
    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration, busy: busy)
    }

    private struct PrimaryBody: View {
        let configuration: Configuration
        let busy: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var running = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: StartLook.radius, style: .continuous)
            configuration.label
                .appFont(17, .semibold).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(minHeight: 52)
                .background {
                    shape.fill(ColorTokens.accentDefault)
                        .overlay {
                            if enabled && !busy && !reduceMotion {
                                TimelineView(.animation(minimumInterval: 1 / 30, paused: !running)) { context in
                                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 1.1
                                    GeometryReader { g in
                                        LinearGradient(colors: [.clear, .white.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
                                            .frame(width: g.size.width * 0.3)
                                            .offset(x: g.size.width * (-0.35 + 1.4 * min(phase, 1)))
                                            .opacity(phase < 1 ? 1 : 0)
                                    }
                                }
                                .modifier(LiveLoop(running: $running))
                                .clipShape(shape)
                                .allowsHitTesting(false)
                            }
                        }
                }
                .modifier(StartPress(pressed: configuration.isPressed))
                .opacity(enabled || busy ? 1 : 0.4)
                .hoverEffect(.highlight)
        }
    }
}

/// Three dots rising one after another: the busy sign beside "Connecting…". Still with Reduce Motion.
struct DotWave: View {
    var color: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().fill(color).frame(width: 6, height: 6)
                        .offset(y: reduceMotion ? 0 : -3 * max(0, sin((t * 2 * .pi / 1.1) - Double(i) * 0.7)))
                        .opacity(reduceMotion ? 0.9 : 0.55 + 0.45 * max(0, sin((t * 2 * .pi / 1.1) - Double(i) * 0.7)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Shown for a moment when a connection is made: a ring bursts outwards and a check draws itself. With Reduce Motion both are
/// simply there.
struct ConnectedMark: View {
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(drawn ? 0 : 0.7), lineWidth: 3)
                .scaleEffect(drawn && !reduceMotion ? 1.9 : 1)
            Circle().fill(color.opacity(0.18)).overlay(Circle().strokeBorder(color, lineWidth: 2.5))
            CheckShape().trim(from: 0, to: drawn ? 1 : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                .padding(24)
        }
        .frame(width: 88, height: 88)
        .onAppear {
            if reduceMotion { drawn = true } else { withAnimation(.easeOut(duration: 0.55)) { drawn = true } }
        }
        .accessibilityElement()
        .accessibilityLabel("Connected")
    }
}

private struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY + r.height * 0.05))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY - r.height * 0.1))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.12))
        return p
    }
}

/// A short side-to-side shake, played when a connection fails. `shakes` counts failures; each new one shakes once.
struct Shake: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat { get { shakes } set { shakes = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(shakes * .pi * 4), y: 0))
    }
}
