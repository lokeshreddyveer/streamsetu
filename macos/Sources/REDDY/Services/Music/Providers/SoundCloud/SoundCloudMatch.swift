import Foundation

/// Deciding whether a SoundCloud upload is the same recording as a song from another source. SoundCloud holds remixes, bootlegs, DJ edits, covers
/// and re-uploads under the same titles as studio songs, so a match here is always weak: it may be OFFERED as an alternative, never merged
/// into a song's identity unless the two carry the same ISRC. Everything here is pure.
enum SoundCloudMatch {
    /// Words in a title that make it another version of a song.
    static let versionWords: [String: String] = [
        "remix": "remix", "rmx": "remix", "refix": "remix", "flip": "flip", "bootleg": "bootleg", "mashup": "mashup", "edit": "edit",
        "rework": "rework", "vip": "vip", "live": "live", "acoustic": "acoustic", "instrumental": "instrumental", "acapella": "acapella",
        "cover": "cover", "demo": "demo", "slowed": "slowed", "sped": "sped", "reverb": "reverb", "nightcore": "nightcore", "dub": "dub",
        "mix": "mix", "set": "set", "extended": "extended", "karaoke": "karaoke", "lofi": "lofi", "bass": "bass", "boosted": "boosted"
    ]
    /// Words that name no other version.
    private static let neutral: Set<String> = ["original", "official", "audio", "video", "lyrics", "lyric", "hd", "hq", "explicit", "clean", "remastered", "remaster", "version", "radio", "single", "album", "full", "feat", "ft", "featuring", "prod"]

    private static func words(_ s: String) -> [String] { MusicText.normalize(s).split(separator: " ").map(String.init) }

    /// Version markers in a title, wherever they are written ("Song (Club Remix)", "Song - Live at ...", "Song [Bootleg]").
    static func versionTags(_ title: String) -> Set<String> {
        var tags = Set<String>()
        for w in words(title) { if let v = versionWords[w] { tags.insert(v) } }
        // "original mix" and "original version" name the studio recording.
        let all = words(title).joined(separator: " ")
        if all.contains("original mix") || all.contains("original version") { tags.remove("mix") }
        if all.contains("radio edit") || all.contains("single edit") { tags.remove("edit") }
        return tags
    }

    /// The title without bracketed or dashed clutter, as comparable words.
    static func coreWords(_ title: String) -> [String] {
        var t = title.lowercased()
        t = t.replacingOccurrences(of: "[\\(\\[\\{][^\\)\\]\\}]*[\\)\\]\\}]", with: " ", options: .regularExpression)
        if let r = t.range(of: " - ") { t = String(t[..<r.lowerBound]) }
        t = t.replacingOccurrences(of: "\\s+(feat\\.?|ft\\.?|featuring)\\s.*$", with: "", options: .regularExpression)
        return words(t).filter { !neutral.contains($0) }
    }

    /// Whether an uploader name stands for the same artist as a credited one (either name contains the other, folded).
    static func sameArtist(_ a: String, _ b: String) -> Bool {
        let x = MusicText.normalize(a), y = MusicText.normalize(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || x.contains(y) || y.contains(x)
    }

    /// Length difference allowed between two copies of one recording: 5 seconds or 3 percent, whichever is larger.
    static func durationTolerance(ms: Int64) -> Int64 { max(5_000, ms * 3 / 100) }

    static func sameLength(_ a: Int64, _ b: Int64) -> Bool {
        guard a > 0, b > 0 else { return false }
        return abs(a - b) <= durationTolerance(ms: max(a, b))
    }

    /// May this SoundCloud track be treated as the same recording as `other`? Only when the ISRC agrees, or the title, version markers, artist and length all agree.
    /// A remix, bootleg, edit, live or slowed version never matches a plain recording, whatever else agrees.
    static func isSameRecording(_ sc: MusicTrack, _ other: MusicTrack) -> Bool {
        if let a = sc.isrc?.uppercased(), let b = other.isrc?.uppercased(), !a.isEmpty, a == b { return true }
        guard versionTags(sc.title) == versionTags(other.title) else { return false }
        let a = coreWords(sc.title), b = coreWords(other.title)
        guard !a.isEmpty, a == b else { return false }
        guard other.artists.contains(where: { o in sc.artists.contains { sameArtist($0.name, o.name) } }) else { return false }
        return sameLength(sc.durationMs, other.durationMs)
    }

    /// Whether a SoundCloud row is ever allowed to join another source's song in the library graph: by a shared ISRC only.
    static func mayMergeInGraph(_ sc: MusicTrack, _ other: MusicTrack) -> Bool {
        guard let a = sc.isrc?.uppercased(), let b = other.isrc?.uppercased(), !a.isEmpty else { return false }
        return a == b && versionTags(sc.title) == versionTags(other.title)
    }

    /// 0...1 closeness of an upload to a wanted song for the alternatives list, 0 when it fails a hard rule (version markers, title, length).
    static func alternativeScore(want: MusicTrack, got: MusicTrack) -> Float {
        guard versionTags(want.title) == versionTags(got.title) else { return 0 }
        let a = coreWords(want.title), b = coreWords(got.title)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var score: Float = 0
        if a == b { score += 0.5 } else if Set(a).isSubset(of: Set(b)) || Set(b).isSubset(of: Set(a)), min(a.count, b.count) >= 2 { score += 0.3 } else { return 0 }
        if want.artists.contains(where: { w in got.artists.contains { sameArtist($0.name, w.name) } }) { score += 0.25 }
        if want.durationMs > 0, got.durationMs > 0 {
            guard sameLength(want.durationMs, got.durationMs) else { return 0 }
            score += 0.2
        }
        return min(score, 0.95)
    }

    /// The one profile that is confidently an artist: the same folded name, and either a verified badge or a following large enough, clearly ahead
    /// of any other profile with that name. Nil means "show nothing".
    static let followerFloor = 1_000
    static func confidentUser(named name: String, among users: [SCUser]) -> SCUser? {
        let want = MusicText.normalize(name)
        guard !want.isEmpty else { return nil }
        let same = users.filter { MusicText.normalize($0.displayName) == want }.sorted { ($0.followers ?? 0) > ($1.followers ?? 0) }
        guard let best = same.first else { return nil }
        let f = best.followers ?? 0
        guard best.verified || f >= followerFloor else { return nil }
        if same.count > 1, !best.verified {
            let second = same[1].followers ?? 0
            guard f >= second * 5 else { return nil }
        }
        return best
    }

    /// The graph id of a SoundCloud upload: its own `provider` id, the same spelling as the track's uid. It names only that upload.
    static func externalID(for t: MusicTrack) -> ExternalID { ExternalID(scheme: .provider, value: "soundcloud:" + t.id) }
}
