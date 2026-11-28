import Foundation
import CoreGraphics
import ImageIO

// Colour taken from the cover art so the Music screens can follow the song that is playing. All the maths is pure (a small RGBA buffer in, numbers out)
// so it is tested without images; decoding to the 32x32 buffer is the only part that touches ImageIO.

struct MusicRGB: Hashable, Sendable {
    var r: Double, g: Double, b: Double   // 0...1, sRGB
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
}

struct MusicTintFills: Hashable, Sendable {
    var background: MusicRGB, card: MusicRGB, secondary: MusicRGB, muted: MusicRGB, sidebar: MusicRGB, sidebarAccent: MusicRGB
    /// The hue (degrees) the fills were made at.
    var hue: Double
}

enum MusicAdaptiveColor {
    static let sampleSide = 32
    static let minSaturation = 0.15
    static let darkTarget = 0.65, lightTarget = 0.39
    static let lightThreshold = 0.6

    // MARK: colour spaces

    static func hsv(_ c: MusicRGB) -> (h: Double, s: Double, v: Double) {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == c.r { h = (c.g - c.b) / d } else if mx == c.g { h = 2 + (c.b - c.r) / d } else { h = 4 + (c.r - c.g) / d }
            h = (h * 60).truncatingRemainder(dividingBy: 360); if h < 0 { h += 360 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    static func rgb(h: Double, s: Double, v: Double) -> MusicRGB {
        let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let c = v * s, x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let (r, g, b): (Double, Double, Double)
        switch Int(hh) { case 0: (r, g, b) = (c, x, 0); case 1: (r, g, b) = (x, c, 0); case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c); case 4: (r, g, b) = (x, 0, c); default: (r, g, b) = (c, 0, x) }
        return MusicRGB(r + m, g + m, b + m)
    }

    /// The HSP perceived brightness, 0...1.
    static func brightness(_ c: MusicRGB) -> Double { (0.299 * c.r * c.r + 0.587 * c.g * c.g + 0.114 * c.b * c.b).squareRoot() }

    /// Text on an accent is dark when this is true. HSP, not WCAG luminance, because luminance gives mid blues black text.
    static func isLight(_ c: MusicRGB) -> Bool { brightness(c) > lightThreshold }

    // MARK: extraction

    /// A 3-bit-per-channel histogram. Each opaque pixel adds saturation x (1 - |brightest channel - 0.65|), favouring saturated mid-bright pixels so the
    /// near-black and near-white that dominate covers never win by area. The winner's colour is the mean of its pixels. A cover with no colour gives nil.
    static func dominant(rgba: [UInt8]) -> MusicRGB? {
        var score = [Double](repeating: 0, count: 512), sum = [Double](repeating: 0, count: 512 * 3), count = [Int](repeating: 0, count: 512)
        var i = 0
        while i + 3 < rgba.count {
            defer { i += 4 }
            guard rgba[i + 3] >= 128 else { continue }
            let r = Double(rgba[i]) / 255, g = Double(rgba[i + 1]) / 255, b = Double(rgba[i + 2]) / 255
            let mx = max(r, g, b), mn = min(r, g, b)
            guard mx > 0 else { continue }
            let bucket = Int(rgba[i] >> 5) << 6 | Int(rgba[i + 1] >> 5) << 3 | Int(rgba[i + 2] >> 5)
            score[bucket] += ((mx - mn) / mx) * (1 - abs(mx - 0.65))
            sum[bucket * 3] += r; sum[bucket * 3 + 1] += g; sum[bucket * 3 + 2] += b; count[bucket] += 1
        }
        guard let best = score.indices.max(by: { score[$0] < score[$1] }), score[best] > 0, count[best] > 0 else { return nil }
        let n = Double(count[best])
        let c = MusicRGB(sum[best * 3] / n, sum[best * 3 + 1] / n, sum[best * 3 + 2] / n)
        return hsv(c).s < minSaturation ? nil : c
    }

    // MARK: banding

    /// Brings a raw cover colour into the theme's band: brightness 0.65 on dark themes, 0.39 on light ones, saturation 0.45...0.85, hue kept. If even full value cannot
    /// reach the target (a deep blue) saturation is bisected downward to keep as much colour as possible.
    static func toAccent(_ c: MusicRGB, dark: Bool) -> MusicRGB {
        let target = dark ? darkTarget : lightTarget
        let p = hsv(c)
        var s = min(0.85, max(0.45, p.s))
        if brightness(rgb(h: p.h, s: s, v: 1)) < target {
            var lo = 0.0, hi = s
            for _ in 0..<12 { let mid = (lo + hi) / 2; if brightness(rgb(h: p.h, s: mid, v: 1)) >= target { lo = mid } else { hi = mid } }
            s = lo
        }
        let full = brightness(rgb(h: p.h, s: s, v: 1))
        let v = full > 0 ? min(1, target / full) : 1
        return rgb(h: p.h, s: s, v: v)
    }

    // MARK: tinted fills

    /// OKLCH to sRGB (clamped).
    static func oklch(_ l: Double, _ c: Double, _ hDeg: Double) -> MusicRGB {
        let h = hDeg * .pi / 180, a = c * cos(h), b = c * sin(h)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b, m_ = l - 0.1055613458 * a - 0.0638541728 * b, s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
        let r = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
        let g = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
        let bl = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
        func gamma(_ x: Double) -> Double { let v = min(1, max(0, x)); return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        return MusicRGB(gamma(r), gamma(g), gamma(bl))
    }

    /// The hue of a colour in OKLCH, in degrees.
    static func oklchHue(_ c: MusicRGB) -> Double {
        func lin(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let r = lin(c.r), g = lin(c.g), b = lin(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let h = atan2(bb, a) * 180 / .pi
        return h < 0 ? h + 360 : h
    }

    /// Fills only (never text or borders): lightness / chroma pairs at the cover's hue, one set per theme.
    static func fills(hue: Double, dark: Bool) -> MusicTintFills {
        if dark {
            return MusicTintFills(background: oklch(0.165, 0.028, hue), card: oklch(0.225, 0.038, hue), secondary: oklch(0.285, 0.04, hue), muted: oklch(0.275, 0.042, hue),
                                  sidebar: oklch(0.195, 0.032, hue), sidebarAccent: oklch(0.275, 0.042, hue), hue: hue)
        }
        return MusicTintFills(background: oklch(0.985, 0.014, hue), card: oklch(0.995, 0.01, hue), secondary: oklch(0.945, 0.03, hue), muted: oklch(0.945, 0.028, hue),
                              sidebar: oklch(0.965, 0.022, hue), sidebarAccent: oklch(0.935, 0.035, hue), hue: hue)
    }

    // MARK: decoding

    /// Draws the image into a `side` x `side` RGBA buffer (premultiplied alpha undone).
    static func rgba(from data: Data, side: Int = sampleSide) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: max(side * 4, 64)] as CFDictionary)
        else { return nil }
        return rgba(from: img, side: side)
    }

    /// Same, from a cover the artwork service already decoded.
    static func rgba(from img: CGImage, side: Int = sampleSide) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: side * side * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return nil }
        var i = 0
        while i < buf.count {
            let a = Int(buf[i + 3])
            if a > 0, a < 255 { for k in 0..<3 { buf[i + k] = UInt8(min(255, Int(buf[i + k]) * 255 / a)) } }
            i += 4
        }
        return buf
    }

    /// The accent for a cover image, or nil when the cover has no colour or cannot be read.
    static func accent(fromImage data: Data, dark: Bool) -> MusicRGB? {
        guard let px = rgba(from: data), let c = dominant(rgba: px) else { return nil }
        return toAccent(c, dark: dark)
    }
}

// MARK: - Cover wash

/// A soft blurred copy of the cover for the full-screen player background. Baked once per track at 160x160 and stretched, never blurred live.
enum MusicCoverWash {
    static let side = 160
    static let blurRadius = 28
    static let cacheLimit = 8

    struct Baked: Sendable { var rgba: [UInt8]; var darkest: Double; var brightest: Double }

    /// Three box blurs by running sums (edges held) approximate a gaussian of sigma ~28; colour is then pushed 1.5x away from grey.
    static func bake(rgba source: [UInt8], side n: Int = side, radius: Int = blurRadius) -> Baked {
        guard n > 0, source.count == n * n * 4 else { return Baked(rgba: source, darkest: 0, brightest: 1) }
        var px = source.map { Double($0) }
        for _ in 0..<3 { px = boxBlur(px, side: n, radius: radius, horizontal: true); px = boxBlur(px, side: n, radius: radius, horizontal: false) }
        var darkest = 1.0, brightest = 0.0
        var out = [UInt8](repeating: 255, count: px.count)
        var i = 0
        while i < px.count {
            let r = px[i] / 255, g = px[i + 1] / 255, b = px[i + 2] / 255
            let grey = 0.299 * r + 0.587 * g + 0.114 * b
            let c = [r, g, b].map { min(1, max(0, grey + ($0 - grey) * 1.5)) }
            let br = MusicAdaptiveColor.brightness(MusicRGB(c[0], c[1], c[2]))
            darkest = min(darkest, br); brightest = max(brightest, br)
            out[i] = UInt8(c[0] * 255); out[i + 1] = UInt8(c[1] * 255); out[i + 2] = UInt8(c[2] * 255)
            i += 4
        }
        return Baked(rgba: out, darkest: darkest, brightest: brightest)
    }

    private static func boxBlur(_ src: [Double], side n: Int, radius r: Int, horizontal: Bool) -> [Double] {
        var out = src
        let width = Double(2 * r + 1)
        for line in 0..<n {
            func idx(_ k: Int) -> Int { (horizontal ? line * n + min(n - 1, max(0, k)) : min(n - 1, max(0, k)) * n + line) * 4 }
            for ch in 0..<3 {
                var sum = 0.0
                for k in -r...r { sum += src[idx(k) + ch] }
                for k in 0..<n {
                    out[idx(k) + ch] = sum / width
                    sum += src[idx(k + r + 1) + ch] - src[idx(k - r) + ch]
                }
            }
        }
        return out
    }

    /// How strongly the wash may show so text stays readable: dark themes lift the room to at most ~20% grey, light themes darken to at most ~85%.
    static func opacity(dark: Bool, darkest: Double, brightest: Double) -> Double {
        if dark { return brightest > 0 ? min(1, 0.2 / brightest) : 1 }
        let d = 1 - darkest
        return d > 0 ? min(1, 0.15 / d) : 1
    }

    struct Blob: Hashable, Sendable { var hueOffset: Double; var saturation: Double; var lightness: Double; var alpha: Double; var cx: Double; var cy: Double; var rx: Double; var ry: Double }

    /// The three soft colour blobs of the player background; hue 265 when the cover has no colour.
    static let blobs: [Blob] = [
        Blob(hueOffset: 0, saturation: 0.72, lightness: 0.48, alpha: 0.34, cx: 0.12, cy: 0.18, rx: 0.70, ry: 0.60),
        Blob(hueOffset: 38, saturation: 0.70, lightness: 0.45, alpha: 0.28, cx: 0.88, cy: 0.82, rx: 0.60, ry: 0.55),
        Blob(hueOffset: -46, saturation: 0.65, lightness: 0.52, alpha: 0.20, cx: 0.72, cy: 0.08, rx: 0.55, ry: 0.50),
    ]
    static let fallbackHue = 265.0
}
