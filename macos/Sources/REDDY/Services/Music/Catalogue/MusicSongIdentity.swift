import Foundation

/// When two rows of a RANKED list (a chart, a trending list) are the same song: the same cleaned title (spelling-tolerant), the same credited
/// artists, a running time within about 15 percent, and the same kind of version. Different recordings (cover, live, remix, re-recording,
/// karaoke, instrumental, reprise, female or male version ...) are never the same song here. This is for charts and other ranked lists and for
/// duplicate video-id rows of one recording; it is NOT applied to the tracks of an album (an album can hold two recordings with one title).
enum MusicSongIdentity {
    struct Signature: Hashable, Sendable {
        var titleKey: String
        var artistKeys: Set<String>
        /// nil for the song as released; otherwise what makes it a different recording ("remix", "live", "female version" ...).
        var version: String?
        var durationMs: Int64
        var isrc: String?
    }

    static let runtimeTolerance = 0.15

    // MARK: signature

    static func signature(for t: MusicTrack) -> Signature {
        Signature(titleKey: titleKey(t.title, artists: t.artists.map(\.name)), artistKeys: artistKeys(t.artists.map(\.name)),
                  version: versionTag(t.title), durationMs: t.durationMs, isrc: t.isrc?.uppercased())
    }

    /// The spelling-tolerant key of the song's core title: display noise, bracketed asides and film suffixes gone.
    static func titleKey(_ title: String, artists: [String] = []) -> String {
        var core = MusicDisplayTitle.clean(title: title, artists: artists).title
        core = core.replacingOccurrences(of: #"[\(\[\{（【][^\)\]\}）】]*[\)\]\}）】]"#, with: " ", options: .regularExpression)
        for d in [" - ", " – ", " — "] { if let r = core.range(of: d) { core = String(core[..<r.lowerBound]) } }
        let k = MusicTransliterationKey.key(core)
        return k.isEmpty ? MusicText.normalize(core) : k
    }

    /// Credited people as keys: channels and compilation labels are not people, so they never count for or against a match.
    static func artistKeys(_ names: [String]) -> Set<String> {
        var out = Set<String>()
        for n in names {
            for part in MusicLyricsQueryBuilder.names(n) {
                let c = MusicLyricsQueryBuilder.channelCore(part)
                guard !c.isEmpty, !MusicLyricsQueryBuilder.looksLikeChannel(c), !MusicCompilationArtist.isCompilation(c) else { continue }
                let k = MusicTransliterationKey.key(c)
                if !k.isEmpty { out.insert(k) }
            }
        }
        return out
    }

    private static let extraVersionPatterns: [(String, String)] = [
        (#"\bfemale (version|ver)\b|[\(\[]\s*female\s*[\)\]]"#, "female version"), (#"\bmale (version|ver)\b|[\(\[]\s*male\s*[\)\]]"#, "male version"),
        (#"\bsad version\b|\bsad ver\b"#, "sad version"), (#"\bduet version\b"#, "duet version"),
        (#"\bslowed\b|\bslow\s*\+\s*reverb\b|\bsped up\b|\bspeed up\b"#, "slowed/sped"), (#"\blo-?fi\b"#, "lofi"), (#"\bmashup\b"#, "mashup"),
        (#"\bextended\b"#, "extended"), (#"\bjukebox\b"#, "jukebox"), (#"\bmedley\b"#, "medley"), (#"\bbgm\b"#, "bgm"), (#"\b8d\b"#, "8d"), (#"\bdj\b"#, "dj")
    ]

    /// What kind of recording the title says this is; nil for the plain song. Uses the app's version typing and adds the Indian-film cases.
    static func versionTag(_ title: String) -> String? {
        var tags: [String] = []
        if let h = MusicCreditsAdapter.versionHint(title: title) { tags.append(h.kind.rawValue) }
        let l = title.lowercased()
        for (p, tag) in extraVersionPatterns where l.range(of: p, options: .regularExpression) != nil && !tags.contains(tag) { tags.append(tag) }
        // A language tag in brackets ("(Telugu)", "[Tamil]") is a dubbed or re-sung version.
        if let r = l.range(of: #"[\(\[]\s*(telugu|tamil|hindi|kannada|malayalam|punjabi|bengali)\s*[\)\]]"#, options: .regularExpression) {
            tags.append("lang " + l[r].trimmingCharacters(in: CharacterSet(charactersIn: "()[] ")))
        }
        return tags.isEmpty ? nil : tags.sorted().joined(separator: "+")
    }

    // MARK: comparison

    static func artistsCompatible(_ a: Set<String>, _ b: Set<String>) -> Bool {
        a.isEmpty || b.isEmpty || !a.isDisjoint(with: b)
    }

    static func runtimeCompatible(_ a: Int64, _ b: Int64) -> Bool {
        guard a > 0, b > 0 else { return true }
        let diff = abs(a - b)
        return diff <= 4000 || Double(diff) <= Double(max(a, b)) * runtimeTolerance
    }

    static func sameSong(_ a: Signature, _ b: Signature) -> Bool {
        guard !a.titleKey.isEmpty, a.titleKey == b.titleKey, a.version == b.version else { return false }
        guard artistsCompatible(a.artistKeys, b.artistKeys), runtimeCompatible(a.durationMs, b.durationMs) else { return false }
        // Two different recording codes with different lengths are two recordings, whatever the title says.
        if let x = a.isrc, let y = b.isrc, x != y, a.durationMs > 0, b.durationMs > 0, abs(a.durationMs - b.durationMs) > 3000 { return false }
        return true
    }

    static func sameSong(_ a: MusicTrack, _ b: MusicTrack) -> Bool { sameSong(signature(for: a), signature(for: b)) }

    // MARK: ranked lists

    /// What kind of upload a chart row is, in the order the chart pipeline prefers: the source's own audio or Topic, an album track, a lyric video,
    /// an official video. Same ladder as `MusicChartVersionRules.classify`, read from the row itself.
    static func classify(_ t: MusicTrack) -> MusicChartVersion {
        let padded = " " + MusicText.normalize(t.title) + " "
        func has(_ words: [String]) -> Bool { words.contains { padded.contains(" " + $0 + " ") } }
        if t.directStreams?.isEmpty == false { return .own }
        if t.artists.contains(where: { MusicTextMatch.isTopicChannel($0.name) }) { return .officialAudio }
        if has(["lyric video", "lyrical video", "lyrical", "lyrics", "lyric"]) { return .lyricVideo }
        if has(["official audio", "full audio", "audio song", "audio"]) { return .officialAudio }
        if has(["official video", "official music video", "music video", "video song", "full video", "video"]) || t.isVideo == true { return .officialVideo }
        if let a = t.album, !a.title.trimmingCharacters(in: .whitespaces).isEmpty { return .albumTrack }
        if t.providerID == "youtube-music" || t.providerID == "ytmusic" { return .albumTrack }
        return .other
    }

    struct Member: Equatable, Sendable {
        /// 1-based position in the original chart.
        var rank: Int
        var track: MusicTrack
        var kind: MusicChartVersion
    }

    /// One song of a ranked list: the best copy to play, every other copy, and the best (lowest) chart rank among them.
    struct Group: Equatable, Sendable {
        var rank: Int
        var members: [Member]
        var best: Member { members[0] }
        var versionCount: Int { members.count }
        var alternates: [Member] { Array(members.dropFirst()) }
    }

    struct Result: Equatable, Sendable {
        var groups: [Group]
        /// Rows that share a title with another group but were kept apart because they are a different recording: shown with a small marker.
        var sameTitleDifferentRecording: Set<String>
        var removedCount: Int { groups.reduce(0) { $0 + $1.members.count - 1 } }
    }

    /// Collapses the duplicates of a ranked list. Order follows the best chart rank of each song; within a song the preferred version leads.
    static func collapse(_ tracks: [MusicTrack], startRank: Int = 1) -> Result {
        let sigs = tracks.map(signature(for:))
        var groups: [Group] = []
        var sigOf: [[Signature]] = []
        for (i, t) in tracks.enumerated() {
            let m = Member(rank: startRank + i, track: t, kind: classify(t))
            if let gi = groups.indices.first(where: { g in sigOf[g].contains { sameSong($0, sigs[i]) } }) {
                groups[gi].members.append(m); sigOf[gi].append(sigs[i])
            } else {
                groups.append(Group(rank: m.rank, members: [m])); sigOf.append([sigs[i]])
            }
        }
        for gi in groups.indices {
            groups[gi].rank = groups[gi].members.map(\.rank).min() ?? groups[gi].rank
            groups[gi].members.sort { $0.kind.preference != $1.kind.preference ? $0.kind.preference < $1.kind.preference : $0.rank < $1.rank }
        }
        groups.sort { $0.rank < $1.rank }
        var marked = Set<String>()
        var byTitle: [String: [Group]] = [:]
        for g in groups { byTitle[signature(for: g.best.track).titleKey, default: []].append(g) }
        for (k, gs) in byTitle where !k.isEmpty && gs.count > 1 {
            let tags = Set(gs.map { signature(for: $0.best.track).version ?? "" })
            // Same title and same version kind but kept apart (different length or artists): a different recording of the same name.
            if tags.count < gs.count { for g in gs { marked.insert(g.best.track.uid) } }
        }
        return Result(groups: groups, sameTitleDifferentRecording: marked)
    }

    /// For ALBUMS: nothing is merged. A track whose title repeats inside the album with another recording (different length) gets a marker, so
    /// "Kashmeeru" twice in one album reads as two recordings and not as a mistake.
    static func repeatedTitleMarkers(inAlbum tracks: [MusicTrack]) -> Set<String> {
        var out = Set<String>()
        var seen: [String: [MusicTrack]] = [:]
        for t in tracks { seen[titleKey(t.title, artists: t.artists.map(\.name)) + "|" + (versionTag(t.title) ?? ""), default: []].append(t) }
        for (k, ts) in seen where !k.hasPrefix("|") && ts.count > 1 { for t in ts { out.insert(t.uid) } }
        return out
    }

    /// Label for an alternative in a "Choose version" list.
    static func versionLabel(_ v: MusicChartVersion) -> String {
        switch v {
        case .own, .officialAudio: Localized.string("Audio")
        case .albumTrack: Localized.string("Album track")
        case .lyricVideo: Localized.string("Lyric video")
        case .officialVideo: Localized.string("Video")
        case .other: Localized.string("Other version")
        }
    }
}
