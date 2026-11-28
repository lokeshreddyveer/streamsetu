import Foundation

/// Every number and word list the twin matcher uses, in one value so a new edge case is a data change and a test, not new logic.
/// The shape follows the usual tiered matching: the catalogue's own identity first, then title and artist (title weighs more), then the running
/// time on a falling curve, then version words; a phonetic spelling match is a hint that has to be backed by artist and running time.
struct MusicTwinRules: Sendable {
    var titleWeight: Float = 0.6
    var artistWeight: Float = 0.4
    /// Added when title and artist both reach `highThreshold`.
    var bothHighBonus: Float = 0.1
    var highThreshold: Float = 0.85
    /// Largest difference between the catalogue's running time and the copy's, in milliseconds.
    var runtimeWindowMs: Int64 = 10_000
    /// A copy found only through a phonetic spelling must agree much more closely.
    var phoneticRuntimeWindowMs: Int64 = 5_000
    /// Within this the copy is the same recording for certain (also the exception that lets an unclear artist pass).
    var exactRuntimeMs: Int64 = 2_000
    var acceptThreshold: Float = 0.62
    var minimumTitleSimilarity: Float = 0.75
    var unknownRuntimeFactor: Float = 0.8
    /// (largest difference in ms, multiplier) from closest to farthest; past the last row the factor is the last row's.
    var runtimeCurve: [(Int64, Float)] = [(2_000, 1), (5_000, 0.93), (8_000, 0.82), (10_000, 0.7)]
    var topicBoost: Float = 0.06
    var officialBoost: Float = 0.03
    var songRowBoost: Float = 0.04
    var lyricVideoPenalty: Float = 0.10
    var userUploadPenalty: Float = 0.05
    var unknownRuntimePenalty: Float = 0.08
    /// Words that mark a lyric video, jukebox or similar upload, which the catalogue's studio version is not.
    var lyricVideoWords: [String] = ["lyric video", "lyrical video", "lyrical", "lyrics", "jukebox", "full video", "video song", "reaction", "tutorial", "slideshow"]
    /// Words that make a recording a re-creation of the song (not the song itself) wherever they appear in its title or channel, unless the catalogue title has them too.
    var recreationWords: [String] = ["emulation", "8 bit", "8bit", "tribute", "piano version", "music box", "lullaby", "ringtone", "made famous by", "originally performed",
                                     "in the style of", "type beat", "cover", "karaoke", "midi"]
    var youTubeFamily: Set<String> = ["youtube-music", "ytmusic", "youtube", "piped", "invidious"]

    static let standard = MusicTwinRules()
}

struct MusicTwinVerdict: Sendable, Equatable {
    var accepted: Bool
    var score: Float
    var titleSimilarity: Float
    var artistSimilarity: Float
    /// The title agreed only through the phonetic key.
    var phonetic: Bool
    var deltaMs: Int64?
    /// Plain reason a copy was refused, for tests and the log.
    var reason: String?
}

enum MusicTwinSelection {
    // MARK: text agreement

    /// How well a candidate's title fits the canonical title: the best of the plain reading, the cleaned reading, and "Artist - Title" swapped.
    static func titleSimilarity(canonical: String, candidate: String) -> (value: Float, phonetic: Bool) {
        let cleaned = MusicLyricsQueryBuilder.cleanTitle(candidate)
        var texts = [cleaned.title, MusicTextMatch.coreTokens(candidate).joined(separator: " ")]
        if let lead = cleaned.leadingArtist { texts.append(lead) }
        var exact: Float = 0, soft: Float = 0
        let want = MusicTextMatch.coreTokens(canonical)
        for t in texts where !t.isEmpty {
            let plain = MusicTextMatch.similarity(want, MusicTextMatch.coreTokens(t))
            exact = max(exact, plain)
            soft = max(soft, MusicTransliterationKey.similarity(canonical, t))
        }
        // The whole canonical title sitting inside a longer upload title ("Tum Hi Ho Full Audio Song") counts as a near match.
        let wantKey = MusicText.normalize(MusicCandidateRules.latin(canonical)).split(separator: " ").map(String.init)
        let have = MusicText.normalize(MusicCandidateRules.latin(MusicCandidateRules.cleanTitle(candidate))).split(separator: " ").map(String.init)
        if wantKey.count >= 2, containsRun(have, wantKey) { exact = max(exact, 0.88) }
        let value = max(exact, soft)
        return (value, soft > exact + 0.0001 && exact < 0.8 && soft >= 0.9)
    }

    private static func containsRun(_ big: [String], _ small: [String]) -> Bool {
        guard !small.isEmpty, small.count <= big.count else { return false }
        for i in 0...(big.count - small.count) where Array(big[i..<(i + small.count)]) == small { return true }
        return false
    }

    /// 1 when the uploading channel carries a credited name, 0.9 for a phonetic match of it, 0.7 when only the title names the artist (anyone can
    /// write a name in a title), 0.5 when the candidate says nothing, 0 when the channel is somebody else.
    static func artistSimilarity(canonical: MusicCanonicalTrack, candidate: MusicAudioSource) -> Float {
        let wanted = canonical.artists.flatMap { MusicCandidateRules.nameTokens($0) }
        let channel = candidate.artist.map { MusicCandidateRules.nameTokens($0) } ?? []
        if MusicCandidateRules.namesOverlap(wanted, channel) { return 1 }
        if let share = MusicCandidateRules.sharesArtist(track: canonical.asTrack(), candidateArtist: candidate.artist, candidateTitle: candidate.title) {
            if share { return 0.7 }
        } else { return 0.5 }
        if let channel = candidate.artist.map(MusicLyricsQueryBuilder.channelCore) {
            for a in canonical.artists where MusicTransliterationKey.similarity(a, channel) >= 0.9 { return 0.9 }
        }
        return 0
    }

    private static func languageTag(_ title: String) -> String? {
        MusicCandidateRules.versionTags(title: title).first { $0.hasPrefix("lang:") }
    }

    // MARK: verdict

    static func evaluate(canonical: MusicCanonicalTrack, candidate: MusicAudioSource, rules: MusicTwinRules = .standard) -> MusicTwinVerdict {
        func refuse(_ why: String, _ t: Float = 0, _ a: Float = 0, _ p: Bool = false, _ d: Int64? = nil) -> MusicTwinVerdict {
            MusicTwinVerdict(accepted: false, score: 0, titleSimilarity: t, artistSimilarity: a, phonetic: p, deltaMs: d, reason: why)
        }
        // Version words: equal, ignoring language tags; two different named languages are two different recordings.
        let candTags = MusicCandidateRules.versionTags(title: candidate.title, album: candidate.album)
        let candVersion = Set(candTags.filter { !$0.hasPrefix("lang:") })
        if candVersion != Set(canonical.versionTags) { return refuse("version") }
        if let want = canonical.language, let got = languageTag(candidate.title)?.dropFirst(5), want.lowercased() != got.lowercased() { return refuse("language") }

        let padded = " " + MusicText.normalize(candidate.title + " " + (candidate.artist ?? "")) + " "
        let wantedPadded = " " + MusicText.normalize(canonical.title) + " "
        if let w = rules.recreationWords.first(where: { padded.contains(" " + $0 + " ") && !wantedPadded.contains(" " + $0 + " ") }) { return refuse("recreation: " + w) }
        let (title, phonetic) = titleSimilarity(canonical: canonical.title, candidate: candidate.title)
        let artist = artistSimilarity(canonical: canonical, candidate: candidate)
        let known = canonical.durationMs > 0 && (candidate.durationMs ?? 0) > 0
        let delta: Int64? = known ? abs(canonical.durationMs - (candidate.durationMs ?? 0)) : nil
        if title < rules.minimumTitleSimilarity { return refuse("title", title, artist, phonetic, delta) }

        if artist == 0 {
            let excepted = (delta.map { $0 <= rules.exactRuntimeMs } ?? false) && !phonetic && title >= 0.95
            if !excepted { return refuse("artist", title, artist, phonetic, delta) }
        }
        if phonetic, artist < 0.9 { return refuse("phonetic title needs the artist", title, artist, phonetic, delta) }
        if let delta {
            if delta > (phonetic ? rules.phoneticRuntimeWindowMs : rules.runtimeWindowMs) { return refuse("runtime", title, artist, phonetic, delta) }
        } else if phonetic { return refuse("phonetic title needs the runtime", title, artist, phonetic, nil) }
        if let flag = MusicCandidateRules.explicitMarker(in: candidate.title), flag != canonical.explicit, canonical.explicit { return refuse("explicit", title, artist, phonetic, delta) }

        var base = rules.titleWeight * title + rules.artistWeight * artist
        if title >= rules.highThreshold, artist >= rules.highThreshold { base += rules.bothHighBonus }
        var factor = rules.unknownRuntimeFactor
        if let delta { factor = rules.runtimeCurve.first { delta <= $0.0 }?.1 ?? rules.runtimeCurve.last?.1 ?? 0.7 }
        var score = base * factor
        if delta == nil { score -= rules.unknownRuntimePenalty }
        if MusicTextMatch.isTopicChannel(candidate.artist) { score += rules.topicBoost }
        else if let c = candidate.artist.map(MusicTextMatch.normalize), c.hasSuffix("vevo") || c.hasSuffix("official") { score += rules.officialBoost }
        if candidate.album != nil, rules.youTubeFamily.contains(candidate.providerID) { score += rules.songRowBoost }
        if canonical.versionTags.isEmpty {
            let padded = " " + MusicText.normalize(candidate.title) + " "
            if rules.lyricVideoWords.contains(where: { padded.contains(" " + $0 + " ") }) { score -= rules.lyricVideoPenalty }
        }
        let official = MusicTextMatch.isTopicChannel(candidate.artist) || candidate.album != nil || artist >= 0.9
        if rules.youTubeFamily.contains(candidate.providerID), !official { score -= rules.userUploadPenalty }
        score += 0.05 * min(1, max(0, candidate.confidence))
        score = max(0, score)
        let ok = score >= rules.acceptThreshold
        return MusicTwinVerdict(accepted: ok, score: score, titleSimilarity: title, artistSimilarity: artist, phonetic: phonetic, deltaMs: delta,
                                reason: ok ? nil : "score")
    }

    /// Accepted copies, best first.
    static func rank(canonical: MusicCanonicalTrack, candidates: [MusicAudioSource], rules: MusicTwinRules = .standard) -> [(source: MusicAudioSource, verdict: MusicTwinVerdict)] {
        candidates.map { ($0, evaluate(canonical: canonical, candidate: $0, rules: rules)) }.filter { $0.1.accepted }.sorted { $0.1.score > $1.1.score }
    }

    // MARK: queries

    /// Up to three search texts that use the catalogue's words: title and artist, title and film (or the plain title), then another spelling.
    static func queries(for c: MusicCanonicalTrack, limit: Int = 3) -> [String] {
        var out: [String] = []
        func add(_ s: String) {
            let t = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !t.isEmpty, !out.contains(where: { MusicText.normalize($0) == MusicText.normalize(t) }) { out.append(t) }
        }
        add(c.title + " " + c.primaryArtist)
        if let f = c.film, MusicText.normalize(f) != MusicText.normalize(c.title) { add(c.title + " " + f) } else { add(c.title) }
        if let alt = MusicTransliterationKey.alternates(of: c.title, limit: 1).first { add(alt + " " + c.primaryArtist) }
        else { add(c.title) }
        return Array(out.prefix(limit))
    }

    /// Wanted-track variants for the audio providers, in the form they read (title in `title`, artist in `artists`).
    static func variants(for c: MusicCanonicalTrack) -> [MusicTrack] {
        var base = c.asTrack()
        base.providerID = "catalogue"
        var out: [MusicTrack] = []
        var seen = Set<String>()
        func add(_ title: String, artists: [MusicArtistRef]) {
            var t = base; t.title = title; t.artists = artists
            let k = MusicText.normalize(title + " " + (artists.first?.name ?? ""))
            if !k.isEmpty, seen.insert(k).inserted { out.append(t) }
        }
        let first = Array(base.artists.prefix(1))
        add(c.title, artists: first)
        add(c.title + (c.film.flatMap { MusicText.normalize($0) == MusicText.normalize(c.title) ? nil : " " + $0 } ?? ""), artists: [])
        if let alt = MusicTransliterationKey.alternates(of: c.title, limit: 1).first { add(alt, artists: first) } else { add(c.title, artists: []) }
        return Array(out.prefix(3))
    }
}
