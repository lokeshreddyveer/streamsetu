import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// Semantic colour tokens. Raw hex values live in `ThemePalette`; these read the palette of the current theme.
enum ColorTokens {
    private static var p: ThemePalette { ThemeStore.palette }
    static var background: Color { Color(hex: p.background) }
    static var panel: Color { Color(hex: p.panel) }                 // navigation and sidebar base
    static var sidebar: Color { panel }
    static var surface: Color { Color(hex: p.surface) }             // content surfaces (live panel, guide cells)
    static var card: Color { Color(hex: p.card) }
    static var elevated: Color { Color(hex: p.elevated) }
    static var accentDefault: Color { Color(hex: p.accent) }
    /// The accent in force: the person's choice in Settings, else the theme's. Use this, not `ColorTokens.accent` (which ignores the theme).
    static var accent: Color { ThemeStore.state.userAccent ?? accentDefault }
    static var live: Color { accentDefault }
    static var barFill: Color { Color(hex: p.bar) }
    static var glassFill: Color { Color(hex: p.glass) }

    static var textPrimary: Color { Color(hex: p.text) }
    private static var contrast: Bool { ThemeStore.state.highContrast }
    static var textSecondary: Color { contrast ? Color(hex: p.text, opacity: 0.9) : Color(hex: p.textSecondary) }
    static var textTertiary: Color { contrast ? Color(hex: p.text, opacity: 0.75) : Color(hex: p.textTertiary) }

    static var line: Color { Color.white.opacity(contrast ? 0.35 : 0.07) }
    static var border: Color { line }
    static var lineStrong: Color { Color.white.opacity(contrast ? 0.55 : 0.14) }
    static var borderStrong: Color { lineStrong }
    /// The star of a rating badge (the same on every tile, Mac and iPhone).
    static let starRating = Color.yellow
    static let glassEdge = Color(hex: 0xE3E8F0, opacity: 0.17)

    /// Strength of the top-lit sheen, and of the bright top-edge hairline, for the current theme.
    static var glassy: Bool { p.glassy }
    static var nativeGlass: Bool { p.nativeGlass && !ThemeStore.state.frostedOnly }
    /// Page colour for content areas: transparent on glassy themes so the lit backdrop shows through.
    static var contentBackground: Color { p.glassy ? .clear : Color(hex: p.background) }
    static var sheen: Double { p.sheen }
    static var highlight: Double { p.highlight }

    static let success = Color(hex: 0x38B981)
    static let warning = Color(hex: 0xF0B34A)
    static let danger = Color(hex: 0xEF5350)
}

extension ColorTokens {
    /// Relative luminance (WCAG) of a colour, 0 for black to 1 for white.
    static func luminance(of color: Color) -> Double {
        let r = color.resolve(in: EnvironmentValues())
        return 0.2126 * Double(r.linearRed) + 0.7152 * Double(r.linearGreen) + 0.0722 * Double(r.linearBlue)
    }
    /// The label colour for text or an icon drawn on a solid `accent` fill: near-black on light accents, white on dark ones,
    /// whichever gives the stronger contrast (the crossover is a luminance of about 0.19 against near-black).
    static func onAccent(_ accent: Color) -> Color { luminance(of: accent) > 0.19 ? Color(hex: 0x0B0D12) : .white }
}

private struct OnAccentLabel: ViewModifier {
    @Environment(\.reddyAccent) private var accent
    func body(content: Content) -> some View { content.foregroundStyle(ColorTokens.onAccent(accent)) }
}
extension View {
    /// Text or an icon on a solid accent fill: legible on every accent, light or dark.
    func onAccentLabel() -> some View { modifier(OnAccentLabel()) }
}

private struct DensityKey: EnvironmentKey { static let defaultValue = LayoutDensity.comfortable }
private struct AccentKey: EnvironmentKey { static var defaultValue: Color { ColorTokens.accentDefault } }
extension EnvironmentValues {
    var reddyAccent: Color { get { self[AccentKey.self] } set { self[AccentKey.self] = newValue } }
    var reddyDensity: LayoutDensity { get { self[DensityKey.self] } set { self[DensityKey.self] = newValue } }
}
