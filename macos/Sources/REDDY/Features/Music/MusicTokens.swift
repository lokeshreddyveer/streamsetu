import SwiftUI

/// The only place Music maps sizes, fonts and a few fixed colours onto the app's own tokens. Screens read from here (or from `ColorTokens`,
/// `Typography`, `LayoutTokens`) and never carry a colour, font size or corner radius of their own.
///
/// Stable names added for the Living Canvas work (all documented below; motion is in MusicMotion.swift, layout in MusicLayoutGrid.swift):
/// - `MusicSpace` spacing scale: xxs 4, xs 8, sm 12, md 16, lg 20, xl 24, xxl 32, huge 40, giant 48 (`MusicSpace.scale` lists them).
/// - `MusicTypeRole` (display, page, section, card, body, secondary, caption, micro): `.font`, `.pointSize`; `View.musicText(_:)`.
/// - `MusicCorner` radius table: control, controlLarge, compactCard, compactCardLarge, card, cardLarge, panel, panelLarge, immersive,
///   immersiveLarge; `MusicCorner.range(for:)`.
/// - `MusicIconSize`: tiny 10, small 12, medium 14, large 16, toolbar 18, row 20, control 24, hero 32, empty 48.
/// - `MusicInk` (the only place literal white/black live): `onArtwork`, `onArtworkSecondary`, `onArtworkTertiary`, `onArtworkFaint`,
///   `hairlineOnArtwork`, `fullscreenBackdrop`, `fullscreenInk*`, `scrim(_:)`, `MusicInk.ScrimLevel`.
/// - `MusicElevation` levels 0-5 with `View.musicElevation(_:cornerRadius:)` and `View.musicHoverLift(_:cornerRadius:)`.
enum MusicTokens {
    // Hit targets: 28 pt on the Mac, 44 pt on iPhone and iPad.
    #if os(macOS)
    static let hitTarget: CGFloat = 28
    #else
    static let hitTarget: CGFloat = 44
    #endif

    // Corner radii come from the app.
    static let radiusRow = LayoutTokens.radiusSmall
    static let radiusCard = LayoutTokens.radius
    static let radiusPanel = LayoutTokens.radiusPanel
    static let radiusSheet = LayoutTokens.radiusLarge

    // Chrome sizes.
    static let headerHeight: CGFloat = 40
    static let railWidth: CGFloat = 200
    static let settingsRailWidth: CGFloat = 208
    static let settingsHeight: CGFloat = 560
    static let settingsWidth: CGFloat = 780
    static let settingsRowMinHeight: CGFloat = 44
    static let sheetWidth: CGFloat = 420
    static let commentsWidth: CGFloat = 320
    static let avatarSmall: CGFloat = 24
    static let avatarLarge: CGFloat = 32
    static let previewArtwork: CGFloat = 80
    /// Trailing room the setup footer leaves for the floating assistant button.
    static let setupCardWidth: CGFloat = 480
    static let assistantReserve: CGFloat = 72
    /// Longest line of running text (footnotes, notes) on a Music page.
    static let noteMaxWidth: CGFloat = 680

    // Symbol fonts for icon-only controls.
    static let iconSmall = Font.system(size: 12, weight: .medium)
    static let iconMedium = Font.system(size: 14, weight: .medium)
    static let iconLarge = Font.system(size: 16, weight: .semibold)

    // Text roles map to the app's type scale.
    static let pageTitle = Typography.pageTitle
    static let sheetTitle = Typography.title
    static let rowTitle = Typography.bodyMedium
    static let rowNote = Typography.caption
    static let sectionLabel = Typography.eyebrow

    // Motion: the app's standard curves, and nothing when Reduce Motion is on.
    static let spring = AnimationTokens.spring
    static let standard = AnimationTokens.standard

    // Fixed overlays. The scrim darkens the page behind a dialog; the flash is the accent at the strength the settings search uses.
    static let scrim = MusicInk.scrim(.medium)
    static let flashFill: Double = 0.16

    /// The flat fill of a cover that has not arrived: a faint neutral wash tinted by a stable hue (none for the empty address).
    static func coverWash(hue: Double, empty: Bool) -> some View {
        Color.primary.opacity(0.06).overlay(Color(hue: hue, saturation: 0.5, brightness: 0.7).opacity(empty ? 0 : 0.14))
    }
    /// The designed look of a cover that is missing or failed: a gradient in a stable hue per address (never a flat dark box).
    static func coverGradient(hue: Double) -> LinearGradient {
        let h2 = (hue + 0.08).truncatingRemainder(dividingBy: 1)
        return LinearGradient(colors: [Color(hue: hue, saturation: 0.5, brightness: 0.62), Color(hue: h2, saturation: 0.58, brightness: 0.4)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// The full designed cover for a missing picture: the two-hue gradient, a soft highlight from a corner chosen by the seed (0...3) and a darker foot,
    /// so neighbouring missing covers never look alike.
    @ViewBuilder static func coverBackdrop(hue: Double, corner: Int) -> some View {
        let spots: [UnitPoint] = [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing]
        ZStack {
            coverGradient(hue: hue)
            RadialGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0)], center: spots[abs(corner) % 4], startRadius: 0, endRadius: 240)
            LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.28)], startPoint: .center, endPoint: .bottom)
        }
    }
    /// The quiet glyph and the letters of a missing cover scale with the cover.
    static func coverGlyphFont(side: CGFloat) -> Font { .system(size: max(10, side * 0.46), weight: .semibold) }
    static func coverMonogramFont(side: CGFloat) -> Font { .system(size: max(9, side * 0.34), weight: .bold, design: .rounded) }
    static let flashHold: Double = 0.55
    static let flashSeconds: Double = 1.8
}

// MARK: - Spacing

/// Spacing scale in points. Use these for padding, stack spacing and gaps; nothing else.
enum MusicSpace {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let huge: CGFloat = 40
    static let giant: CGFloat = 48
    static let scale: [CGFloat] = [xxs, xs, sm, md, lg, xl, xxl, huge, giant]
}

// MARK: - Type roles

/// Type roles mapped onto the app's own `Typography` scale. `pointSize` mirrors that scale for layout maths and tests; it is the one
/// table of sizes Music keeps, and it must follow `Typography`.
enum MusicTypeRole: CaseIterable, Sendable {
    case display, page, section, card, body, secondary, caption, micro

    var font: Font {
        switch self {
        case .display: Typography.display
        case .page: Typography.pageTitle
        case .section: Typography.heading
        case .card: Typography.bodyMedium
        case .body: Typography.body
        case .secondary: Typography.row
        case .caption: Typography.caption
        case .micro: Typography.micro
        }
    }

    /// Nominal point size of the role in the app's scale.
    var pointSize: CGFloat {
        switch self {
        case .display: 34
        case .page: 26
        case .section: 16
        case .card: 13
        case .body: 13
        case .secondary: 12
        case .caption: 11
        case .micro: 10
        }
    }
}

extension View {
    /// Applies a Music type role as the font.
    func musicText(_ role: MusicTypeRole) -> some View { font(role.font) }
}

// MARK: - Corner geometry

/// Corner radii by surface kind. Pick the kind, not a number. Values derive from the app's `LayoutTokens` where one exists.
enum MusicCorner {
    static let control: CGFloat = 6
    static let controlLarge: CGFloat = 8
    static let compactCard: CGFloat = 10
    static let compactCardLarge: CGFloat = 12
    static let card: CGFloat = LayoutTokens.radius
    static let cardLarge: CGFloat = 16
    static let panel: CGFloat = LayoutTokens.radiusPanel
    static let panelLarge: CGFloat = 20
    static let immersive: CGFloat = 20
    static let immersiveLarge: CGFloat = 28

    enum Kind: CaseIterable, Sendable { case control, compactCard, card, panel, immersive }

    /// The allowed span for each kind (lower to upper).
    static func range(for kind: Kind) -> ClosedRange<CGFloat> {
        switch kind {
        case .control: control...controlLarge
        case .compactCard: compactCard...compactCardLarge
        case .card: card...cardLarge
        case .panel: panel...panelLarge
        case .immersive: immersive...immersiveLarge
        }
    }
}

// MARK: - Icon sizes

/// Symbol point sizes for `Image(systemName:)` and drawn icons.
enum MusicIconSize {
    static let tiny: CGFloat = 10
    static let small: CGFloat = 12
    static let medium: CGFloat = 14
    static let large: CGFloat = 16
    static let toolbar: CGFloat = 18
    static let row: CGFloat = 20
    static let control: CGFloat = 24
    static let hero: CGFloat = 32
    static let empty: CGFloat = 48
    static let scale: [CGFloat] = [tiny, small, medium, large, toolbar, row, control, hero, empty]
}

// MARK: - Ink and scrims

/// Colours for content that sits on artwork or on the full-screen player. This is the only place literal white and black may appear in
/// Music; everything else reads from here or from `ColorTokens`.
enum MusicInk {
    // Text and glyphs over artwork or a dark scrim.
    static let onArtwork = Color.white
    static let onArtworkSecondary = Color.white.opacity(0.72)
    static let onArtworkTertiary = Color.white.opacity(0.5)
    static let onArtworkFaint = Color.white.opacity(0.24)
    /// A hairline edge or divider over artwork.
    static let hairlineOnArtwork = Color.white.opacity(0.12)
    /// A subtle fill for chips and buttons over artwork.
    static let fillOnArtwork = Color.white.opacity(0.14)

    // The full-screen player: a dark ground and its ink, independent of the app theme.
    static let fullscreenBackdrop = Color.black
    static let fullscreenInk = Color.white
    static let fullscreenInkSecondary = Color.white.opacity(0.7)
    static let fullscreenInkTertiary = Color.white.opacity(0.45)
    static let fullscreenTrack = Color.white.opacity(0.2)

    /// Darkening levels for scrims over artwork and behind dialogs.
    enum ScrimLevel: Double, CaseIterable, Sendable {
        case whisper = 0.12, light = 0.25, medium = 0.4, strong = 0.6, heavy = 0.8
    }

    static func scrim(_ level: ScrimLevel) -> Color { Color.black.opacity(level.rawValue) }
    /// Clear black, for the transparent end of a gradient that fades to a scrim.
    static let clear = Color.black.opacity(0)
}

// MARK: - Elevation

/// Elevation levels. 0 flat; 1 hairline edge; 2 raised (edge and a faint tint); 3 floating bar or popover; 4 menu or dialog; 5 immersive.
/// Resting cards never carry a shadow: only levels 3 and above cast one, and hover lift on a card is a stroke overlay.
enum MusicElevation: Int, CaseIterable, Comparable, Sendable {
    case flat, edge, raised, floating, overlay, immersive

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var shadowRadius: CGFloat { [0, 0, 0, 12, 20, 32][rawValue] }
    var shadowOpacity: Double { [0, 0, 0, 0.22, 0.3, 0.38][rawValue] }
    var shadowOffsetY: CGFloat { [0, 0, 0, 4, 8, 14][rawValue] }
    var edgeOpacity: Double { [0, 1, 1, 1, 1, 0.6][rawValue] }
}

private struct MusicElevationModifier: ViewModifier {
    let level: MusicElevation
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                if level.edgeOpacity > 0 && level != .flat {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(ColorTokens.line.opacity(level.edgeOpacity), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: MusicInk.scrim(.strong).opacity(level.shadowOpacity / 0.6), radius: level.shadowRadius, y: level.shadowOffsetY)
    }
}

private struct MusicHoverLiftModifier: ViewModifier {
    let active: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(ColorTokens.lineStrong, lineWidth: 1)
                .opacity(active ? 1 : 0)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    /// Applies an elevation level. Do not use above level 1 on list or grid cards.
    func musicElevation(_ level: MusicElevation, cornerRadius: CGFloat = MusicCorner.card) -> some View {
        modifier(MusicElevationModifier(level: level, cornerRadius: cornerRadius))
    }

    /// Hover lift as a stroke overlay that fades with `active` (animate with `MusicMotion.Kind.hover`); no shadow, no layout change.
    func musicHoverLift(_ active: Bool, cornerRadius: CGFloat = MusicCorner.card) -> some View {
        modifier(MusicHoverLiftModifier(active: active, cornerRadius: cornerRadius))
    }
}
