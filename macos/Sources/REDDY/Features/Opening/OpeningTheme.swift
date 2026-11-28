#if os(macOS)
import SwiftUI

/// The colours of one run of the opening, read once from the person's saved appearance (theme, custom theme, accent) before the first themed frame, and kept for the whole run so
/// no frame ever mixes two themes. It reads the same stored settings the rest of the app does and builds the colours with the app's own palette types; it does not keep a copy of any
/// palette. Anything unreadable falls back to the default theme, exactly as the app does.
struct OpeningTheme: Equatable {
    var background: Color
    var accent: Color
    /// "Stream" in the logo (the header draws it in white) and the brightest icon colour.
    var primary: Color
    /// The quiet icon colour.
    var secondary: Color

    /// The saved theme and accent. `defaults` is injectable for tests.
    static func read(_ d: UserDefaults = .standard) -> OpeningTheme {
        var theme = AppTheme(rawValue: d.string(forKey: "settings.theme") ?? "") ?? .cinematic
        // The first start of the current design resets the theme to the default (AppSettings does the same), so a stale stored value is not shown.
        if !d.bool(forKey: "settings.design2") { theme = .cinematic }
        let palette: ThemePalette
        if theme == .custom, let custom = CustomTheme(encoded: d.string(forKey: "settings.customtheme") ?? "") { palette = custom.palette } else { palette = theme.palette }
        let choice = AccentChoice(rawValue: d.string(forKey: "settings.accent") ?? "") ?? .coral
        let accent: Color = choice == .coral ? Color(hex: palette.accent) : choice.color
        return OpeningTheme(background: Color(hex: palette.background), accent: accent, primary: .white, secondary: Color(hex: palette.textSecondary))
    }
}
#endif
