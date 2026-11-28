import Foundation

/// The five looks of the lyrics strip (the slim card just above the player bar). Each shows the same three things (the line before, the line being sung and the
/// next one) in a different way.
enum MusicLyricsStripStyle: String, CaseIterable, Sendable {
    case threeLines, subtitle, karaoke, capsule, coverGlow
    var title: String {
        switch self {
        case .threeLines: Localized.string("Three lines")
        case .subtitle: Localized.string("Subtitle")
        case .karaoke: Localized.string("Karaoke")
        case .capsule: Localized.string("Capsule")
        case .coverGlow: Localized.string("Cover glow")
        }
    }
    /// Subtitle shows only the line being sung; every other look shows the neighbours too.
    var showsNeighbours: Bool { self != .subtitle }
}

enum MusicLyricsStripPrefs {
    static let styleKey = "music.lyrics.stripStyle"
    static let opacityKey = "music.lyrics.stripOpacity"
}

struct MusicLyricsStripWindow: Equatable, Sendable {
    var previous: Int?
    var current: Int?
    var next: Int?
}

enum MusicLyricsStripLogic {
    /// The line before, the line being sung and the next one, at lyric time `ms`. A blank line (an instrumental gap) is never shown as a lyric: while one is
    /// sounding there is no current line, and the neighbours skip over blanks.
    static func window(lines: [MusicLyricLine], atMs ms: Int64) -> MusicLyricsStripWindow {
        func blank(_ i: Int) -> Bool { lines[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let at = MusicLyricsLookup.lineIndex(in: lines, at: ms)
        var w = MusicLyricsStripWindow()
        let anchor: Int
        if let at, !blank(at) { w.current = at; anchor = at } else { anchor = at ?? -1 }
        var p = (w.current ?? anchor) - 1
        if w.current == nil { p = anchor }              // in a gap, the line before is the last one that finished
        while p >= 0 { if !blank(p) { w.previous = p; break }; p -= 1 }
        var n = (w.current ?? anchor) + 1
        while n < lines.count { if !blank(n) { w.next = n; break }; n += 1 }
        return w
    }

    /// How much of the current line has been sung, 0 to 1: by its word timings when it has them, otherwise by time between this line and the next.
    static func fill(of line: MusicLyricLine, nextStartMs: Int64?, atMs ms: Int64) -> Double {
        if let words = line.words?.filter({ !$0.background }), !words.isEmpty {
            var done = 0.0
            for w in words {
                if ms >= w.endMs { done += 1 }
                else if ms > w.startMs, w.endMs > w.startMs { done += Double(ms - w.startMs) / Double(w.endMs - w.startMs) }
            }
            return min(1, max(0, done / Double(words.count)))
        }
        let end = line.endMs ?? nextStartMs ?? (line.timeMs + 4000)
        guard end > line.timeMs else { return 1 }
        return min(1, max(0, Double(ms - line.timeMs) / Double(end - line.timeMs)))
    }
}
