import Testing
import Foundation
import SwiftUI
@testable import REDDY

/// Contrast and identity checks for every theme, and for the two Liquid Glass variants in particular.
@Suite("Theme contrast and identity") @MainActor struct ThemeContrastTests {
    static func lum(_ h: UInt32) -> Double {
        func c(_ v: UInt32) -> Double { let x = Double(v) / 255; return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * c((h >> 16) & 0xFF) + 0.7152 * c((h >> 8) & 0xFF) + 0.0722 * c(h & 0xFF)
    }
    static func ratio(_ a: UInt32, _ b: UInt32) -> Double { let (x, y) = (lum(a), lum(b)); return (max(x, y) + 0.05) / (min(x, y) + 0.05) }
    /// The label colour a control puts on an accent fill: near-black or white, the stronger of the two.
    static func labelRatio(on accent: UInt32) -> Double {
        let dark = ColorTokens.luminance(of: Color(hex: accent)) > 0.19
        return ratio(accent, dark ? 0x0B0D12 : 0xFFFFFF)
    }

    @Test func liquidGlassVariantsMeetTheStrictThresholds() {
        for t in [AppTheme.liquidGlass, .liquidGlassBlue] {
            let p = t.palette
            for (name, s) in [("background", p.background), ("panel", p.panel), ("surface", p.surface), ("card", p.card), ("elevated", p.elevated), ("bar", p.bar), ("glass", p.glass)] {
                #expect(Self.ratio(p.text, s) >= 7, "\(t.rawValue): text on \(name)")
            }
            for (name, s) in [("background", p.background), ("panel", p.panel), ("surface", p.surface), ("card", p.card), ("bar", p.bar)] {
                #expect(Self.ratio(p.textSecondary, s) >= 4.5, "\(t.rawValue): secondary text on \(name)")
            }
            if t == .liquidGlass { #expect(Self.ratio(p.textSecondary, p.elevated) >= 4.5, "secondary text on elevated") }
            for (name, s) in [("bar", p.bar), ("surface", p.surface), ("background", p.background)] {
                #expect(Self.ratio(p.accent, s) >= 3, "\(t.rawValue): accent on \(name)")
            }
            #expect(Self.labelRatio(on: p.accent) >= 4.5, "\(t.rawValue): label on an accent-filled button")
        }
    }

    @Test func liquidGlassIsNeutralGraphiteWithTheBrandTeal() {
        let p = AppTheme.liquidGlass.palette
        func spread(_ h: UInt32) -> Int { let c = [Int((h >> 16) & 255), Int((h >> 8) & 255), Int(h & 255)]; return c.max()! - c.min()! }
        for h in [p.background, p.panel, p.surface, p.card, p.elevated, p.bar, p.glass] + p.backdrop {
            #expect(spread(h) <= 0x14, "a near-neutral grey, no blue-violet cast: \(String(h, radix: 16))")
            #expect(h & 0xFF <= (h >> 16 & 0xFF) + 0x14)
        }
        for g in p.glows { #expect(Self.lum(g) < 0.15, "the glows stay faint") }
        #expect(p.glassy && p.nativeGlass)
        // the accent is teal: green and blue channels well above red
        #expect((p.accent >> 16 & 0xFF) < 0x40 && (p.accent >> 8 & 0xFF) > 0x90 && (p.accent & 0xFF) > 0xA0)
        #expect(p.sheen > 0.15 && p.highlight > 0.3, "still reads as glass")
        // steps up in lightness
        let l = [p.background, p.panel, p.surface, p.card, p.elevated].map(Self.lum)
        #expect(l == l.sorted())
    }

    @Test func liquidGlassBlueIsExactlyTheOldLook() {
        let p = AppTheme.liquidGlassBlue.palette
        #expect([p.background, p.panel, p.surface, p.card, p.elevated, p.accent, p.text, p.textSecondary, p.textTertiary, p.bar, p.glass] ==
                [0x0A1020, 0x101A33, 0x14203E, 0x1B2A4D, 0x25365F, 0x5EA8FF, 0xF4F7FF, 0xB4C0DC, 0x7C8BAE, 0x0B1226, 0x0A1226])
        #expect(p.sheen == 0.26 && p.highlight == 0.46 && p.glassy && p.nativeGlass)
        #expect(p.backdrop == [0x18305E, 0x0B1226, 0x1A0F33] && p.glows == [0x3A78FF, 0xB05CFF])
        #expect(AppTheme.liquidGlassBlue.group == AppTheme.liquidGlass.group)
        #expect(AppTheme.liquidGlassBlue.subtitle == "The previous Liquid Glass look: a deep blue backdrop.")
        #expect(AppTheme.liquidGlass.subtitle == "Apple's real Liquid Glass material on macOS 26 and later, over a smoky graphite backdrop with a teal accent.")
    }

    @Test func pickerOrderAndSavedChoices() {
        let names = AppTheme.allCases.map(\.rawValue)
        let i = names.firstIndex(of: "Liquid Glass")!
        #expect(names[i + 1] == "Liquid Glass Blue", "Blue sits right after Liquid Glass in the picker")
        #expect(names.count == 29)
        #expect(names.last == "Custom")
        let d = UserDefaults(suiteName: "lg-\(UUID().uuidString)")!
        d.set(true, forKey: "settings.design2")
        d.set("Liquid Glass", forKey: "settings.theme")
        #expect(AppSettings(defaults: d).theme == .liquidGlass, "a saved Liquid Glass gets the new look, not Blue")
        d.set("Liquid Glass Blue", forKey: "settings.theme")
        #expect(AppSettings(defaults: d).theme == .liquidGlassBlue)
        d.set("Liquid Glass Purple", forKey: "settings.theme")
        #expect(AppSettings(defaults: d).theme == .cinematic, "unknown names still fall back to the default")
        ThemeStore.current = .cinematic
    }

    /// Every theme: text, secondary text, hints, accent and the accent-button label meet the readable minimums.
    /// Tertiary text is for hints only. The editor classics keep their canonical backgrounds, so their text colours were lifted
    /// just enough (same hue) to pass; none is documented as an exception.
    @Test func everyThemeIsReadable() {
        for t in AppTheme.allCases {
            let p = t.palette
            for (n, s) in [("background", p.background), ("panel", p.panel), ("surface", p.surface)] {
                #expect(Self.ratio(p.text, s) >= 7, "\(t.rawValue): text on \(n)")
            }
            for (n, s) in [("card", p.card), ("elevated", p.elevated)] { #expect(Self.ratio(p.text, s) >= 4.5, "\(t.rawValue): text on \(n)") }
            for (n, s) in [("background", p.background), ("panel", p.panel), ("surface", p.surface), ("card", p.card)] {
                #expect(Self.ratio(p.textSecondary, s) >= 4.5, "\(t.rawValue): secondary on \(n)")
                #expect(Self.ratio(p.textTertiary, s) >= 3, "\(t.rawValue): hint text on \(n)")
            }
            #expect(Self.ratio(p.textSecondary, p.elevated) >= 3, "\(t.rawValue): secondary on elevated")
            for (n, s) in [("background", p.background), ("bar", p.bar), ("card", p.card)] { #expect(Self.ratio(p.accent, s) >= 3, "\(t.rawValue): accent on \(n)") }
            #expect(Self.labelRatio(on: p.accent) >= 4.5, "\(t.rawValue): label on an accent fill")
        }
    }

    @Test func onAccentPicksTheStrongerLabel() {
        #expect(ColorTokens.onAccent(Color(hex: 0xFFCC66)) == Color(hex: 0x0B0D12))
        #expect(ColorTokens.onAccent(Color(hex: 0x2AB9CB)) == Color(hex: 0x0B0D12))
        #expect(ColorTokens.onAccent(Color(hex: 0x6366F1)) == .white)
    }
}

@Suite("Accent follows the theme") @MainActor struct AccentTokenTests {
    @Test func theAccentTokenIsTheThemeAccentUnlessThePersonPickedOne() {
        let saved = ThemeStore.current; defer { ThemeStore.current = saved; ThemeStore.state.userAccent = nil }
        ThemeStore.state.userAccent = nil
        for t in [AppTheme.liquidGlass, .obsidian, .dracula] {
            ThemeStore.current = t
            #expect(ColorTokens.accent == Color(hex: t.palette.accent))
        }
        let d = UserDefaults(suiteName: "acc-\(UUID().uuidString)")!
        let s = AppSettings(defaults: d)
        s.accent = .magenta
        #expect(ColorTokens.accent == AccentChoice.magenta.color)
        s.accent = .coral
        #expect(ColorTokens.accent == ColorTokens.accentDefault, "the Theme colour choice follows the theme")
    }
}
