import Foundation

// Pure rules of the film page: how credits are ordered and folded, which soundtrack matches are shown and how, how songs are arranged and
// turned into playable tracks, and how the singers are counted. No store, no player, no clock: a value in, a value out.

enum MusicFilmPageBuilders {
    /// The crew roles the page lists, in the order they are listed.
    static let crewOrder: [MusicRole] = [.director, .screenwriter, .writer, .producer, .musicDirector, .composer, .cinematographer, .editor]

    /// The crew role of a film credit edge, or nil when the edge is not a crew credit (cast, soundtrack, language...).
    static func crewRole(of e: MusicEdge) -> MusicRole? {
        let role: MusicRole?
        switch e.predicate {
        case .directedBy: role = e.role ?? .director
        case .producedBy: role = e.role ?? .producer
        case .composedBy: role = e.role ?? .composer
        case .musicDirectedBy: role = e.role ?? .musicDirector
        case .writtenBy: role = (e.role == .writer ? .screenwriter : e.role) ?? .screenwriter   // writing is one job whichever of its two names a source used
        default: role = nil
        }
        guard let r = role, crewOrder.contains(r) else { return nil }
        return r
    }

    /// Billing order, one entry per person, and a name-only entry dropped when the same name is also known by id.
    static func cast(_ people: [MusicFilmPersonItem]) -> [MusicFilmPersonItem] {
        let sorted = people.enumerated().sorted { a, b in
            let x = a.element.order ?? Int.max, y = b.element.order ?? Int.max
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
        let named = Set(sorted.filter { !$0.nameOnly }.map { MusicGraphText.latin($0.name) })
        var seen = Set<MusicEntityID>()
        var out: [MusicFilmPersonItem] = []
        for p in sorted {
            if p.nameOnly, named.contains(MusicGraphText.latin(p.name)) { continue }
            guard seen.insert(p.person).inserted else { continue }
            out.append(p)
        }
        return out
    }

    /// Crew grouped by role in `crewOrder`. When the composers are exactly the music directors, one line (music director) is kept.
    static func crew(_ people: [MusicFilmPersonItem]) -> [MusicFilmCrewItem] {
        var groups: [MusicRole: [MusicFilmPersonItem]] = [:]
        for p in people { groups[p.role, default: []].append(p) }
        for r in groups.keys {
            var seen = Set<MusicEntityID>()
            groups[r] = groups[r]!.sorted { ($0.order ?? Int.max) < ($1.order ?? Int.max) }.filter { seen.insert($0.person).inserted }.prefix(MusicFilmGraphReading.crewPerRole).map { $0 }
        }
        if let c = groups[.composer], let m = groups[.musicDirector], Set(c.map(\.person)) == Set(m.map(\.person)) { groups[.composer] = nil }
        return crewOrder.compactMap { r in groups[r].flatMap { $0.isEmpty ? nil : MusicFilmCrewItem(role: r, people: $0) } }
    }

    /// The singers of the film's songs, the ones with most songs first (ties keep the order of first appearance).
    static func singers(from songs: [MusicFilmSongItem]) -> [MusicFilmSingerItem] {
        var order: [MusicEntityID] = []
        var counts: [MusicEntityID: Int] = [:]
        var info: [MusicEntityID: MusicFilmSingerRef] = [:]
        // A provisional singer joins the one established person of the same name, when there is exactly one.
        var byName: [String: Set<MusicEntityID>] = [:]
        for s in songs { for r in s.singers where r.established { byName[MusicGraphText.latin(r.name), default: []].insert(r.person) } }
        for s in songs {
            for var ref in s.singers {
                if !ref.established, let only = byName[MusicGraphText.latin(ref.name)], only.count == 1, let target = only.first,
                   let full = songs.lazy.flatMap(\.singers).first(where: { $0.person == target }) { ref = full }
                if counts[ref.person] == nil { order.append(ref.person); info[ref.person] = ref }
                counts[ref.person, default: 0] += 1
            }
        }
        return order.enumerated().sorted { a, b in
            let x = counts[a.element] ?? 0, y = counts[b.element] ?? 0
            return x != y ? x > y : a.offset < b.offset
        }.map { e in MusicFilmSingerItem(person: e.element, name: info[e.element]!.name, imageRef: info[e.element]!.imageRef, songCount: counts[e.element] ?? 0) }
    }

    /// What the page shows for the music of a film once every section has settled: the sections, or one quiet line.
    enum MusicPlan: Equatable, Sendable { case loading, showSections, noSoundtrack, failed }

    static func musicPlan(soundtracks: MusicSectionPhase, songs: MusicSectionPhase, haveAlbums: Bool, haveSongs: Bool, enriching: Bool) -> MusicPlan {
        if haveAlbums || haveSongs { return .showSections }
        let settled: (MusicSectionPhase) -> Bool = { $0 == .loaded || $0 == .empty || $0 == .failed }
        // A section that failed is not the same as a film with no music: the page says so and offers a retry.
        if settled(soundtracks), settled(songs), soundtracks == .failed || songs == .failed { return .failed }
        if settled(soundtracks), settled(songs), !enriching { return .noSoundtrack }
        return .loading
    }
}

/// Which `soundtrackOf` claims the film page shows and how they are ordered and worded.
enum MusicFilmSoundtrackRules {
    /// Below this the link is a guess and the album stays out of the film page (it stays plain text on the album's own page).
    static let minimumConfidence: Float = 0.6

    static func accepts(_ e: MusicEdge) -> Bool {
        e.predicate == .soundtrackOf && !e.tombstone && e.status != .conflicted && e.confidence >= minimumConfidence
    }

    /// The signals of a matcher's claims, without the word "stated" (a stated link needs no explanation).
    static func evidence(from facts: [MusicProvenance]) -> [String] {
        var out: [String] = []
        for f in facts where f.stance == .asserts {
            for t in f.evidence where t != MusicProvenance.statedToken && !out.contains(t) { out.append(t) }
        }
        return Array(out.prefix(5))
    }

    /// Originals before dubbed editions; within each, stated before inferred, stronger before weaker, then older first.
    static func ordered(_ items: [MusicFilmAlbumItem]) -> [MusicFilmAlbumItem] {
        let rank: (EdgeStatus) -> Int = { $0 == .verified ? 0 : 1 }
        return items.sorted { a, b in
            if (a.dubLanguage == nil) != (b.dubLanguage == nil) { return a.dubLanguage == nil }
            if rank(a.status) != rank(b.status) { return rank(a.status) < rank(b.status) }
            if a.confidence != b.confidence { return a.confidence > b.confidence }
            if a.year != b.year { return (a.year ?? Int.max) < (b.year ?? Int.max) }
            return a.name < b.name
        }
    }
}

enum MusicFilmSongRules {
    /// A credit that counts as "sings" on a song row. A provider's flat artist list arrives as `performer`, so it counts.
    static func isSingerRole(_ role: MusicRole?) -> Bool {
        guard let role else { return true }
        return role == .singer || role == .performer || role == .featured
    }

    /// One credit per performer on a song: a person minted from provider text is dropped when the same name is also credited as an established person
    /// (the provider's flat artist list and the MusicBrainz credit are one performer), and a name repeated among provisional ones is kept once. Two
    /// established persons of one name stay two (never merged on a name).
    static func collapse(_ refs: [MusicFilmSingerRef]) -> [MusicFilmSingerRef] {
        let established = Set(refs.filter(\.established).map { MusicGraphText.latin($0.name) })
        var seenProvisional = Set<String>()
        return refs.filter { r in
            let k = MusicGraphText.latin(r.name)
            if r.established { return true }
            return !established.contains(k) && seenProvisional.insert(k).inserted
        }
    }

    /// "आवारा (1951 फ़िल्म)" and "Awaara (1951 film)" are article titles; the name is what stands before the bracket.
    static func withoutDisambiguator(_ title: String) -> String {
        guard let r = title.range(of: #"\s*[\(（][^\)）]*[\)）]\s*$"#, options: .regularExpression) else { return title }
        let t = String(title[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? title : t
    }

    /// One row per song of an album: the same song on two editions keeps the one with a playable copy, then the earlier position. Disc and track order.
    /// A title alone does not make two rows one song (a male and a female version, a reprise with the same name): they must also be about the same length, or one of them
    /// has no length on record.
    static func arranged(_ rows: [MusicFilmSongItem], limit: Int) -> [MusicFilmSongItem] {
        var best: [String: MusicFilmSongItem] = [:]
        var firstSeen: [String] = []
        for r in rows {
            let title = MusicGraphText.latin(r.title)
            // The key is the title plus a counter for each different-length song of that title.
            var n = 0
            var key = title
            while let cur = best[key] {
                if Self.sameLength(cur.durationMs, r.durationMs) { break }
                n += 1; key = title + "#\(n)"
            }
            if let cur = best[key] {
                let better = (r.playsDirectly && !cur.playsDirectly) || (r.playsDirectly == cur.playsDirectly && (r.position ?? Int.max) < (cur.position ?? Int.max))
                if better { best[key] = r }
            } else { best[key] = r; firstSeen.append(key) }
        }
        let list = firstSeen.compactMap { best[$0] }.enumerated().sorted { a, b in
            let x = (a.element.disc ?? 1, a.element.position ?? Int.max), y = (b.element.disc ?? 1, b.element.position ?? Int.max)
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
        return Array(list.prefix(limit))
    }

    /// Two lengths are the same song's when either is unknown or they are within three seconds.
    static func sameLength(_ a: Int?, _ b: Int?) -> Bool {
        guard let a, let b, a > 0, b > 0 else { return true }
        return abs(a - b) <= 3_000
    }

    /// The playable copy to use when a recording (or release) is known on more than one provider: the provider of its release first (so the album link stays valid), then
    /// the provider names in alphabetical order, so the same recording always plays from the same copy. A uid with no `provider:id` shape is never picked.
    static func pickProviderUID(_ ids: [ExternalID], preferring provider: String?) -> String? {
        let uids = ids.filter { $0.scheme == .provider }.map(\.value).filter { split(providerUID: $0) != nil }
        return uids.sorted { a, b in
            let pa = split(providerUID: a)?.provider == provider, pb = split(providerUID: b)?.provider == provider
            return pa != pb ? pa : a < b
        }.first
    }

    static func split(providerUID uid: String) -> (provider: String, id: String)? {
        guard let i = uid.firstIndex(of: ":"), i != uid.startIndex else { return nil }
        let id = String(uid[uid.index(after: i)...])
        return id.isEmpty ? nil : (String(uid[..<i]), id)
    }

    private static func artists(_ s: MusicFilmSongItem) -> [MusicArtistRef] { s.singers.map { MusicArtistRef(id: "", name: $0.name) } }
    private static func thumbs(_ s: MusicFilmSongItem) -> [MusicThumbnail] { s.imageRef.map { [MusicThumbnail(url: $0, width: 300, height: 300)] } ?? [] }

    /// The song as a track the player can start now: the playable copy's own provider and id, with the graph's title, singers and cover.
    static func playableTrack(for s: MusicFilmSongItem) -> MusicTrack? {
        guard let uid = s.providerUID, let p = split(providerUID: uid) else { return nil }
        var t = MusicTrack(id: p.id, providerID: p.provider, title: s.title, durationMs: Int64(s.durationMs ?? 0), trackNumber: s.position, discNumber: s.disc,
                           artists: artists(s), thumbnails: thumbs(s))
        if let ru = s.releaseProviderUID, let rp = split(providerUID: ru), rp.provider == p.provider {
            t.album = MusicAlbumRef(id: rp.id, title: s.albumName, thumbnails: thumbs(s))
        }
        return t
    }

    /// A catalogue row for a song with no playable copy in the graph: the matcher finds a playable twin by title, singers and length.
    static func catalogueRow(for s: MusicFilmSongItem) -> MusicTrack {
        MusicTrack(id: s.recording.token, providerID: "graph", title: s.title, durationMs: Int64(s.durationMs ?? 0), trackNumber: s.position, discNumber: s.disc,
                   artists: artists(s), album: MusicAlbumRef(id: "", title: s.albumName), thumbnails: thumbs(s))
    }

    /// The tracks to queue for a list of songs, in order: a direct copy, else the matched one, else nothing (an unplayable song is skipped, not faked).
    static func queue(songs: [MusicFilmSongItem], matched: [MusicEntityID: MusicTrack]) -> [MusicTrack] {
        var seen = Set<String>()
        let tracks = songs.compactMap { playableTrack(for: $0) ?? matched[$0.recording] }
        return tracks.filter { seen.insert($0.uid).inserted }
    }

    /// The songs with each recording once, first place kept (the same recording on two accepted albums is one song).
    static func uniqueRecordings(_ songs: [MusicFilmSongItem]) -> [MusicFilmSongItem] {
        var seen = Set<MusicEntityID>()
        return songs.filter { seen.insert($0.recording).inserted }
    }
}
