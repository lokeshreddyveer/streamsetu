import Foundation

// The numbers behind the animated lyrics panel, kept free of SwiftUI so every rule can be tested with plain values.
// Alpha and blur by distance, the shared easing curve, word lift, the held-word letter swell, scroll look-ahead and stagger,
// the three-dot interlude and the single-line strip fade.

enum MusicLyricsMotion {
    // MARK: easing

    /// Control points of the one curve every row transition uses: away quickly, in slowly and softly.
    static let bezier: (x1: Double, y1: Double, x2: Double, y2: Double) = (0.41, 0, 0.12, 0.99)
    static let duration = 0.4

    /// Value of the cubic bezier easing at time fraction `t` (0...1).
    static func curve(_ t: Double, _ b: (x1: Double, y1: Double, x2: Double, y2: Double) = bezier) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        func x(_ s: Double) -> Double { 3 * (1 - s) * (1 - s) * s * b.x1 + 3 * (1 - s) * s * s * b.x2 + s * s * s }
        func y(_ s: Double) -> Double { 3 * (1 - s) * (1 - s) * s * b.y1 + 3 * (1 - s) * s * s * b.y2 + s * s * s }
        func dx(_ s: Double) -> Double { 3 * (1 - s) * (1 - s) * b.x1 + 6 * (1 - s) * s * (b.x2 - b.x1) + 3 * s * s * (1 - b.x2) }
        var s = t
        for _ in 0..<8 {
            let err = x(s) - t
            if abs(err) < 1e-6 { break }
            let d = dx(s)
            if abs(d) < 1e-6 { break }
            s -= err / d
        }
        var lo = 0.0, hi = 1.0
        if s < 0 || s > 1 || abs(x(s) - t) > 1e-4 {
            for _ in 0..<40 { s = (lo + hi) / 2; if x(s) < t { lo = s } else { hi = s } }
        }
        return y(min(1, max(0, s)))
    }

    static func smoothstep(_ f: Double) -> Double { let c = min(1, max(0, f)); return c * c * (3 - 2 * c) }
    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

    // MARK: row emphasis

    static let falloffPhone: [Double] = [1, 0.8, 0.68, 0.58, 0.52, 0.5]
    static let falloffWide: [Double] = [1, 0.84, 0.74, 0.66, 0.58]
    static let blurRadii: [Double] = [0, 1, 1, 1.7, 2.4]
    static let unsungAlpha = 0.6
    static let unsungAlphaStrip = 0.65
    static let browsingAlpha = 0.8
    static let inactiveScale = 0.98
    static let pressedScale = 0.96

    /// Distance of every row from the nearest lit row. With nothing lit yet the first line counts as the one coming up.
    static func distances(count: Int, lit: Set<Int>, fallbackFocus: Int = 0) -> [Int] {
        guard count > 0 else { return [] }
        let anchors = lit.isEmpty ? [min(max(0, fallbackFocus), count - 1)] : lit.sorted()
        return (0..<count).map { i in anchors.map { abs($0 - i) }.min() ?? 0 }
    }

    static func alpha(distance d: Int, wide: Bool) -> Double {
        let table = wide ? falloffWide : falloffPhone
        return table[min(max(0, d), table.count - 1)]
    }

    static func blur(distance d: Int) -> Double { blurRadii[min(max(0, d), blurRadii.count - 1)] }

    static func rowAlphas(count: Int, lit: Set<Int>, wide: Bool, browsing: Bool = false, fallbackFocus: Int = 0) -> [Double] {
        if browsing { return [Double](repeating: browsingAlpha, count: count) }
        return distances(count: count, lit: lit, fallbackFocus: fallbackFocus).map { alpha(distance: $0, wide: wide) }
    }

    /// Blur is off while browsing, when the person turned it off or asked for less motion, and for unsynced lyrics.
    static func rowBlurs(count: Int, lit: Set<Int>, enabled: Bool, browsing: Bool = false, fallbackFocus: Int = 0) -> [Double] {
        guard enabled, !browsing else { return [Double](repeating: 0, count: count) }
        return distances(count: count, lit: lit, fallbackFocus: fallbackFocus).map { blur(distance: $0) }
    }

    /// The newest started line plus every earlier line that has a known end and is still before it (overlapping vocals stay lit).
    static func litRows(lines: [MusicLyricLine], at ms: Int64) -> Set<Int> {
        guard let newest = MusicLyricsLookup.lineIndex(in: lines, at: ms) else { return [] }
        var out: Set<Int> = [newest]
        var i = newest - 1
        while i >= 0 && i >= newest - 6 {
            if let end = knownEnd(lines[i]), !lines[i].text.isEmpty, end > ms { out.insert(i) }
            i -= 1
        }
        return out
    }

    /// An end the source stated: the last word end (background included) or the line's own end. The distance to the next stamp is not evidence.
    static func knownEnd(_ line: MusicLyricLine) -> Int64? {
        let wordEnd = line.words?.map(\.endMs).max()
        switch (wordEnd, line.endMs) {
        case let (w?, e?): return max(w, e)
        case let (w?, nil): return w
        case let (nil, e?): return e
        default: return nil
        }
    }

    // MARK: word sweep, lift, letters

    static let featherPoints = 30.0
    static let liftPoints = 2.0
    static let liftFallMs = 700.0

    /// 0...1 progress of the sweep inside one word.
    static func wordProgress(_ w: MusicLyricWord, at ms: Int64) -> Double {
        if ms <= w.startMs { return 0 }
        if ms >= w.endMs { return 1 }
        let span = Double(max(1, w.endMs - w.startMs))
        return Double(ms - w.startMs) / span
    }

    /// Lines without word timing light whole at their stamp.
    static func lineLit(_ line: MusicLyricLine, at ms: Int64) -> Bool { ms >= line.timeMs }

    static func heightFactor(holdMs: Double) -> Double {
        if holdMs <= 150 { return 0.25 }
        if holdMs >= 900 { return 1 }
        return 0.25 + 0.75 * smoothstep((holdMs - 150) / 750)
    }

    /// How far a sung word is lifted, 0...1 (multiply by `liftPoints`). Rises over its own length (250...700 ms) and settles over 700 ms after its end.
    static func lift(_ w: MusicLyricWord, at ms: Int64) -> Double {
        guard ms >= w.startMs else { return 0 }
        let hold = Double(max(0, w.endMs - w.startMs))
        let riseDur = clamp(hold, 250, 700)
        let rise = Double(ms - w.startMs) / riseDur
        let fall = 1 - Double(ms - w.endMs) / liftFallMs
        return heightFactor(holdMs: hold) * smoothstep(min(rise, fall))
    }

    /// A line is lifted from the first word start until 700 ms after the last word end.
    static func lineLifted(_ line: MusicLyricLine, at ms: Int64) -> Bool {
        guard let w = line.words, let first = w.first, let last = w.map(\.endMs).max() else { return false }
        return Double(ms) > Double(first.startMs) && Double(ms) < Double(last) + liftFallMs
    }

    static func isWide(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3040...0x30FF).contains(v) || (0x3400...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v)
            || (0x0590...0x0EFF).contains(v) || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v)   // Hebrew, Arabic, Devanagari to Malayalam, Thai: letters join, so they never grow one by one
    }

    /// A word "grows" only when short, plain script, and held long enough for its length.
    static func qualifiesForSwell(text: String, holdMs: Double) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = t.count
        guard n >= 1, n <= 7, !t.contains("-"), !t.contains(where: isWide) else { return false }
        switch n {
        case 1: return holdMs >= 1100
        case 2, 3: return holdMs >= 1360 + Double(n - 2) * 140
        case 4: return holdMs >= 1050
        default: return holdMs >= 900 && holdMs >= Double(n) * 200
        }
    }

    struct LetterPeak: Equatable, Sendable {
        var scale: Double
        var bloom: Double
        /// In multiples of the ordinary lift.
        var rise: Double
        /// Horizontal lean in em, away from the word centre.
        var shiftEm: Double
    }

    static func letterPeaks(length n: Int, holdMs: Double) -> [LetterPeak] {
        guard n > 0 else { return [] }
        let earned = pow(clamp((holdMs - 400) / (3000 - 400), 0, 1), 3)
        var decay = 0.0
        if n > 5 { decay += min(Double(n - 5) / 5, 1) * 0.4 }
        if holdMs < 1200 { decay += max(0, 1 - (holdMs - 800) / 400) * (n > 3 ? 0.3 : 0.1) }
        decay = min(decay, 0.7)
        let base = n <= 3 ? 0.05 : 0.04
        let spread = n <= 3 ? 0.85 : (n >= 6 ? 1.1 : 1.0)
        return (0..<n).map { i in
            let place = n > 1 ? Double(i) / Double(n - 1) : 0
            let reach = earned * (1 - place * decay)
            let scale = (1 + base + reach * 0.08) * 0.98
            let bloom = (0.35 + reach * 0.45) * min(1.1, holdMs / 1500) * spread
            let rise = ((scale - 1) / 0.1) * clamp(holdMs / 2000, 0.3, 1)
            let centre = n > 1 ? place : 0.5
            let shift = (centre - 0.5) * 2 * (scale - 1) * (25.0 / 34.0) * 0.98
            return LetterPeak(scale: scale, bloom: max(0, bloom), rise: max(0, rise), shiftEm: shift)
        }
    }

    /// Start of letter `i`'s move: each starts 9% of the hold after the previous.
    static func letterStart(wordStartMs: Int64, index i: Int, holdMs: Double) -> Double { Double(wordStartMs) + Double(i) * 0.09 * holdMs }

    /// 0...1 envelope of a letter's move at `ms`: up over the first 25%, held to 30%, settle to 75%, then rest.
    static func letterMove(wordStartMs: Int64, index i: Int, holdMs: Double, at ms: Int64) -> Double {
        let span = max(1, holdMs * 1.5)
        let p = (Double(ms) - letterStart(wordStartMs: wordStartMs, index: i, holdMs: holdMs)) / span
        if p <= 0 { return 0 }
        if p < 0.25 { return smoothstep(p / 0.25) }
        if p < 0.30 { return 1 }
        if p < 0.75 { return 1 - smoothstep((p - 0.30) / 0.45) }
        return 0
    }

    static func swellRestsAt(wordStartMs: Int64, length n: Int, holdMs: Double) -> Double {
        Double(wordStartMs) + holdMs * (Double(max(0, n - 1)) * 0.09 + 1.5)
    }

    // MARK: scroll

    static let leadRangeMs: ClosedRange<Double> = 350...500

    /// The silence between the end of the line being sung and the start of the next, clamped to 350...500 ms; 350 before the first line and after the last.
    static func scrollLead(lines: [MusicLyricLine], at ms: Int64) -> Double {
        guard let i = MusicLyricsLookup.lineIndex(in: lines, at: ms), i + 1 < lines.count else { return leadRangeMs.lowerBound }
        let end = knownEnd(lines[i]) ?? lines[i].timeMs
        return clamp(Double(lines[i + 1].timeMs - end), leadRangeMs.lowerBound, leadRangeMs.upperBound)
    }

    /// The row the panel is heading to: the active line evaluated a lead ahead of now.
    static func focusRow(lines: [MusicLyricLine], at ms: Int64) -> (index: Int?, leadMs: Double) {
        let lead = scrollLead(lines: lines, at: ms)
        return (MusicLyricsLookup.lineIndex(in: lines, at: ms + Int64(lead)), lead)
    }

    static let staggerStep = 0.06
    static let staggerRows = 3
    static let staggerSpan = 1.18

    /// Delay for a row trailing the target by `rowsBehind` rows, in seconds.
    static func rowDelay(rowsBehind: Int, duration: Double) -> Double { Double(min(max(0, rowsBehind), staggerRows)) * staggerStep * duration }

    /// Extra translation of a trailing row while the list moves `distance` points.
    static func trailingExtra(distance: Double, t: Double, delayFraction: Double) -> Double {
        distance * (curve(t) - curve(t - delayFraction))
    }

    /// Sum of the heights (and spacing) between two rows: how far the list travels from `from` to `to` (positive going down the list).
    static func travel(heights: [Int: Double], spacing: Double, from: Int, to: Int, estimate: Double) -> Double {
        guard from != to else { return 0 }
        let lo = min(from, to), hi = max(from, to)
        var total = 0.0
        for i in lo..<hi { total += (heights[i] ?? estimate) + spacing }
        return from < to ? total : -total
    }

    /// The scroll offset that puts a row's centre at `anchor` (0 = top, 0.5 = middle) of the viewport, kept inside the content.
    static func scrollOffset(rowTop: Double, rowHeight: Double, viewport: Double, content: Double, anchor: Double) -> Double {
        let raw = rowTop + rowHeight / 2 - viewport * anchor
        return min(max(0, raw), max(0, content - viewport))
    }

    /// Auto-follow resumes this long after the last manual scroll.
    static let manualPause = 3.0
    static func followResumes(lastManual: Date?, now: Date) -> Bool {
        guard let lastManual else { return true }
        return now.timeIntervalSince(lastManual) >= manualPause
    }

    // MARK: interlude

    static let interludeDot = 13.0, interludeGap = 5.0

    /// Fill of each of the three dots, 0.25 at rest to 1, each owning a third of the break. `progress` is 0...1 across the break.
    static func dotFills(progress: Double) -> [Double] {
        let p = clamp(progress, 0, 1)
        return (0..<3).map { i in 0.25 + 0.75 * clamp(p * 3 - Double(i), 0, 1) }
    }

    /// A break is the silence from an empty line (or the end of a line) to the next line's start. Nil when `index` is not an interlude.
    static func interlude(lines: [MusicLyricLine], index: Int, trackEndMs: Int64?) -> (start: Int64, end: Int64)? {
        guard lines.indices.contains(index), lines[index].text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let start = lines[index].timeMs
        let end = index + 1 < lines.count ? lines[index + 1].timeMs : (trackEndMs ?? start + 4000)
        return end > start ? (start, end) : nil
    }

    static func breakProgress(start: Int64, end: Int64, at ms: Int64) -> Double {
        guard end > start else { return 0 }
        return clamp(Double(ms - start) / Double(end - start), 0, 1)
    }

    // MARK: one-line strip

    /// A line's end for the strip: the next stamp, else the track end, else four seconds on.
    static func stripEnd(lines: [MusicLyricLine], index: Int, durationMs: Int64?) -> Int64 {
        if index + 1 < lines.count { return lines[index + 1].timeMs }
        if let d = durationMs, d > lines[index].timeMs { return d }
        return lines[index].timeMs + 4000
    }

    static func stripAlpha(remainingMs: Double, lineMs: Double) -> Double {
        let fade = clamp(0.28 * lineMs, 160, 700)
        return 0.78 * clamp(remainingMs / fade, 0, 1)
    }

    // MARK: sub-lines

    /// A translation or reading is drawn only when it differs from the line (trimmed, case-insensitive).
    static func showsSubLine(_ sub: String?, original: String) -> Bool {
        guard let s = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return false }
        return s.caseInsensitiveCompare(original.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame
    }

    // MARK: offset

    static let offsetStepMs: Int64 = 100
    static let offsetRangeMs: Int64 = 5000

    static func clampUIOffset(_ ms: Int64) -> Int64 { min(offsetRangeMs, max(-offsetRangeMs, ms)) }

    /// "+1.5 s" style text: one decimal, explicit sign.
    static func offsetLabel(_ ms: Int64) -> String {
        let s = Double(ms) / 1000
        if ms == 0 { return "0.0 s" }
        return String(format: "%@%.1f s", ms > 0 ? "+" : "-", abs(s))
    }

    /// Lyric time for a player position: positive offsets show the lyrics later; never negative.
    static func lyricTime(position: Int64, songOffset: Int64, globalOffset: Int64) -> Int64 { max(0, position - songOffset - globalOffset) }

    /// Seek target for a tapped line: its time plus the offsets, never negative.
    static func seekTime(lineMs: Int64, songOffset: Int64, globalOffset: Int64) -> Int64 { max(0, lineMs + songOffset + globalOffset) }
}
