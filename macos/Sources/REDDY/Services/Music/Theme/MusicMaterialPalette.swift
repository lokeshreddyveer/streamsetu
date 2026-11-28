import Foundation

// A Material You style palette made from one seed colour, in pure maths so it is tested without a screen.
//
// Method: an OKLCH approximation of the published tonal-palette idea (one hue, one chroma, many tones), not CAM16. A tone T (0...100, the CIE L* scale) is
// turned into OKLab lightness through its luminance, so greys line up with Material tones; chroma is then reduced until the colour fits sRGB. The scheme roles
// use the lightness and chroma figures of the behaviour notes: baseline purple #6750A4 has OKLCH chroma 0.1305, every chroma is scaled by the seed's chroma
// relative to that. No colour library is used and nothing is copied from one.

enum MusicOKLCH {
    struct Value: Hashable, Sendable { var l: Double, c: Double, h: Double }

    private static func lin(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    private static func gamma(_ x: Double) -> Double { x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055 }

    static func from(_ c: MusicRGB) -> Value {
        let r = lin(c.r), g = lin(c.g), b = lin(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let hue = atan2(bb, a) * 180 / .pi
        return Value(l: lightness, c: (a * a + bb * bb).squareRoot(), h: hue < 0 ? hue + 360 : hue)
    }

    /// Linear sRGB for an OKLCH colour, not clamped.
    private static func linear(_ l: Double, _ c: Double, _ hDeg: Double) -> (Double, Double, Double) {
        let h = hDeg * .pi / 180, a = c * cos(h), b = c * sin(h)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b, m_ = l - 0.1055613458 * a - 0.0638541728 * b, s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
        return (4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S,
                -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S,
                -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S)
    }

    private static func inGamut(_ t: (Double, Double, Double)) -> Bool {
        let e = 1e-4
        return t.0 >= -e && t.0 <= 1 + e && t.1 >= -e && t.1 <= 1 + e && t.2 >= -e && t.2 <= 1 + e
    }

    /// sRGB for the colour; when it does not fit, chroma is reduced (hue and lightness kept) instead of clamping channels, which would shift the hue.
    static func rgb(l: Double, c: Double, h: Double) -> MusicRGB {
        let light = min(1, max(0, l))
        var chroma = max(0, c)
        if !inGamut(linear(light, chroma, h)) {
            var lo = 0.0, hi = chroma
            for _ in 0..<22 { let mid = (lo + hi) / 2; if inGamut(linear(light, mid, h)) { lo = mid } else { hi = mid } }
            chroma = lo
        }
        let t = linear(light, chroma, h)
        func out(_ x: Double) -> Double { gamma(min(1, max(0, x))) }
        return MusicRGB(out(t.0), out(t.1), out(t.2))
    }

    /// OKLab lightness of the grey at Material tone `t` (CIE L*), so tone 0 is black and tone 100 is white.
    static func lightness(ofTone t: Double) -> Double {
        let lstar = min(100, max(0, t))
        let fy = (lstar + 16) / 116
        let y = fy > 6.0 / 29 ? fy * fy * fy : (lstar / 903.2962962962963)
        return cbrt(y)
    }

    static func hex(_ c: MusicRGB) -> String {
        func b(_ x: Double) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", b(c.r), b(c.g), b(c.b))
    }

    static func rgb(hex raw: String) -> MusicRGB? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return MusicRGB(Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255)
    }
}

struct MusicMaterialSeed: Hashable, Sendable {
    var hue: Double
    /// Seed chroma relative to the baseline purple, kept between 0.15 and 1.35 so a grey seed still tints and a neon one stays usable.
    var chromaFactor: Double

    static let baselineChroma = 0.1305
    static let achromaticHue = 294.0
    /// Below this OKLCH chroma the colour is treated as grey and its (noise) hue is ignored.
    static let achromaticBelow = 0.004
    static let baseline = MusicMaterialSeed(hue: 294, chromaFactor: 1)

    init(hue: Double, chromaFactor: Double) { self.hue = hue; self.chromaFactor = chromaFactor }

    init(_ color: MusicRGB) {
        let v = MusicOKLCH.from(color)
        hue = v.c < Self.achromaticBelow ? Self.achromaticHue : v.h
        chromaFactor = min(1.35, max(0.15, v.c / Self.baselineChroma))
    }
}

/// One hue and chroma at the standard Material tones.
struct MusicTonalPalette: Hashable, Sendable {
    static let tones: [Int] = [0, 10, 20, 25, 30, 35, 40, 50, 60, 70, 80, 90, 95, 98, 99, 100]
    var hue: Double
    var chroma: Double

    func color(tone: Double) -> MusicRGB {
        // Chroma fades out near black and white, where a coloured tone would look dirty.
        let edge = min(1, max(0, min(tone / 12, (100 - tone) / 6)))
        return MusicOKLCH.rgb(l: MusicOKLCH.lightness(ofTone: tone), c: chroma * edge, h: hue)
    }

    func ramp() -> [Int: MusicRGB] { Dictionary(uniqueKeysWithValues: Self.tones.map { ($0, color(tone: Double($0))) }) }
}

struct MusicMaterialScheme: Hashable, Sendable {
    var primary: MusicRGB, onPrimary: MusicRGB, primaryContainer: MusicRGB, onPrimaryContainer: MusicRGB
    var secondary: MusicRGB, onSecondary: MusicRGB, secondaryContainer: MusicRGB, onSecondaryContainer: MusicRGB
    var background: MusicRGB, onBackground: MusicRGB
    var surfaceContainerLow: MusicRGB, surfaceContainer: MusicRGB, surfaceContainerHigh: MusicRGB
    var onSurfaceVariant: MusicRGB, outline: MusicRGB, outlineVariant: MusicRGB
    var seed: MusicMaterialSeed
    var dark: Bool

    /// The fills the Music views already understand (backgrounds only, never text).
    var tintFills: MusicTintFills {
        MusicTintFills(background: background, card: surfaceContainerLow, secondary: surfaceContainer, muted: surfaceContainerHigh,
                       sidebar: surfaceContainerLow, sidebarAccent: surfaceContainerHigh, hue: seed.hue)
    }
}

enum MusicMaterialPalette {
    static func primaryPalette(_ s: MusicMaterialSeed) -> MusicTonalPalette { MusicTonalPalette(hue: s.hue, chroma: 0.135 * s.chromaFactor) }
    static func secondaryPalette(_ s: MusicMaterialSeed) -> MusicTonalPalette { MusicTonalPalette(hue: s.hue + 60, chroma: 0.065 * s.chromaFactor) }
    static func neutralPalette(_ s: MusicMaterialSeed) -> MusicTonalPalette { MusicTonalPalette(hue: s.hue, chroma: 0.012) }

    static func scheme(_ s: MusicMaterialSeed, dark: Bool) -> MusicMaterialScheme {
        let c = s.chromaFactor, h = s.hue
        let primary = primaryPalette(s), secondary = secondaryPalette(s)
        func ok(_ l: Double, _ chroma: Double, _ hue: Double = h) -> MusicRGB { MusicOKLCH.rgb(l: l, c: chroma, h: hue) }
        if dark {
            return MusicMaterialScheme(
                primary: ok(0.835, 0.098 * c), onPrimary: ok(0.315, 0.130 * c),
                primaryContainer: primary.color(tone: 30), onPrimaryContainer: primary.color(tone: 90),
                secondary: ok(0.835, 0.068 * c, h + 60), onSecondary: secondary.color(tone: 20),
                secondaryContainer: secondary.color(tone: 30), onSecondaryContainer: secondary.color(tone: 90),
                background: ok(0.182, 0.012), onBackground: ok(0.914, 0.012),
                surfaceContainerLow: ok(0.215, 0.014), surfaceContainer: ok(0.242, 0.016), surfaceContainerHigh: ok(0.285, 0.018),
                onSurfaceVariant: ok(0.80, 0.02), outline: ok(0.650, 0.02), outlineVariant: ok(0.38, 0.02), seed: s, dark: true)
        }
        return MusicMaterialScheme(
            primary: ok(0.4955, 0.135 * c), onPrimary: ok(1, 0),
            primaryContainer: primary.color(tone: 90), onPrimaryContainer: primary.color(tone: 10),
            secondary: ok(0.4955, 0.065 * c, h + 60), onSecondary: ok(1, 0),
            secondaryContainer: secondary.color(tone: 90), onSecondaryContainer: secondary.color(tone: 10),
            background: ok(0.984, 0.011), onBackground: ok(0.215, 0.012),
            surfaceContainerLow: ok(0.966, 0.013), surfaceContainer: ok(0.948, 0.016), surfaceContainerHigh: ok(0.930, 0.018),
            onSurfaceVariant: ok(0.44, 0.02), outline: ok(0.565, 0.02), outlineVariant: ok(0.84, 0.02), seed: s, dark: false)
    }
}

// MARK: - Settings keys

/// Where the Material You seed comes from. Wallpaper palettes have no macOS API, so these are the portable options.
enum MusicPaletteChoice: String, CaseIterable, Identifiable, Sendable {
    /// The app's own accent; nothing is replaced.
    case standard
    case materialCover, materialPicked, materialSystem
    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .materialCover: "Material You from the cover"
        case .materialPicked: "Material You from a colour I pick"
        case .materialSystem: "Material You from the system accent"
        }
    }
}

/// Theme settings beside `MusicAdaptiveSettings.defaultsKey` ("Adapt colours to artwork"). Everything is off or standard until the person changes it.
enum MusicThemeSettings {
    static let paletteKey = "music.theme.palette"
    static let pickedColorKey = "music.theme.pickedColor"
    static let defaultPicked = "#6750A4"
    /// "Light around music videos": off until switched on.
    static let ambientLightKey = "music.ambientLight"

    static func palette(_ d: UserDefaults = .standard) -> MusicPaletteChoice { d.string(forKey: paletteKey).flatMap(MusicPaletteChoice.init(rawValue:)) ?? .standard }
    static func setPalette(_ p: MusicPaletteChoice, _ d: UserDefaults = .standard) { d.set(p.rawValue, forKey: paletteKey) }
    static func pickedColor(_ d: UserDefaults = .standard) -> MusicRGB { d.string(forKey: pickedColorKey).flatMap { MusicOKLCH.rgb(hex: $0) } ?? MusicOKLCH.rgb(hex: defaultPicked) ?? MusicRGB(0.4, 0.31, 0.64) }
    static func setPickedColor(_ c: MusicRGB, _ d: UserDefaults = .standard) { d.set(MusicOKLCH.hex(c), forKey: pickedColorKey) }

    /// The seed colour for a choice. Nil means "leave the theme alone" (standard, or a cover with no colour).
    static func seedColor(for choice: MusicPaletteChoice, cover: MusicRGB?, picked: MusicRGB, system: MusicRGB?) -> MusicRGB? {
        switch choice {
        case .standard: nil
        case .materialCover: cover
        case .materialPicked: picked
        case .materialSystem: system
        }
    }
}
