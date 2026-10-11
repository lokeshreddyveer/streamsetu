import Foundation

/// A theme the person builds themselves from three colours and a gloss level; every other colour is derived so the result stays
/// coherent. Stored as a short string ("0B0D12,2BB8F0,F5F6F8,0.30") so it travels in backups like any other setting.
struct CustomTheme: Equatable, Sendable {
    var background: UInt32 = 0x0B0D12
    var accent: UInt32 = 0x2BB8F0
    var text: UInt32 = 0xF5F6F8
    /// 0…1, from flat to glossy.
    var gloss = 0.2

    static let standard = CustomTheme()

    var palette: ThemePalette {
        let bg = background, ink = text
        return ThemePalette(
            background: bg,
            panel: Self.mix(bg, 0x000000, 0.18),
            surface: Self.mix(bg, ink, 0.025),
            card: Self.mix(bg, ink, 0.055),
            elevated: Self.mix(bg, ink, 0.095),
            accent: accent,
            text: ink,
            textSecondary: Self.mix(bg, ink, 0.68),
            textTertiary: Self.mix(bg, ink, 0.46),
            bar: Self.mix(bg, 0x000000, 0.45),
            glass: Self.mix(bg, 0x000000, 0.6),
            sheen: 0.03 + 0.27 * gloss,
            highlight: 0.5 * gloss)
    }

    /// Contrast of body text on the page background; WCAG asks for at least 4.5.
    var textContrast: Double { Self.contrast(text, background) }
    var accentContrast: Double { Self.contrast(accent, background) }
    var isReadable: Bool { textContrast >= 4.5 && accentContrast >= 3 }

    var encoded: String { String(format: "%06X,%06X,%06X,%.2f", background, accent, text, gloss) }

    init() {}

    init?(encoded s: String) {
        let p = s.split(separator: ",").map(String.init)
        guard p.count == 4, p[0].count == 6, p[1].count == 6, p[2].count == 6,
              let b = UInt32(p[0], radix: 16), let a = UInt32(p[1], radix: 16), let t = UInt32(p[2], radix: 16), let g = Double(p[3]) else { return nil }
        background = b; accent = a; text = t; gloss = min(1, max(0, g))
    }

    // MARK: colour maths

    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ s: UInt32) -> Double { Double((a >> s) & 0xFF) * (1 - t) + Double((b >> s) & 0xFF) * t }
        func q(_ v: Double) -> UInt32 { UInt32(min(255, max(0, v.rounded()))) }
        return q(ch(16)) << 16 | q(ch(8)) << 8 | q(ch(0))
    }

    static func luminance(_ c: UInt32) -> Double {
        func lin(_ v: UInt32) -> Double { let x = Double(v) / 255; return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin((c >> 16) & 0xFF) + 0.7152 * lin((c >> 8) & 0xFF) + 0.0722 * lin(c & 0xFF)
    }

    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
