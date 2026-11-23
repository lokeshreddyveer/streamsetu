import Foundation
import CoreGraphics

// The Mac title page's decisions, kept out of the views so they can be tested: how wide the page is and what that changes,
// what the Play button says, which facts become chips, which details are shown, and what colour the artwork gives the hero.

enum TitlePageLogic {
    // MARK: size

    /// How the page lays out at a width: two columns (synopsis beside the details) or one flow, and the sizes that follow.
    struct Metrics: Equatable {
        enum Columns { case two, one }
        var columns: Columns
        var heroHeight: CGFloat
        var poster: CGFloat
        var sideWidth: CGFloat
        var margin: CGFloat
        var titleSize: CGFloat
    }

    static func metrics(width: CGFloat) -> Metrics {
        if width >= 860 { return Metrics(columns: .two, heroHeight: 372, poster: 148, sideWidth: 300, margin: 32, titleSize: 40) }
        if width >= 640 { return Metrics(columns: .one, heroHeight: 340, poster: 120, sideWidth: 0, margin: 28, titleSize: 34) }
        return Metrics(columns: .one, heroHeight: 300, poster: 0, sideWidth: 0, margin: 20, titleSize: 28)
    }

    /// The dialog's size for a window: the window less a margin, never beyond a comfortable reading size, never below what the page needs.
    static func dialogSize(window: CGSize) -> CGSize {
        CGSize(width: min(1060, max(600, window.width - 96)), height: min(820, max(440, window.height - 64)))
    }

    // MARK: Play

    struct Resume: Equatable {
        var fraction: Double
        var remaining: Double
    }

    /// Resume only when something worth resuming exists: started (over 30 s), not finished, and not almost done.
    static func resume(_ p: WatchProgress?) -> Resume? {
        guard let p, !p.completed, p.positionSeconds > 30, p.durationSeconds > 0 else { return nil }
        let fraction = min(1, max(0, p.positionSeconds / p.durationSeconds))
        return fraction < 0.97 ? Resume(fraction: fraction, remaining: p.durationSeconds - p.positionSeconds) : nil
    }

    struct PlayLabel: Equatable { var title: String; var detail: String?; var fraction: Double? }

    static func playLabel(resume: Resume?) -> PlayLabel {
        if let r = resume { return PlayLabel(title: "Resume", detail: remainingText(r.remaining), fraction: r.fraction) }
        return PlayLabel(title: "Play", detail: nil, fraction: nil)
    }

    /// A series: "Play S1 E1" for a first watch, "Resume S2 E3" mid-episode, "Next S2 E4" once the last one is finished.
    static func playLabel(episode: (season: Int, number: Int)?, resume: Resume?, startedSeries: Bool) -> PlayLabel {
        guard let e = episode else { return PlayLabel(title: "Play", detail: nil, fraction: nil) }
        let tag = "S\(e.season) E\(e.number)"
        if let r = resume { return PlayLabel(title: "Resume \(tag)", detail: remainingText(r.remaining), fraction: r.fraction) }
        return PlayLabel(title: startedSeries ? "Play Next \(tag)" : "Play \(tag)", detail: nil, fraction: nil)
    }

    static func remainingText(_ seconds: Double) -> String { Localized.string("%@ left", DurationFormatter.short(seconds)) }

    // MARK: chips and details

    /// The small facts under the title, in order, each only when known. Age rating and quality are drawn as a small outlined box.
    struct Chip: Equatable, Identifiable {
        enum Kind { case year, seasons, runtime, age, quality }
        var text: String
        var kind: Kind
        var badge: Bool { kind == .age || kind == .quality }
        var id: String { "\(kind):\(text)" }
    }

    static func chips(year: Int?, runtimeSeconds: Double?, age: String?, quality: String?, seasons: Int?) -> [Chip] {
        var out: [Chip] = []
        if let year { out.append(Chip(text: String(year), kind: .year)) }
        if let s = seasons, s > 0 { out.append(Chip(text: "\(Localized.plural(s, one: "%@ season", other: "%@ seasons"))", kind: .seasons)) }
        if let r = runtimeSeconds, r > 0 { out.append(Chip(text: DurationFormatter.short(r), kind: .runtime)) }
        if let age = age?.nilIfEmpty { out.append(Chip(text: age, kind: .age)) }
        if let quality = quality?.nilIfEmpty { out.append(Chip(text: quality, kind: .quality)) }
        return out
    }

    /// VoiceOver reads the whole line as one sentence: "2026, 2 hours 56 minutes, rated PG-13, 4K, rating 8.0".
    static func chipsSpoken(_ chips: [Chip], rating: Double?, runtimeSeconds: Double?) -> String {
        var parts: [String] = chips.map { c in
            switch c.kind {
            case .runtime: runtimeSeconds.map(spokenDuration) ?? c.text
            case .age: "rated \(c.text)"
            default: c.text
            }
        }
        if let rating { parts.append("rating " + String(format: "%.1f", rating)) }
        return parts.joined(separator: ", ")
    }

    static func spokenDuration(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded()), h = m / 60, r = m % 60
        return [h > 0 ? "\(Localized.plural(h, one: "%@ hour", other: "%@ hours"))" : nil, r > 0 ? "\(Localized.plural(r, one: "%@ minute", other: "%@ minutes"))" : nil].compactMap { $0 }.joined(separator: " ")
    }

    /// The genres line: names joined by a dot, at most four, never an empty entry.
    static func genreLine(_ genres: [String]) -> String? {
        let g = genres.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return g.isEmpty ? nil : g.prefix(4).joined(separator: " · ")
    }

    /// Details shown as a grid: when the cast rail is on the page the "Starring" row would only repeat it.
    static func gridRows(_ rows: [DetailRow], castShown: Bool) -> [DetailRow] {
        rows.filter { row in
            if case .people = row.value { return !castShown }
            return true
        }
    }

    /// A cast photo is only drawn when its picture may be fetched: TMDB's pictures need the person's own key, a media server's own do not.
    static func photoURL(_ p: TitleDetails.Person, hasKey: Bool) -> String? {
        guard let url = p.photoURL else { return nil }
        return url.hasPrefix(MetadataMatchService.imageBase) && !hasKey ? nil : url
    }

    /// Initials for a cast member without a photo: at most two letters.
    static func initials(_ name: String) -> String { String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased() }

    // MARK: episode names

    /// What an episode row shows: its own title with the series name, the language tag, "S01E01" and stray separators taken off ("Murder in Mahim (Telugu) - S01E01 -" gives
    /// "Episode 1"). Display only: the full name stays in the accessibility label. Never empty.
    static func cleanEpisodeTitle(_ raw: String, series: String, number: Int) -> String {
        var t = raw
        let seriesName = series.trimmingCharacters(in: .whitespaces)
        if !seriesName.isEmpty, let r = t.range(of: seriesName, options: [.caseInsensitive, .diacriticInsensitive]) { t.removeSubrange(r) }
        t = t.replacingOccurrences(of: #"\([^()]*\)"#, with: " ", options: .regularExpression)               // (Telugu), (2024), (Dubbed)
        t = t.replacingOccurrences(of: #"(?i)\bS\d{1,2}\s*E\d{1,3}\b"#, with: " ", options: .regularExpression)     // S01E01
        t = t.replacingOccurrences(of: #"(?i)\b(?:season|episode|ep)\.?\s*\d+\b"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:|·.,_"))
        return t.isEmpty || t.allSatisfy({ $0.isNumber }) ? "Episode \(number)" : t
    }

    // MARK: scroll edges

    /// Which edges of a horizontal row fade: a side fades only when more lies beyond it, so a row that fits never fades.
    static func fadeEdges(offset: CGFloat, content: CGFloat, viewport: CGFloat) -> (leading: Bool, trailing: Bool) {
        guard content > viewport + 1 else { return (false, false) }
        return (offset < -1, content + offset > viewport + 1)
    }

    /// Season picker: chips up to six seasons, a menu beyond that.
    static func seasonsAsChips(_ count: Int) -> Bool { count <= 6 }
}

// MARK: colour from artwork

/// The colour a picture gives its hero: the average of what is saturated and not too dark or too bright, so a mostly black poster
/// still gives its one warm colour. Pure maths on a 24 pixel thumbnail.
enum TitlePalette {
    struct RGB: Equatable, Sendable { var r: Double, g: Double, b: Double
        var brightness: Double { max(r, g, b) }
        var saturation: Double { let hi = max(r, g, b), lo = min(r, g, b); return hi == 0 ? 0 : (hi - lo) / hi }
    }

    static func dominant(of image: CGImage) -> RGB? {
        let n = 24
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        let px = data.bindMemory(to: UInt8.self, capacity: n * n * 4)
        var r = 0.0, g = 0.0, b = 0.0, wsum = 0.0, ar = 0.0, ag = 0.0, ab = 0.0
        for i in 0..<(n * n) {
            let pr = Double(px[i * 4]) / 255, pg = Double(px[i * 4 + 1]) / 255, pb = Double(px[i * 4 + 2]) / 255
            ar += pr; ag += pg; ab += pb
            let c = RGB(r: pr, g: pg, b: pb)
            // weight: colourful pixels count most; near-black and near-white count little
            let w = c.saturation * (c.brightness > 0.12 && c.brightness < 0.97 ? 1 : 0.1) + 0.02
            r += pr * w; g += pg * w; b += pb * w; wsum += w
        }
        guard wsum > 0 else { return nil }
        let total = Double(n * n)
        let weighted = RGB(r: r / wsum, g: g / wsum, b: b / wsum)
        // a flat grey picture has nothing to offer: fall back to its plain average
        return weighted.saturation < 0.05 ? RGB(r: ar / total, g: ag / total, b: ab / total) : weighted
    }

    /// The wash colour for the hero: the dominant colour pulled to a fixed, dark, readable level (white text sits on it).
    static func wash(_ c: RGB) -> RGB {
        let hi = max(c.r, c.g, c.b)
        guard hi > 0 else { return RGB(r: 0.12, g: 0.12, b: 0.14) }
        let target = 0.42, s = target / hi
        return RGB(r: min(1, c.r * s), g: min(1, c.g * s), b: min(1, c.b * s))
    }
}
