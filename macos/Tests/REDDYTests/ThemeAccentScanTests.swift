import Testing
import Foundation
@testable import REDDY

/// No new literal colours in the screens or the design system: everything comes from the theme palette and the accent.
/// A file may keep literals only for a stated reason (artwork-derived colours, media badges, fixed brand art, fixed palettes).
@Suite("Accent and theme tokens only") struct ThemeAccentScanTests {
    /// File name (or folder) to the reason its literal colours stay.
    static let allowed: [String: String] = [
        "SettingsModels.swift": "the named accent choices are fixed colours by design",
        "StartScreenStyle.swift": "the branded start screen uses the logo's own teal and silver",
        "Opening": "the opening animation is fixed brand art",
        "BrandMotion.swift": "the logo animation is fixed brand art",
        "Cards.swift": "tile hues derive from the artwork; badge scrims and the watched tick are media overlays",
        "ArtworkImage.swift": "placeholder hue derives from the title",
        "FeaturedSlideshow.swift": "hero text sits on artwork, so its scrim and white button are fixed",
        "AudioOnlyBackdrop.swift": "fixed dark backdrop behind audio-only playback",
        "PlaybackSettingsPage.swift": "subtitle preview draws the chosen subtitle colour on a sample frame",
        "RatingBadge.swift": "media badge over artwork",
        "DownloadCornerBadge.swift": "media status badge over artwork",
        "ProfileViews.swift": "fixed avatar colours for people",
        "TMDBAttribution.swift": "the data provider's own brand colour",
        "TitlePageParts.swift": "title-page washes derive from the artwork hue",
        "MacTitleViews.swift": "title-page washes derive from the artwork hue",
        "AssistantView.swift": "the online dot is a status colour (green)",
        "ElementPickerTheme.swift": "falls back to the system blue only if a colour cannot be converted",
        "GeneralSettingsPage.swift": "the theme tile and the colour picker draw palette values",
        "GlassSurface.swift": "draws palette values",
        "CastSection.swift": "placeholder initials",
        "OnYourDeviceView.swift": "white spinner on a dark loading state",
    ]
    static let patterns = [#"Color\(hex: 0x"#, #"Color\(red:"#, #"Color\(hue:"#, #"Color\(\.sRGB"#, #"Color\.(blue|red|green|orange|yellow|purple|pink|cyan|teal|mint|indigo|brown)\b"#,
                           #"controlAccentColor"#, #"\.accentColor\b"#, #"NSColor\(red"#, #"UIColor\(red"#, #"systemBlue"#]

    @Test func noNewLiteralColoursOutsideTheTheme() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/REDDY")
        var bad: [String] = []
        for sub in ["Features", "DesignSystem", "Atlas"] {
            let en = try #require(FileManager.default.enumerator(at: root.appendingPathComponent(sub), includingPropertiesForKeys: nil))
            for case let f as URL in en where f.pathExtension == "swift" {
                if f.path.contains("/DesignSystem/Theme/") { continue }
                if Self.allowed.keys.contains(where: { f.lastPathComponent == $0 || f.path.contains("/\($0)/") }) { continue }
                let text = try String(contentsOf: f, encoding: .utf8)
                for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("//") { continue }
                    for p in Self.patterns where line.range(of: p, options: .regularExpression) != nil { bad.append("\(f.lastPathComponent):\(i + 1)") }
                }
            }
        }
        #expect(bad.isEmpty, "literal colours outside the theme, take them from ColorTokens or the accent: \(bad)")
    }

    @Test func theOldBlueLiteralsLiveOnlyInThePalette() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/REDDY")
        let en = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var bad: [String] = []
        for case let f as URL in en where f.pathExtension == "swift" && f.lastPathComponent != "ThemePalette.swift" {
            let text = try String(contentsOf: f, encoding: .utf8)
            for lit in ["0x5EA8FF", "0x0A1020", "0x18305E", "0x3A78FF", "0xB05CFF"] where text.contains(lit) { bad.append("\(f.lastPathComponent) \(lit)") }
        }
        #expect(bad.isEmpty, "Liquid Glass colours are defined only in ThemePalette: \(bad)")
    }
}
