import Foundation

/// A named place inside a long mix or DJ set.
struct SoundCloudChapter: Sendable, Hashable, Identifiable {
    var startSeconds: Double
    var title: String
    var id: Double { startSeconds }
}

/// Reads a tracklist out of free text ("12:34 Title", "1:02:03 - Title", "[12:34] Title", "Title - 12:34") or out of timestamped comments. Pure.
/// Fewer than three entries is not a tracklist, so nothing is returned: a stray time in a sentence never becomes a chapter.
enum SoundCloudChapters {
    static let minimumCount = 3
    /// Tracks at least this long get chapters (seconds).
    static let longTrackSeconds: Double = 20 * 60

    private static let time = #"((?:\d{1,2}:)?\d{1,2}:\d{2})"#
    private static let opener = #"[\[\(（【]?"#, closer = #"[\]\)）】]?"#
    private static let bullets = #"(?:[\-\*•·▪►▶>]+\s*)?(?:\d{1,3}\s*[\.\)\]]\s+)?"#
    private static let leading = "^\\s*" + bullets + opener + "\\s*" + time + "\\s*" + closer + #"\s*[-–—:|.]*\s*(.+?)\s*$"#
    private static let trailing = #"^\s*(?:[\-\*•·▪►▶>]+\s*)?(.+?)\s*[-–—|:@]*\s*"# + opener + time + closer + #"\s*$"#

    /// "12:34" or "1:02:03" in seconds; nil when the fields are out of range.
    static func seconds(_ stamp: String) -> Double? {
        let p = stamp.split(separator: ":").map { Int($0) }
        guard p.allSatisfy({ $0 != nil }) else { return nil }
        let v = p.compactMap { $0 }
        switch v.count {
        case 2: return v[1] < 60 ? Double(v[0] * 60 + v[1]) : nil
        case 3: return v[1] < 60 && v[2] < 60 ? Double(v[0] * 3600 + v[1] * 60 + v[2]) : nil
        default: return nil
        }
    }

    private static func match(_ pattern: String, _ line: String) -> (time: String, title: String, timeFirst: Bool)? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 3 else { return nil }
        let a = ns.substring(with: m.range(at: 1)), b = ns.substring(with: m.range(at: 2))
        return pattern == trailing ? (b, a, false) : (a, b, true)
    }

    static func parse(description: String, duration: Double? = nil) -> [SoundCloudChapter] {
        var raw: [SoundCloudChapter] = []
        for line in description.components(separatedBy: .newlines) {
            guard line.count <= 300 else { continue }
            let hit = match(leading, line) ?? match(trailing, line)
            guard let hit, let s = seconds(hit.time) else { continue }
            let title = clean(hit.title)
            if !title.isEmpty { raw.append(SoundCloudChapter(startSeconds: s, title: title)) }
        }
        return finish(raw, duration: duration)
    }

    /// Uploader comments pinned to a moment in the track (SoundCloud's timed comments); the body is the title.
    static func parse(comments: [SCComment], duration: Double? = nil) -> [SoundCloudChapter] {
        let raw = comments.compactMap { c -> SoundCloudChapter? in
            guard let ms = c.timestampMs, ms >= 0 else { return nil }
            let first = c.body.components(separatedBy: .newlines).first ?? c.body
            // A comment that carries its own stamp ("12:34 Title") loses it: the pinned moment is the time.
            let title = clean(match(leading, first)?.title ?? first)
            return title.isEmpty || title.count > 120 ? nil : SoundCloudChapter(startSeconds: Double(ms) / 1000, title: title)
        }.sorted { $0.startSeconds < $1.startSeconds }
        return finish(raw, duration: duration)
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—|:·•")))
    }

    /// Drops times that do not move forward or lie past the end, and everything when fewer than three remain.
    private static func finish(_ raw: [SoundCloudChapter], duration: Double?) -> [SoundCloudChapter] {
        var out: [SoundCloudChapter] = []
        for c in raw {
            if let d = duration, d > 0, c.startSeconds > d { continue }
            if let last = out.last, c.startSeconds <= last.startSeconds { continue }
            out.append(c)
        }
        return out.count >= minimumCount ? out : []
    }

    /// The chapter playing at `position` seconds.
    static func index(at position: Double, in chapters: [SoundCloudChapter]) -> Int? {
        chapters.lastIndex { $0.startSeconds <= position + 0.25 }
    }
}
