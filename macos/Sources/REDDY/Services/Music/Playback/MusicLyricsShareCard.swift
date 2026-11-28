import Foundation

/// The data behind the "share these lyrics" card and its short video. The picture itself is drawn by the interface; this decides which
/// lines fit, how a picked set reads (gaps become an ellipsis), the card measurements, and how long each line plays in the video.
struct MusicLyricsShareCard: Sendable, Equatable {
    /// At most this many characters of picked lyric text (a translation or reading does not count).
    static let characterBudget = 250

    enum Measure {
        static let width = 1080.0
        static let maxHeight = 1920.0
        static let margin = 72.0
        static let artwork = 160.0
        static let storyPanelWidth = 760.0
        static let storyMaxHeight = 1280.0
        static let storyRadius = 44.0
        static let storyPadding = 52.0
        static let storyArtwork = 128.0
        /// Text sizes follow the lyrics panel's own ratios to its 34-point line.
        static let featherRatio = 30.0 / 34, liftRatio = 2.0 / 34, glowRatio = 6.0 / 34, subRatio = 20.0 / 34
        static let lineAdvanceRatio = 41.0 / 34, subAdvanceRatio = 25.0 / 20, trackingRatio = -0.7 / 34
    }

    struct Row: Sendable, Equatable {
        /// Index into the lyric's lines; nil for an ellipsis row standing for lines that were skipped.
        var lineIndex: Int?
        var text: String
        var sub: String?
        var background: String?
        var isEllipsis: Bool { lineIndex == nil }
    }

    var rows: [Row]
    var characterCount: Int
    var title: String
    var artist: String
    var showLogo: Bool

    /// The outcome of tapping a line while picking.
    enum Pick: Equatable, Sendable { case added, removed, full, ignored }

    static func characters(_ line: MusicLyricLine) -> Int { line.text.trimmingCharacters(in: .whitespacesAndNewlines).count }

    /// Adds or removes `index`. A line that would take the card over budget is not added (the interface shows "Card is full"); an empty
    /// line cannot be picked.
    static func toggle(_ index: Int, in picked: inout Set<Int>, lines: [MusicLyricLine]) -> Pick {
        guard lines.indices.contains(index) else { return .ignored }
        if picked.contains(index) { picked.remove(index); return .removed }
        let n = characters(lines[index])
        guard n > 0 else { return .ignored }
        let used = picked.reduce(0) { $0 + characters(lines[$1]) }
        if used + n > characterBudget { return .full }
        picked.insert(index)
        return .added
    }

    /// The card for a picked set, in song order, with an ellipsis row wherever the pick skips lines. Nothing picked gives nil.
    static func build(lines: [MusicLyricLine], picked: Set<Int>, title: String, artist: String, subLines: MusicLyricsSubLines? = nil,
                      showLogo: Bool = true) -> MusicLyricsShareCard? {
        let order = picked.filter { lines.indices.contains($0) && characters(lines[$0]) > 0 }.sorted()
        guard !order.isEmpty else { return nil }
        var rows: [Row] = []
        var previous: Int?
        var count = 0
        for i in order {
            if let p = previous, i > p + 1, lines[(p + 1)..<i].contains(where: { characters($0) > 0 }) { rows.append(Row(lineIndex: nil, text: "...")) }
            let l = lines[i]
            let text = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
            count += text.count
            let sub = subLines?.display(for: i, original: text)
            rows.append(Row(lineIndex: i, text: text, sub: (sub?.text.isEmpty ?? true) ? nil : sub?.text, background: sub?.background))
            previous = i
        }
        return MusicLyricsShareCard(rows: rows, characterCount: count, title: title, artist: artist, showLogo: showLogo)
    }

    /// Height a card of this many rows needs, never more than the maximum; the interface scales text down to fit.
    static func cardHeight(rowCount: Int, lineSize: Double = 34) -> Double {
        min(Measure.maxHeight, Measure.margin * 2 + Measure.artwork + Double(rowCount) * lineSize * Measure.lineAdvanceRatio * 2)
    }

    // MARK: video timing

    static let videoTailMs: Int64 = 400
    static let videoMaxRunMs: Int64 = 9_000
    static let videoFallbackMs: Int64 = 5_000

    struct Segment: Equatable, Sendable { var lineIndex: Int; var startMs: Int64; var endMs: Int64 }

    /// Each picked line plays from its stamp to the stamp of the next picked line when they are neighbours. The last line of a run ends at
    /// its own end plus 400 ms, or the next stamp, but the run is at most 9 s; with no end known, 5 s.
    static func videoSegments(lines: [MusicLyricLine], picked: Set<Int>) -> [Segment] {
        let order = picked.filter { lines.indices.contains($0) }.sorted()
        var out: [Segment] = []
        var runStart: Int64 = 0
        for (k, i) in order.enumerated() {
            let l = lines[i]
            let nextIsNeighbour = k + 1 < order.count && order[k + 1] == i + 1
            if k == 0 || order[k - 1] != i - 1 { runStart = l.timeMs }
            var end: Int64
            if nextIsNeighbour { end = lines[i + 1].timeMs } else {
                if l.hasKnownEnd { end = l.resolvedEndMs + videoTailMs } else if i + 1 < lines.count { end = lines[i + 1].timeMs } else { end = l.timeMs + videoFallbackMs }
                if i + 1 < lines.count { end = min(end, max(lines[i + 1].timeMs, l.resolvedEndMs)) }
                end = min(end, runStart + videoMaxRunMs)
                if !l.hasKnownEnd && i + 1 >= lines.count { end = min(l.timeMs + videoFallbackMs, runStart + videoMaxRunMs) }
            }
            out.append(Segment(lineIndex: i, startMs: l.timeMs, endMs: max(end, l.timeMs + 1)))
        }
        return out
    }
}
