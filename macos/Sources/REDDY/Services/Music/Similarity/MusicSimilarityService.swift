import Foundation

// The part between "a service says these songs are similar" and "these songs can play": it asks Last.fm and ListenBrainz (cooling a service down when it fails),
// merges and de-duplicates what they say, finds each song on the music sources the person has switched on, and keeps only a close match of both title and
// artist. Personal suggestions honour Private listening, a reset of recommendations and a thin history; suggestions tied to a song, an artist or a tag are not
// personal and never claim to be a chart for a country or region.

enum MusicSimilaritySupport {
    static func merged(_ lists: [[MusicSimilarCandidate]]) -> [MusicSimilarCandidate] { MusicSimilarityRules.merged(lists) }
}

enum MusicSimilarityRules {
    /// What personal suggestions may do right now.
    enum Personal: Equatable, Sendable {
        case allowed
        /// A private session: nothing personal is asked for or shown.
        case privateSession
        /// Too little listening to personalise: no generic list stands in for it.
        case coldStart
    }

    static let minimumSeeds = 3

    /// `seedCount` counts only listening that still counts: after a reset, plays before the reset are not seeds.
    static func personal(isPrivate: Bool, seedCount: Int) -> Personal {
        if isPrivate { return .privateSession }
        return seedCount >= minimumSeeds ? .allowed : .coldStart
    }

    /// ListenBrainz builds its personal list on its own server from every listen it holds, including those from before a reset, so after a reset that list is not used.
    static func listenBrainzMayPersonalise(resetAt: Date?) -> Bool { resetAt == nil }

    /// One list from several services: the same recording (by MusicBrainz id, else folded title and artist) appears once, with the best score and the number of
    /// services that named it, ordered by score then by how many agreed.
    static func merged(_ lists: [[MusicSimilarCandidate]]) -> [MusicSimilarCandidate] {
        var by: [String: (item: MusicSimilarCandidate, votes: Int)] = [:]
        for list in lists {
            for c in list {
                guard let title = c.title, !title.isEmpty else { continue }
                let key = c.mbid.map { "mbid:" + $0.lowercased() } ?? "t:" + MusicText.normalize(title) + "|" + MusicText.normalize(c.artist)
                if var e = by[key] { e.votes += 1; if c.score > e.item.score { e.item = c }; by[key] = e } else { by[key] = (c, 1) }
            }
        }
        return by.values.sorted { $0.item.score != $1.item.score ? $0.item.score > $1.item.score : ($0.votes != $1.votes ? $0.votes > $1.votes : ($0.item.title ?? "") < ($1.item.title ?? "")) }.map(\.item)
    }

    /// Whether a found song is the one the service meant: the title and the artist both match closely.
    static func isSame(_ candidate: MusicSimilarCandidate, _ track: MusicTrack) -> Bool {
        guard let title = candidate.title else { return false }
        guard MusicRelatedMatch.titleScore(title, track.title) >= MusicRelatedMatch.accept else { return false }
        return track.artists.contains { MusicRelatedMatch.nameScore(candidate.artist, $0.name) >= MusicRelatedMatch.accept }
    }

    /// The languages a person's own plays are in, worked out from what they played and never from a country, a setting or a name: every language whose share of their
    /// plays (songs whose language is known, Latin-script and unknown ones left out) reaches `minShare`. Empty when there is too little to say, so nothing is filtered.
    nonisolated static func listenedLanguages(_ tracks: [MusicTrack], known: [String: MusicLanguage] = [:], minShare: Double = 0.12, minKnown: Int = 8) -> Set<MusicLanguage> {
        var counts: [MusicLanguage: Int] = [:]
        for t in tracks { if let l = MusicLanguageDetector.language(of: t).flatMap({ $0 == .latin ? nil : $0 }) ?? known[t.uid] { counts[l, default: 0] += 1 } }
        let total = counts.values.reduce(0, +)
        guard total >= minKnown else { return [] }
        var out = Set(counts.filter { Double($0.value) / Double(total) >= minShare }.map(\.key))
        // Marathi and Hindi share a script, and a stated language of one of them stands for the other only when the person plays both: nothing is merged here.
        if out.isEmpty, let top = counts.max(by: { $0.value < $1.value }) { out = [top.key] }
        return out
    }

    /// Candidates a person's own filters rule out: a language they chose to keep, or an artist or song they hid or blocked.
    static func filtered(_ tracks: [MusicTrack], hidden: MusicHiddenSet, isBlocked: (MusicTrack) -> Bool, languages: Set<MusicLanguage>?, known: [String: MusicLanguage] = [:]) -> [MusicTrack] {
        tracks.filter { t in
            if hidden.hides(t) || isBlocked(t) { return false }
            let found = MusicLanguageDetector.language(of: t).flatMap { $0 == .latin ? nil : $0 } ?? known[t.uid]
            guard let languages, !languages.isEmpty, let l = found else { return true }
            // A song written in Latin letters says nothing about its language; only a clearly different script is dropped.
            return l == .latin || languages.contains(l)
        }
    }
}

actor MusicSimilarityService {
    static let shared = MusicSimilarityService()

    private var lastFM = LastFMReadClient()
    private var listenBrainz = ListenBrainzReadClient()
    private var cache: [String: (at: Date, items: [MusicSimilarCandidate])] = [:]
    static let cacheSeconds: TimeInterval = 6 * 3600

    func configure(lastFM: LastFMReadClient, listenBrainz: ListenBrainzReadClient) { self.lastFM = lastFM; self.listenBrainz = listenBrainz; cache = [:] }
    func clearCache() { cache = [:] }

    private func cached(_ key: String, now: Date = Date()) -> [MusicSimilarCandidate]? {
        guard let c = cache[key], now.timeIntervalSince(c.at) < Self.cacheSeconds else { return nil }
        return c.items
    }

    private func guarded(_ source: String, _ body: () async throws -> [MusicSimilarCandidate]) async -> [MusicSimilarCandidate] {
        guard await MusicSourceCooldown.shared.allowed(source) else { return [] }
        do { return try await body() } catch is CancellationError { return [] } catch {
            if let e = error as? LastFMAPIError, !LastFMReadClient.isCoolingError(e.code) { return [] }
            await MusicSourceCooldown.shared.fail(source)
            return []
        }
    }

    /// Songs like this one: Last.fm's similar tracks, and when it has none, the top songs of Last.fm's similar artists would need a catalogue lookup, so they are
    /// left to the sources' own artist pages. Not personal: it depends only on the song.
    func similar(to track: MusicTrack, limit: Int = 25) async -> [MusicSimilarCandidate] {
        guard lastFM.isAvailable, let artist = track.artists.first(where: { MusicCompilationArtist.isUsableArtist($0) })?.name else { return [] }
        let key = "t|" + MusicText.normalize(artist) + "|" + MusicText.normalize(track.title)
        if let hit = cached(key) { return hit }
        let list = await guarded("lastfm") { try await lastFM.similarTracks(artist: artist, title: track.title, mbid: nil, limit: limit) }
        let out = MusicSimilarityRules.merged([list])
        if !out.isEmpty { cache[key] = (Date(), out) }
        return out
    }

    /// Songs under a tag the person chose (a genre they like). Not personal and not regional.
    func songs(forTag tag: String, limit: Int = 30) async -> [MusicSimilarCandidate] {
        guard lastFM.isAvailable else { return [] }
        let key = "g|" + MusicText.normalize(tag)
        if let hit = cached(key) { return hit }
        let list = await guarded("lastfm") { try await lastFM.tagTracks(tag, limit: limit) }
        if !list.isEmpty { cache[key] = (Date(), list) }
        return list
    }

    /// ListenBrainz's own list for the person. Only when personalising is allowed; an empty answer is a normal one for a thin history.
    func personal(_ state: MusicSimilarityRules.Personal, afterReset: Bool, count: Int = 25) async -> [MusicSimilarCandidate] {
        guard state == .allowed, MusicSimilarityRules.listenBrainzMayPersonalise(resetAt: afterReset ? Date() : nil), listenBrainz.isAvailable else { return [] }
        let key = "p|" + (listenBrainz.user ?? "")
        if let hit = cached(key) { return hit }
        let list = await guarded("listenbrainz") { try await listenBrainz.candidates(count: count) }
        if !list.isEmpty { cache[key] = (Date(), list) }
        return list
    }

    /// Finds each candidate on the sources the person has on, in order, and keeps the first song that matches both title and artist. Stops at `limit`.
    func resolve(_ candidates: [MusicSimilarCandidate], using sources: [any MusicMetadataProvider], limit: Int = 12) async -> [MusicTrack] {
        var out: [MusicTrack] = []
        var seen = Set<String>()
        for c in candidates {
            if out.count >= limit || Task.isCancelled { break }
            guard let title = c.title else { continue }
            let query = title + " " + c.artist
            for p in sources {
                guard let page = try? await p.searchTracks(query, page: nil), let hit = page.items.first(where: { MusicSimilarityRules.isSame(c, $0) }) else { continue }
                if seen.insert(hit.uid).inserted, seen.insert("v:" + MusicAutoplaySelector.versionKey(hit)).inserted { out.append(hit) }
                break
            }
        }
        return out
    }
}
