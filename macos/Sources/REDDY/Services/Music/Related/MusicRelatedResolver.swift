import Foundation
import Observation

// What the Related tab knows about the song that is playing: its artists, its album, more from the artist, similar artists and related songs.
// The song may come from a source that has no artist or album pages (Audius, a local file, Subsonic), so each piece is resolved in this order:
//   1. the song's own source, when it names an artist or album by a real id;
//   2. the same names searched on the sources that are switched on (the active browse source first), accepting only a close spelling match
//      (Sid Sriram, Sid Sri Ram and Sid Sree Ram are one person; Sriram alone is not) and, for albums, only one that lists the song;
//   3. otherwise what the song itself says, and nothing invented.
// Catalogue-only sources are never searched here: they supply the catalogue's spelling of a name, and their songs show only as verified playable twins.

// MARK: - names and titles

enum MusicRelatedMatch {
    /// The least a candidate scores to be taken for the same artist or title.
    static let accept: Float = 0.9

    /// 1 for the same text, 0.95 for the same sounds ("Sid Sriram" = "Sid Sri Ram"), 0.93 for the same words in another order ("Thaman S" = "S. Thaman"),
    /// else a phonetic similarity that stays below `accept`, so a shorter or longer name is never taken for the person.
    static func nameScore(_ a: String, _ b: String) -> Float {
        let na = MusicText.normalize(MusicCandidateRules.latin(a)), nb = MusicText.normalize(MusicCandidateRules.latin(b))
        guard !na.isEmpty, !nb.isEmpty else { return 0 }
        if na == nb { return 1 }
        let ka = MusicArtistCanon.key(a), kb = MusicArtistCanon.key(b)
        if !ka.isEmpty, ka == kb { return 0.95 }
        let sa = sortedKeys(na), sb = sortedKeys(nb)
        if sa.count > 1, sa == sb { return 0.93 }
        return min(0.85, MusicTransliterationKey.similarity(a, b))
    }

    private static func sortedKeys(_ normalized: String) -> [String] {
        normalized.split(separator: " ").map { MusicTransliterationKey.key(word: String($0)) }.filter { !$0.isEmpty }.sorted()
    }

    /// The same for song and album titles: brackets, film notes and credits are ignored first.
    static func titleScore(_ a: String, _ b: String) -> Float {
        let ca = MusicCandidateRules.cleanTitle(a), cb = MusicCandidateRules.cleanTitle(b)
        return MusicTransliterationKey.similarity(ca.isEmpty ? a : ca, cb.isEmpty ? b : cb)
    }

    static func sameSong(_ a: MusicTrack, _ b: MusicTrack) -> Bool { a.uid == b.uid || titleScore(a.title, b.title) >= accept }

    /// The part of a list to show when only `limit` rows fit: the start of it, moved down only as far as needed to keep the playing row in view.
    static func window(count: Int, playing: Int?, limit: Int) -> Range<Int> {
        guard count > limit, limit > 0 else { return 0..<max(0, count) }
        guard let p = playing, p >= limit else { return 0..<limit }
        let start = min(count - limit, max(0, p - limit / 2))
        return start..<(start + limit)
    }

    /// Related songs: what the source suggested, then (only when that is short) the artist's top songs and the album's songs, without repeats,
    /// without the song that is playing. Never empty while any of the three has something.
    static func songs(suggested: [MusicTrack], topSongs: [MusicTrack], albumTracks: [MusicTrack], playing: MusicTrack,
                      minimum: Int = 8, limit: Int = 20, isBlocked: (MusicTrack) -> Bool = { _ in false }) -> [MusicTrack] {
        var out: [MusicTrack] = []
        var seen: Set<String> = [playing.uid, MusicAlbumMerge.key(playing)]
        func add(_ list: [MusicTrack]) {
            for t in list where out.count < limit && !isBlocked(t) && seen.insert(t.uid).inserted {
                if !seen.insert(MusicAlbumMerge.key(t)).inserted { continue }
                out.append(t)
            }
        }
        add(suggested)
        if out.count < minimum { add(topSongs); add(albumTracks) }
        return out
    }
}

// MARK: - results

struct MusicRelatedArtist: Sendable, Equatable, Identifiable {
    enum Origin: Sendable, Equatable { case ownSource, byName, unresolved }
    /// The credit as the song gives it.
    var credited: MusicArtistRef
    /// The artist page it resolved to; nil when nothing close enough was found.
    var artist: MusicArtist?
    var origin: Origin
    var id: String { credited.name }
}

struct MusicRelatedAlbum: Sendable, Equatable {
    var knownTitle: String
    var thumbnails: [MusicThumbnail]
    var year: String?
    var trackCount: Int?
    /// The album page it resolved to; nil when the song only names an album that has no page.
    var album: MusicAlbum?
    var tracks: [MusicTrack]
    var origin: MusicRelatedArtist.Origin
}

struct MusicRelatedMore: Sendable, Equatable {
    /// The artist with whatever the overview added (biography, followers, pictures).
    var artist: MusicArtist
    var topSongs: [MusicTrack]
    var albums: [MusicAlbum]
    var similar: [MusicArtist]
}

struct MusicRelatedCanon: Sendable, Equatable {
    var title: String
    var artists: [String]
    var film: String?
    var album: String?
}

// MARK: - resolver

actor MusicRelatedResolver {
    struct Environment: Sendable {
        var isGated: @Sendable () async -> Bool = { false }
        var catalogueEnabled: @Sendable () async -> Bool = { true }
        /// A switched-on source by id.
        var provider: @Sendable (String) async -> (any MusicMetadataProvider)? = { _ in nil }
        /// The sources to search by name: switched on, able to answer, never catalogue-only; the active browse source first.
        var searchSources: @Sendable () async -> [any MusicMetadataProvider] = { [] }
        var isCatalogueOnly: @Sendable (String) async -> Bool = { _ in false }
        /// Songs of catalogue-only sources as verified playable twins; the rest are dropped.
        var playableTwins: @Sendable ([MusicTrack]) async -> [MusicTrack] = { $0 }
        var canonical: @Sendable (MusicTrack) async -> MusicRelatedCanon? = { _ in nil }
        var isBlocked: @Sendable (MusicTrack) async -> Bool = { _ in false }
        var isArtistBlocked: @Sendable (MusicArtistRef) async -> Bool = { _ in false }
        /// Songs a similarity service names for this song, already found on the person's sources. Used only when the song's own source suggests little.
        var externalSimilar: @Sendable (MusicTrack) async -> [MusicTrack] = { _ in [] }
        /// Seconds a single source may take for one question.
        var deadline: TimeInterval = 6
        init() {}
    }

    static let cacheLimit = 80
    static let topSongCount = 5
    static let albumCount = 6
    static let similarCount = 8

    private let env: Environment
    private var artistCache = Bounded<[MusicRelatedArtist]>()
    private var albumCache = Bounded<MusicRelatedAlbum?>()
    private var suggestionCache = Bounded<[MusicTrack]>()
    private var moreCache = Bounded<MusicRelatedMore?>()
    private var matchCache = Bounded<MatchedSong?>()
    /// When a cached answer was empty or unresolved (a timeout or an offline moment looks the same as "nothing there"), the answer is trusted for a short while only,
    /// so a transient failure is asked again instead of hiding a section until relaunch.
    private var degradedAt: [String: Date] = [:]
    static let degradedLife: TimeInterval = 45

    private func isFresh(_ key: String) -> Bool {
        guard let at = degradedAt[key] else { return true }
        if Date().timeIntervalSince(at) > Self.degradedLife { degradedAt[key] = nil; return false }
        return true
    }
    private func note(_ key: String, degraded: Bool) { degradedAt[key] = degraded ? Date() : nil }

    init(environment: Environment) { env = environment }

    func isGated() async -> Bool { await env.isGated() }

    /// The catalogue's spelling of the song's words, when the catalogue switch is on and it knows the song.
    private func catalogueNames(_ t: MusicTrack) async -> MusicRelatedCanon? {
        guard await env.catalogueEnabled() else { return nil }
        return await env.canonical(t)
    }

    // MARK: artists

    func artists(for track: MusicTrack) async -> [MusicRelatedArtist] {
        if await env.isGated() { return [] }
        if let hit = artistCache[track.uid], isFresh("a:" + track.uid) { return await withoutBlocked(hit) }
        var credits: [MusicArtistRef] = []
        for a in MusicTrackCells.artists(of: track) {
            let names = MusicLyricsQueryBuilder.names(a.name)
            // A credit that already carries the source's artist id is one artist, whatever its name looks like ("Hall & Oates", "AC/DC"): only a plain-text credit is split.
            if names.count <= 1 || !a.id.isEmpty { credits.append(a) } else { for n in names { credits.append(MusicArtistRef(id: "", name: n)) } }
        }
        credits = credits.filter { !MusicLyricsQueryBuilder.looksLikeChannel($0.name) }
        var seen = Set<String>()
        credits = credits.filter { seen.insert(MusicArtistCanon.key($0.name)).inserted }.prefix(2).map { $0 }
        let canon = await catalogueNames(track)
        var slots: [MusicRelatedArtist?] = Array(repeating: nil, count: credits.count)
        await withTaskGroup(of: (Int, MusicRelatedArtist?).self) { group in
            for (i, c) in credits.enumerated() { group.addTask { (i, await self.resolveArtist(c, track: track, canon: canon)) } }
            for await (i, r) in group { slots[i] = r }
        }
        let out = slots.compactMap { $0 }
        if !Task.isCancelled {
            artistCache[track.uid] = out
            note("a:" + track.uid, degraded: out.isEmpty || out.contains { $0.origin == .unresolved })
        }
        return out
    }

    private func resolveArtist(_ ref: MusicArtistRef, track: MusicTrack, canon: MusicRelatedCanon?) async -> MusicRelatedArtist? {
        if await env.isArtistBlocked(ref) { return nil }
        // 1. the song's own source
        if ref.id.isEmpty == false, ref.id != ref.name, await !env.isCatalogueOnly(track.providerID), let p = await env.provider(track.providerID),
           let a = try? await MusicStreamResolver.withDeadline(env.deadline, { try await p.artist(id: ref.id) }),
           MusicRelatedMatch.nameScore(ref.name, a.name) >= 0.7 {
            return MusicRelatedArtist(credited: ref, artist: Self.withPortrait(a, from: ref), origin: .ownSource)
        }
        if Task.isCancelled { return nil }
        // 2. the name, searched on the other sources (the catalogue's spelling is a second thing to ask with)
        var names = [ref.name]
        for c in canon?.artists ?? [] where MusicRelatedMatch.nameScore(ref.name, c) >= MusicRelatedMatch.accept && !names.contains(c) { names.append(c) }
        let sources = await env.searchSources()
        let spellings = names
        var found: [(artist: MusicArtist, score: Float, order: Int)] = []
        var answered = 0
        await withTaskGroup(of: (Int, Bool, [(MusicArtist, Float)]).self) { group in
            for (i, p) in sources.enumerated() {
                group.addTask { let r = await self.searchArtist(names: spellings, in: p); return (i, r.0, r.1) }
            }
            for await (i, ok, hits) in group {
                if ok { answered += 1 }
                for h in hits { found.append((h.0, h.1, i)) }
            }
        }
        if let best = found.sorted(by: { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }).first {
            let same = found.filter { $0.artist.providerID != best.artist.providerID }.map(\.artist)
            let merged = MusicArtistCanon.merge([best.artist] + same).first ?? best.artist
            var a = merged
            a.id = best.artist.id; a.providerID = best.artist.providerID
            return MusicRelatedArtist(credited: ref, artist: a, origin: .byName)
        }
        if Task.isCancelled { return nil }
        // 3. the same song found on a source that knows its artists by id
        if let m = await matchedSong(for: track, canon: canon),
           let hit = m.track.artists.first(where: { !$0.id.isEmpty && MusicRelatedMatch.nameScore($0.name, ref.name) >= MusicRelatedMatch.accept }),
           let p = await env.provider(m.track.providerID),
           let a = try? await MusicStreamResolver.withDeadline(env.deadline, { try await p.artist(id: hit.id) }),
           MusicRelatedMatch.nameScore(ref.name, a.name) >= MusicRelatedMatch.accept {
            return MusicRelatedArtist(credited: ref, artist: Self.withPortrait(a, from: hit), origin: .byName)
        }
        return MusicRelatedArtist(credited: ref, artist: nil, origin: .unresolved)
    }

    /// The best close match for any of the spellings on one source: (answered, hits at or above the threshold).
    private func searchArtist(names: [String], in p: any MusicMetadataProvider) async -> (Bool, [(MusicArtist, Float)]) {
        var answered = false
        for n in names {
            if Task.isCancelled { break }
            guard let page = try? await MusicStreamResolver.withDeadline(env.deadline, { try await p.searchArtists(n, page: nil) }) else { continue }
            answered = true
            let hits = page.items.prefix(8).compactMap { a -> (MusicArtist, Float)? in
                let s = names.map { MusicRelatedMatch.nameScore($0, a.name) }.max() ?? 0
                return s >= MusicRelatedMatch.accept ? (a, s) : nil
            }
            if !hits.isEmpty { return (true, Array(hits)) }
        }
        return (answered, [])
    }

    private static func withPortrait(_ a: MusicArtist, from ref: MusicArtistRef) -> MusicArtist {
        var x = a
        if x.thumbnails.isEmpty { x.thumbnails = ref.thumbnails }
        return x
    }

    // MARK: same song elsewhere

    struct MatchedSong: Sendable, Equatable { var track: MusicTrack }

    /// The playing song found by title and artist on a source that knows it by id, so its artists and album can be followed. Nil when none matches.
    func matchedSong(for track: MusicTrack, canon: MusicRelatedCanon? = nil) async -> MatchedSong? {
        if let hit = matchCache[track.uid], isFresh("m:" + track.uid) { return hit }
        let artist = MusicTrackCells.artists(of: track).first?.name ?? ""
        let title = MusicCandidateRules.cleanTitle(track.title)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        var result: MatchedSong?
        for p in await env.searchSources() {
            if Task.isCancelled { return nil }
            guard let page = try? await MusicStreamResolver.withDeadline(env.deadline, { try await p.searchTracks(title + " " + artist, page: nil) }) else { continue }
            if let t = page.items.prefix(8).first(where: { c in
                MusicRelatedMatch.titleScore(c.title, title) >= MusicRelatedMatch.accept
                    && c.artists.contains { MusicRelatedMatch.nameScore($0.name, artist) >= MusicRelatedMatch.accept }
            }) { result = MatchedSong(track: t); break }
        }
        if !Task.isCancelled { matchCache[track.uid] = .some(result); note("m:" + track.uid, degraded: result == nil) }
        return result
    }

    // MARK: album

    func album(for track: MusicTrack) async -> MusicRelatedAlbum? {
        if await env.isGated() { return nil }
        if let hit = albumCache[track.uid], isFresh("b:" + track.uid) { return hit }
        let canon = await catalogueNames(track)
        let out = await resolveAlbum(track, canon: canon)
        if !Task.isCancelled { albumCache[track.uid] = .some(out); note("b:" + track.uid, degraded: out == nil || out?.origin == .unresolved) }
        return out
    }

    private func resolveAlbum(_ t: MusicTrack, canon: MusicRelatedCanon?) async -> MusicRelatedAlbum? {
        let own = t.album.flatMap { $0.title.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let credited = MusicTrackCells.artists(of: t).map(\.name)
        func known(_ origin: MusicRelatedArtist.Origin) -> MusicRelatedAlbum? {
            guard let own else { return nil }
            return MusicRelatedAlbum(knownTitle: own.title, thumbnails: own.thumbnails, year: Self.year(own.releaseDate), trackCount: own.totalTracks,
                                     album: nil, tracks: [], origin: origin)
        }
        // 1. the song's own source
        if let own, own.id.isEmpty == false, own.id != own.title, await !env.isCatalogueOnly(t.providerID), let p = await env.provider(t.providerID),
           let found = await fetchAlbum(id: own.id, provider: p, ref: own) {
            return Self.compose(found.album, tracks: found.tracks, known: own, origin: .ownSource)
        }
        if Task.isCancelled { return nil }
        // 2. the album (or film) title searched on the other sources; the album must list the song
        var titles: [String] = []
        func addTitle(_ s: String?) {
            guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let clean = MusicCandidateRules.cleanTitle(s)
            let v = clean.isEmpty ? s : clean
            if !titles.contains(where: { MusicRelatedMatch.titleScore($0, v) >= MusicRelatedMatch.accept }) { titles.append(v) }
        }
        addTitle(own?.title); addTitle(canon?.film); addTitle(canon?.album)
        let sources = await env.searchSources()
        let wanted = titles
        if !titles.isEmpty {
            var cands: [(album: MusicAlbum, tracks: [MusicTrack], score: Float, order: Int)] = []
            var answered = 0
            await withTaskGroup(of: (Int, Bool, MusicAlbum?, [MusicTrack], Float).self) { group in
                for (i, p) in sources.enumerated() {
                    group.addTask {
                        let r = await self.searchAlbum(titles: wanted, credited: credited, song: t, in: p)
                        return (i, r.answered, r.album, r.tracks, r.score)
                    }
                }
                for await (i, ok, a, tr, s) in group {
                    if ok { answered += 1 }
                    if let a { cands.append((a, tr, s, i)) }
                }
            }
            if let best = cands.sorted(by: { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }).first {
                return Self.compose(best.album, tracks: best.tracks, known: own, origin: .byName)
            }
        }
        if Task.isCancelled { return nil }
        // 3. the same song on a source that knows its album by id
        if let m = await matchedSong(for: t, canon: canon), let ref = m.track.album, !ref.id.isEmpty, let p = await env.provider(m.track.providerID),
           let found = await fetchAlbum(id: ref.id, provider: p, ref: ref) {
            return Self.compose(found.album, tracks: found.tracks, known: own ?? ref, origin: .byName)
        }
        return known(.unresolved)
    }

    /// One source's best album for the titles: it must be named like one of them and list the song (or, when its list cannot be read, credit one of the artists).
    private func searchAlbum(titles: [String], credited: [String], song: MusicTrack, in p: any MusicMetadataProvider) async -> (answered: Bool, album: MusicAlbum?, tracks: [MusicTrack], score: Float) {
        var answered = false
        let lead = credited.first ?? ""
        for title in titles {
            for query in lead.isEmpty ? [title] : [title + " " + lead, title] {
                if Task.isCancelled { return (answered, nil, [], 0) }
                guard let page = try? await MusicStreamResolver.withDeadline(env.deadline, { try await p.searchAlbums(query, page: nil) }) else { continue }
                answered = true
                let ranked = page.items.prefix(8).map { ($0, MusicRelatedMatch.titleScore(title, $0.title)) }
                    .filter { $0.1 >= MusicRelatedMatch.accept }.sorted { $0.1 > $1.1 }.prefix(3)
                for (a, score) in ranked {
                    if let list = try? await MusicStreamResolver.withDeadline(env.deadline, { try await p.albumTracks(id: a.id, page: nil) }) {
                        if list.items.contains(where: { MusicRelatedMatch.titleScore($0.title, song.title) >= MusicRelatedMatch.accept }) { return (true, a, list.items, score) }
                    } else if a.artists.contains(where: { r in credited.contains { MusicRelatedMatch.nameScore($0, r.name) >= MusicRelatedMatch.accept } }) {
                        return (true, a, [], score * 0.9)
                    }
                }
            }
        }
        return (answered, nil, [], 0)
    }

    private func fetchAlbum(id: String, provider p: any MusicMetadataProvider, ref: MusicAlbumRef) async -> (album: MusicAlbum, tracks: [MusicTrack])? {
        async let a = try? await MusicStreamResolver.withDeadline(env.deadline, { try await p.album(id: id) })
        async let l = try? await MusicStreamResolver.withDeadline(env.deadline, { try await p.albumTracks(id: id, page: nil) })
        let album = await a, list = await l
        if album == nil && list == nil { return nil }
        let base = album ?? MusicAlbum(id: id, providerID: p.id, title: ref.title, artists: ref.artists, thumbnails: ref.thumbnails,
                                       releaseDate: ref.releaseDate, totalTracks: ref.totalTracks, albumType: ref.albumType, externalURL: ref.externalURL)
        return (base, list?.items ?? [])
    }

    private static func compose(_ a: MusicAlbum, tracks: [MusicTrack], known: MusicAlbumRef?, origin: MusicRelatedArtist.Origin) -> MusicRelatedAlbum {
        MusicRelatedAlbum(knownTitle: a.title.isEmpty ? (known?.title ?? "") : a.title,
                          thumbnails: a.thumbnails.isEmpty ? (known?.thumbnails ?? []) : a.thumbnails,
                          year: year(a.releaseDate ?? known?.releaseDate), trackCount: a.totalTracks ?? (tracks.isEmpty ? known?.totalTracks : tracks.count),
                          album: a, tracks: tracks, origin: origin)
    }

    static func year(_ date: String?) -> String? {
        guard let d = date, d.count >= 4, let y = Int(d.prefix(4)), y > 1000 else { return nil }
        return String(y)
    }

    // MARK: related songs

    /// What the song's own source (or, failing that, the same song on another source) suggests. Blocked songs and the song itself are left out.
    func suggestions(for track: MusicTrack) async -> [MusicTrack] {
        if await env.isGated() { return [] }
        if let hit = suggestionCache[track.uid], isFresh("s:" + track.uid) { return hit }
        var list: [MusicTrack] = []
        if let p = await env.provider(track.providerID), let r = try? await MusicStreamResolver.withDeadline(env.deadline, { try await p.recommendations(seedTrackIDs: [track.id], limit: 20) }) { list = r }
        if list.isEmpty, !Task.isCancelled, let m = await matchedSong(for: track), m.track.providerID != track.providerID, let p = await env.provider(m.track.providerID),
           let r = try? await MusicStreamResolver.withDeadline(env.deadline, { try await p.recommendations(seedTrackIDs: [m.track.id], limit: 20) }) { list = r }
        if list.count < 12, !Task.isCancelled { list += await env.externalSimilar(track) }
        let out = await usable(list, excluding: track)
        if !Task.isCancelled { suggestionCache[track.uid] = out; note("s:" + track.uid, degraded: out.isEmpty) }
        return out
    }

    private func usable(_ list: [MusicTrack], excluding playing: MusicTrack?) async -> [MusicTrack] {
        var kept: [MusicTrack] = []
        var twinNeeded: [MusicTrack] = []
        for t in list {
            if t.uid == playing?.uid || (t.isPodcast ?? false) { continue }
            if await env.isBlocked(t) { continue }
            if await env.isCatalogueOnly(t.providerID) { twinNeeded.append(t) } else { kept.append(t) }
        }
        if !twinNeeded.isEmpty { kept += await env.playableTwins(twinNeeded) }
        return kept
    }

    // MARK: more from the artist

    /// The artist's top songs, albums and related artists, from the source the artist page belongs to. Partial answers are kept.
    /// A cached answer is read again against the block list: an artist blocked after it was cached must not come back from it.
    private func withoutBlocked(_ list: [MusicRelatedArtist]) async -> [MusicRelatedArtist] {
        var out: [MusicRelatedArtist] = []
        for e in list {
            if let a = e.artist, await env.isArtistBlocked(MusicArtistRef(id: a.id, name: a.name)) { continue }
            out.append(e)
        }
        return out
    }

    private func withoutBlocked(_ more: MusicRelatedMore) async -> MusicRelatedMore {
        var m = more
        var similar: [MusicArtist] = []
        for a in more.similar where !(await env.isArtistBlocked(MusicArtistRef(id: a.id, name: a.name))) { similar.append(a) }
        m.similar = similar
        return m
    }

    func more(for artist: MusicArtist) async -> MusicRelatedMore? {
        if await env.isGated() { return nil }
        if let hit = moreCache[artist.uid], isFresh("r:" + artist.uid) {
            guard let cached = hit else { return nil }   // an earlier miss is remembered for the same short time
            return await withoutBlocked(cached)
        }
        guard await !env.isCatalogueOnly(artist.providerID), let p = await env.provider(artist.providerID) else { return nil }
        let id = artist.id, deadline = env.deadline
        var detail = artist
        var tops: [MusicTrack] = [], albums: [MusicAlbum] = [], related: [MusicArtist] = []
        if let o = try? await MusicStreamResolver.withDeadline(deadline, { try await p.artistOverview(id: id) }) {
            detail = Self.enriched(artist, with: o.artist); tops = o.topTracks; albums = o.albums; related = o.related
        } else if !Task.isCancelled {
            async let a = try? await MusicStreamResolver.withDeadline(deadline, { try await p.artist(id: id) })
            async let t = try? await MusicStreamResolver.withDeadline(deadline, { try await p.artistTopTracks(id: id) })
            async let al = try? await MusicStreamResolver.withDeadline(deadline, { try await p.artistAlbums(id: id, page: nil) })
            async let r = try? await MusicStreamResolver.withDeadline(deadline, { try await p.relatedArtists(id: id) })
            if let x = await a { detail = Self.enriched(artist, with: x) }
            tops = await t ?? []; albums = await al?.items ?? []; related = await r ?? []
        }
        let selfKey = MusicArtistCanon.key(artist.name)
        var seenAlbums = Set<String>()
        let albumList = albums.filter { seenAlbums.insert(MusicText.normalize($0.title)).inserted }.prefix(Self.albumCount)
        var seenArtists: Set<String> = [selfKey]
        var similar: [MusicArtist] = []
        for r in related where similar.count < Self.similarCount {
            let ref = MusicArtistRef(id: r.id, name: r.name)
            if await env.isArtistBlocked(ref) { continue }
            let k = MusicArtistCanon.key(r.name)
            if r.id != artist.id, seenArtists.insert(k).inserted { similar.append(r) }
        }
        let usableTops = await usable(tops, excluding: nil)
        let out = MusicRelatedMore(artist: detail, topSongs: usableTops, albums: Array(albumList), similar: similar)
        if !Task.isCancelled { moreCache[artist.uid] = .some(out); note("r:" + artist.uid, degraded: out.topSongs.isEmpty && out.albums.isEmpty && out.similar.isEmpty) }
        return out
    }

    /// The overview's artist adds what the search row lacked; the identity and the pictures already chosen stay.
    private static func enriched(_ base: MusicArtist, with detail: MusicArtist) -> MusicArtist {
        var a = base
        if (a.bio ?? "").isEmpty { a.bio = detail.bio }
        if a.followers == nil { a.followers = detail.followers }
        if a.genres.isEmpty { a.genres = detail.genres }
        if a.thumbnails.isEmpty || !a.thumbnails.contains(where: MusicArtistPortrait.isPlausible) { a.thumbnails = detail.thumbnails + a.thumbnails }
        if a.externalURL == nil { a.externalURL = detail.externalURL }
        return a
    }

    // MARK: bounded memory cache

    struct Bounded<V: Sendable> {
        private var values: [String: V] = [:]
        private var order: [String] = []
        subscript(key: String) -> V? {
            get { values[key] }
            set {
                guard let newValue else { values[key] = nil; order.removeAll { $0 == key }; return }
                if values[key] == nil { order.append(key) }
                values[key] = newValue
                while order.count > MusicRelatedResolver.cacheLimit { values[order.removeFirst()] = nil }
            }
        }
    }
}

// MARK: - what the tab shows

enum MusicRelatedPhase<T: Sendable & Equatable>: Sendable, Equatable {
    case loading, loaded(T), hidden
    var value: T? { if case .loaded(let v) = self { v } else { nil } }
    var isLoading: Bool { if case .loading = self { true } else { false } }
}

/// The state of the Related tab for one song at a time. Each section fills in as its own answer arrives; a failed or empty one hides.
/// `load` is meant to run in `.task(id:)`: it ends early when cancelled, and an answer that arrives for an earlier song is dropped.
@MainActor @Observable
final class MusicRelatedModel {
    private(set) var trackUID: String?
    private(set) var gated = false
    private(set) var artists: MusicRelatedPhase<[MusicRelatedArtist]> = .loading
    private(set) var album: MusicRelatedPhase<MusicRelatedAlbum> = .loading
    private(set) var topSongs: MusicRelatedPhase<[MusicTrack]> = .loading
    private(set) var albums: MusicRelatedPhase<[MusicAlbum]> = .loading
    private(set) var similar: MusicRelatedPhase<[MusicArtist]> = .loading
    private(set) var songs: MusicRelatedPhase<[MusicTrack]> = .loading
    /// True once every section finished and none of them has anything beyond the song's own words.
    private(set) var finishedEmpty = false
    /// The artist whose page feeds "More from" and "Similar artists".
    private(set) var primary: MusicArtist?

    private let resolver: MusicRelatedResolver
    private let isBlocked: @MainActor (MusicTrack) -> Bool

    init(resolver: MusicRelatedResolver, isBlocked: @escaping @MainActor (MusicTrack) -> Bool = { _ in false }) {
        self.resolver = resolver; self.isBlocked = isBlocked
    }

    private enum Part: Sendable {
        case top([MusicTrack]), albumTracks([MusicTrack]), suggested([MusicTrack])
    }

    /// When the answers for `completedUID` were finished: coming back to the tab for the same song within this time keeps what is on screen (no skeletons, no jump).
    private var completedUID: String?
    private var completedAt = Date.distantPast
    static let keepSeconds: TimeInterval = 120

    func load(_ track: MusicTrack?) async {
        guard let t = track else { completedUID = nil; reset(nil); return }
        let uid = t.uid
        if completedUID == uid, trackUID == uid, Date().timeIntervalSince(completedAt) < Self.keepSeconds { return }
        completedUID = nil
        reset(uid)
        if await resolver.isGated() {
            guard trackUID == uid, !Task.isCancelled else { return }
            gated = true; artists = .hidden; album = .hidden; topSongs = .hidden; albums = .hidden; similar = .hidden; songs = .hidden; finishedEmpty = true
            return
        }
        var top: [MusicTrack] = [], fromAlbum: [MusicTrack] = [], suggested: [MusicTrack] = []
        async let p1 = loadArtists(t, uid: uid)
        async let p2 = loadAlbum(t, uid: uid)
        async let p3 = loadSuggestions(t, uid: uid)
        let parts = await [p1, p2, p3]
        for part in parts {
            switch part {
            case .top(let l)?: top = l
            case .albumTracks(let l)?: fromAlbum = l
            case .suggested(let l)?: suggested = l
            case nil: break
            }
        }
        guard alive(uid) else { return }
        let list = MusicRelatedMatch.songs(suggested: suggested, topSongs: top, albumTracks: fromAlbum, playing: t, isBlocked: isBlocked)
        songs = list.isEmpty ? .hidden : .loaded(list)
        let hasMore = (artists.value ?? []).contains { $0.artist != nil } || (album.value?.album != nil) || !list.isEmpty
        finishedEmpty = !hasMore
        completedUID = uid; completedAt = Date()
    }

    private func loadArtists(_ t: MusicTrack, uid: String) async -> Part? {
        let list = await resolver.artists(for: t)
        guard alive(uid) else { return nil }
        artists = list.isEmpty ? .hidden : .loaded(list)
        guard let lead = list.first(where: { $0.artist != nil })?.artist else {
            topSongs = .hidden; albums = .hidden; similar = .hidden; return .top([])
        }
        primary = lead
        let more = await resolver.more(for: lead)
        guard alive(uid) else { return nil }
        if let more {
            primary = more.artist
            artists = .loaded(list.map { e in var x = e; if x.artist?.uid == lead.uid { x.artist = more.artist }; return x })
            // Emptiness is judged after the playing song is taken out: an artist whose only top song is this one has nothing to show under "More from".
            let rest = Array(more.topSongs.filter { !MusicRelatedMatch.sameSong($0, t) && !isBlocked($0) }.prefix(MusicRelatedResolver.topSongCount))   // a song blocked after the answer was cached must not come back
            topSongs = rest.isEmpty ? .hidden : .loaded(rest)
            // The album that is playing already has its own card above this shelf.
            let playingAlbumID = album.value?.album?.id ?? t.album?.id ?? ""
            let playingAlbumTitle = MusicText.normalize(album.value?.album?.title ?? t.album?.title ?? "")
            let otherAlbums = more.albums.filter { a in !(!playingAlbumID.isEmpty && a.id == playingAlbumID) && (playingAlbumTitle.isEmpty || MusicText.normalize(a.title) != playingAlbumTitle) }
            albums = otherAlbums.isEmpty ? .hidden : .loaded(otherAlbums)
            similar = more.similar.isEmpty ? .hidden : .loaded(more.similar)
            return .top(more.topSongs)
        }
        topSongs = .hidden; albums = .hidden; similar = .hidden
        return .top([])
    }
    private func loadAlbum(_ t: MusicTrack, uid: String) async -> Part? {
        let a = await resolver.album(for: t)
                guard alive(uid) else { return nil }
        if let a { album = .loaded(a) } else { album = .hidden }
        return .albumTracks(a?.tracks ?? [])
    }
    private func loadSuggestions(_ t: MusicTrack, uid: String) async -> Part? {
        let list = await resolver.suggestions(for: t)
                guard alive(uid) else { return nil }
        if !list.isEmpty { songs = .loaded(list) }
        return .suggested(list)
    }
    private func alive(_ uid: String) -> Bool { !Task.isCancelled && trackUID == uid }

    private func reset(_ uid: String?) {
        trackUID = uid; gated = false; finishedEmpty = false; primary = nil
        let start: MusicRelatedPhase<[MusicRelatedArtist]> = uid == nil ? .hidden : .loading
        artists = start
        album = uid == nil ? .hidden : .loading
        topSongs = uid == nil ? .hidden : .loading
        albums = uid == nil ? .hidden : .loading
        similar = uid == nil ? .hidden : .loading
        songs = uid == nil ? .hidden : .loading
    }
}
