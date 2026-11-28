import Foundation

// The builders of sections A (header), C (credits) and D (cast), and the shared reads the shelves use. Each builder is an async function over the
// reader that returns plain values; none of them touches the player, a view or the network (the `hooks` are how a page lets a builder ask for
// enrichment or a provider search, and a build without hooks simply works from what the graph holds).

/// What a page lets the builders ask for. The defaults do nothing, so a test or a build without the metadata layer works from the graph alone.
struct MusicSoundtrackHooks: Sendable {
    /// Asks the entity layer to enrich an entity (a film's cast, an actor's filmography). Single-flight and bounded on the other side; returns when done.
    var enrich: @Sendable (MusicEntityID) async -> Void
    /// Searches the active provider for albums that might be a film's soundtrack. Nil when providers may not be asked (no consent, Kids, offline).
    var providerAlbums: (@Sendable (MusicSoundtrackFilm) async -> [MusicSoundtrackProviderAlbum])?
    /// Writes an accepted match into the graph as an INFERRED `soundtrackOf` claim and returns the album's id.
    var persistInferred: @Sendable (MusicSoundtrackProviderAlbum, MusicSoundtrackFilm) async -> MusicEntityID?

    init(enrich: @escaping @Sendable (MusicEntityID) async -> Void = { _ in },
         providerAlbums: (@Sendable (MusicSoundtrackFilm) async -> [MusicSoundtrackProviderAlbum])? = nil,
         persistInferred: @escaping @Sendable (MusicSoundtrackProviderAlbum, MusicSoundtrackFilm) async -> MusicEntityID? = { _, _ in nil }) {
        self.enrich = enrich; self.providerAlbums = providerAlbums; self.persistInferred = persistInferred
    }

    static let none = MusicSoundtrackHooks()
}

struct MusicSoundtrackCredits: Hashable, Sendable {
    var groups: [MusicSoundtrackCreditGroup]
    var film: MusicSoundtrackFilm?
    var sources: [MusicSourceID]
    /// Every (person, role) credit as the graph holds it, before the overview's one-chip-per-person merge. The album's Credits pill reads this list, so a
    /// person who is both music director and singer appears under both.
    var raw: [MusicSoundtrackCredit] = []
    var isEmpty: Bool { groups.isEmpty }
    func group(_ kind: MusicSoundtrackCreditKind) -> MusicSoundtrackCreditGroup? { groups.first { $0.kind == kind } }
    /// The people of one kind, best first.
    func people(_ kind: MusicSoundtrackCreditKind) -> [MusicSoundtrackCredit] { group(kind)?.credits ?? [] }
}

struct MusicSoundtrackCastResult: Hashable, Sendable {
    var film: MusicSoundtrackFilm?
    var cast: [MusicSoundtrackCast]
    var sources: [MusicSourceID]
}

enum MusicSoundtrackBuild {
    // MARK: roles

    static let creditPredicates: [MusicPredicate] = [.performedBy, .composedBy, .musicDirectedBy, .writtenBy, .producedBy]

    static func defaultRole(_ p: MusicPredicate) -> MusicRole {
        switch p {
        case .composedBy: .composer
        case .musicDirectedBy: .musicDirector
        case .writtenBy: .lyricist
        case .producedBy: .producer
        case .directedBy: .director
        default: .performer
        }
    }

    static func kind(for role: MusicRole) -> MusicSoundtrackCreditKind {
        switch role {
        case .musicDirector: .musicDirector
        case .composer: .composer
        case .lyricist, .writer: .lyricist
        case .singer: .singer
        case .performer, .featured: .artist
        default: .other
        }
    }

    /// A credit's level as a specificity (song first), unknown counting as album.
    static func specificity(_ l: CreditLevel) -> Int { switch l { case .song: 0; case .album, .unknown: 1; case .film: 2 } }

    static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    // MARK: header (A)

    /// Music directors and composers of the album or its film, album-level first: the names under the title. Cheap (no per-song reads).
    static func makers(_ r: MusicSoundtrackReader, family: MusicSoundtrackFamily, film: MusicSoundtrackFilm?) async -> [MusicSoundtrackCredit] {
        var found: [MusicEntityID: MusicSoundtrackCredit] = [:]
        func take(_ edges: [MusicEdge], level: CreditLevel) async {
            for e in edges where e.status != .conflicted && (e.predicate == .musicDirectedBy || e.predicate == .composedBy) {
                let role = e.role ?? defaultRole(e.predicate)
                guard role == .musicDirector || role == .composer, let p = await r.person(e.object) else { continue }
                let effective: CreditLevel = e.creditLevel == .unknown ? level : e.creditLevel
                let credit = MusicSoundtrackCredit(person: p, role: role, songCount: 0, level: effective, status: e.status, order: e.order ?? Int.max)
                if let have = found[p.id] {
                    if (have.role == .composer && role == .musicDirector) || specificity(effective) < specificity(have.level) { found[p.id] = credit }
                } else { found[p.id] = credit }
            }
        }
        for m in family.members { await take(await r.edges(m, nil, .outgoing, limit: 60), level: .album) }
        if let film { await take(await r.edges(film.id, nil, .outgoing, limit: 60), level: .film) }
        let sorted = found.values.sorted {
            if ($0.role == .musicDirector) != ($1.role == .musicDirector) { return $0.role == .musicDirector }
            return $0.order != $1.order ? $0.order < $1.order : $0.person.name < $1.person.name
        }
        // One name, one chip: the same composer filed under several graph entities (or a wiki template word taken for a name) is listed once, so the line carries
        // no "#1Z4X" codes. The Credits section below lists every entity with its role.
        let unique = MusicSoundtrackNameGuard.listable(sorted)
        let details = MusicSoundtrackDisambiguator.details(for: unique.map(\.person))
        return unique.prefix(MusicSoundtrackLimits.composersUsed).map { var c = $0; c.person = MusicSoundtrackDisambiguator.apply(c.person, details); return c }
    }

    static func header(_ r: MusicSoundtrackReader, id: MusicEntityID) async -> MusicSoundtrackHeaderFacts? {
        guard let snap = await r.entity(id), snap.kind == .album || snap.kind == .release else { return nil }
        let family = await r.family(of: snap.id)
        let film = await r.filmLink(family)
        async let language = r.facet(of: family.members, .inLanguage)
        async let era = r.facet(of: family.members, .ofEra)
        let makers = await makers(r, family: family, film: film)
        var imageRef = snap.imageRef
        if imageRef == nil { for m in family.members.dropFirst() { if let i = await r.entity(m)?.imageRef { imageRef = i; break } } }
        let lang = await language, eraFacet = await era
        let hint = film == nil ? (snap.attrs["filmHint"] ?? "").trimmingCharacters(in: .whitespaces) : ""
        var facts = MusicSoundtrackHeaderFacts(title: snap.name, year: snap.year ?? film?.year, languageName: lang?.name ?? languageName(snap.lang ?? film?.language),
                                               subkind: snap.subkind, imageRef: imageRef ?? film?.imageRef, film: film, filmHint: hint.isEmpty ? nil : hint, makers: makers)
        facts.languageID = lang?.id; facts.eraID = eraFacet?.id; facts.eraName = eraFacet?.name
        return facts
    }

    // MARK: credits (C)

    private struct Acc { var songs = Set<MusicEntityID>(); var level = CreditLevel.unknown; var status = EdgeStatus.inferred; var order = Int.max; var seen = false }
    private struct Key: Hashable { var person: MusicEntityID; var role: MusicRole }

    static func credits(_ r: MusicSoundtrackReader, id: MusicEntityID, recordings given: [MusicSoundtrackRecording]? = nil) async -> MusicSoundtrackCredits {
        let family = await r.family(of: id)
        let film = await r.filmLink(family)
        var acc: [Key: Acc] = [:]

        func add(_ e: MusicEdge, level: CreditLevel, song: MusicEntityID?) {
            guard e.status != .conflicted, e.object.kind.isAgent else { return }
            let role = e.role ?? defaultRole(e.predicate)
            var a = acc[Key(person: e.object, role: role)] ?? Acc()
            let effective: CreditLevel = song != nil ? .song : (e.creditLevel == .unknown ? level : e.creditLevel)
            if !a.seen || specificity(effective) < specificity(a.level) { a.level = effective }
            a.seen = true
            if e.status == .verified { a.status = .verified }
            a.order = min(a.order, e.order ?? Int.max)
            if let song { a.songs.insert(song) }
            acc[Key(person: e.object, role: role)] = a
        }

        for m in family.members {
            for e in await r.edges(m, nil, .outgoing, limit: 100) where creditPredicates.contains(e.predicate) { add(e, level: .album, song: nil) }
        }
        let recordings: [MusicSoundtrackRecording]
        if let given { recordings = given } else { recordings = await r.recordings(family) }
        let perSong: [[MusicEdge]] = await r.boundedMap(Array(recordings.prefix(MusicSoundtrackLimits.tracksForCredits))) { rec in
            await r.edges(rec.id, nil, .outgoing, limit: 40).filter { creditPredicates.contains($0.predicate) }
        }
        for (i, edges) in perSong.enumerated() { for e in edges { add(e, level: .song, song: recordings[i].id) } }
        var filmEdges: [MusicEdge] = []
        if let film {
            filmEdges = await r.edges(film.id, nil, .outgoing, limit: 80).filter { [.composedBy, .musicDirectedBy, .directedBy, .producedBy].contains($0.predicate) }
            for e in filmEdges { add(e, level: .film, song: nil) }
        }

        // People behind the credits (a credit whose person is not in the graph cannot be opened, so it is not shown).
        let ids = Array(Set(acc.keys.map(\.person)))
        let people: [MusicSoundtrackPerson?] = await r.boundedMap(ids) { await r.person($0) }
        var byID: [MusicEntityID: MusicSoundtrackPerson] = [:]
        for p in people.compactMap({ $0 }) { byID[p.id] = p }

        var credits: [MusicSoundtrackCredit] = []
        for (k, a) in acc {
            guard let p = byID[k.person] else { continue }
            credits.append(MusicSoundtrackCredit(person: p, role: k.role, songCount: a.songs.count, level: a.level, status: a.status, order: a.order))
        }
        // A film-level composer credit of someone already shown as the music director adds nothing.
        let directors = Set(credits.filter { $0.role == .musicDirector }.map(\.person.id))
        credits.removeAll { $0.role == .composer && $0.isFilmCredit && directors.contains($0.person.id) }
        let rawCredits = credits.sorted {
            if $0.songCount != $1.songCount { return $0.songCount > $1.songCount }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.person.name < $1.person.name
        }
        // A performer who is also credited in another role (the music directors are often the credited "artist") is shown there, not twice.
        let otherThanArtist = Set(credits.filter { kind(for: $0.role) != .artist }.map(\.person.id))
        credits.removeAll { kind(for: $0.role) == .artist && otherThanArtist.contains($0.person.id) }
        let hasSingers = credits.contains { kind(for: $0.role) == .singer }
        if hasSingers { credits.removeAll { kind(for: $0.role) == .artist } }

        // One person, one chip: the same name under another role or entity is merged when nothing says they are two people (their descriptions are both empty or
        // equal). The other roles become the chip's second line. People who really share a name keep their labels (a year, a description, or a short code only
        // when those are the same too), and everyone else has no second line.
        let merged = MusicSoundtrackDisambiguator.mergedByName(credits, kind: { kind(for: $0) }, roleName: { MusicSoundtrackText.roleName($0) { Localized.string($0) } },
                                                               also: { Localized.string("also %@", $0.joined(separator: ", ")) })
        let homonyms = MusicSoundtrackDisambiguator.details(for: merged.credits.map(\.person))
        credits = merged.credits.map { var c = $0; c.person.detail = merged.also[$0.person.id] ?? homonyms[$0.person.id]; return c }
        var grouped: [MusicSoundtrackCreditKind: [MusicSoundtrackCredit]] = [:]
        for c in credits { grouped[kind(for: c.role), default: []].append(c) }
        let groups = MusicSoundtrackCreditKind.allCases.compactMap { k -> MusicSoundtrackCreditGroup? in
            guard let list = grouped[k], !list.isEmpty else { return nil }
            let sorted = list.sorted {
                if $0.songCount != $1.songCount { return $0.songCount > $1.songCount }
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.person.name < $1.person.name
            }
            return MusicSoundtrackCreditGroup(kind: k, credits: Array(sorted.prefix(12)))
        }
        let sources = await sourcesOf(r, filmEdges.isEmpty ? [] : Array(filmEdges.prefix(2)))
        return MusicSoundtrackCredits(groups: groups, film: film, sources: sources, raw: rawCredits)
    }

    /// The sources behind a few edges, for attribution lines.
    static func sourcesOf(_ r: MusicSoundtrackReader, _ edges: [MusicEdge]) async -> [MusicSourceID] {
        var out: [MusicSourceID] = []
        for e in edges.prefix(3) {
            for f in (try? await r.store.facts(for: e.key)) ?? [] where !out.contains(f.source) { out.append(f.source) }
        }
        return out
    }

    // MARK: cast (D)

    /// The cast edges of a film that count as verified, in billing order.
    static func castEdges(_ r: MusicSoundtrackReader, film: MusicEntityID) async -> [MusicEdge] {
        await r.edges(film, .hasCast, .outgoing, limit: 80).filter { $0.status == .verified }.sorted {
            let a = $0.order ?? $0.attributes.creditOrder ?? Int.max, b = $1.order ?? $1.attributes.creditOrder ?? Int.max
            return a != b ? a < b : $0.object < $1.object
        }
    }

    static func cast(_ r: MusicSoundtrackReader, id: MusicEntityID, hooks: MusicSoundtrackHooks = .none) async -> MusicSoundtrackCastResult {
        let family = await r.family(of: id)
        guard let film = await r.filmLink(family) else { return MusicSoundtrackCastResult(film: nil, cast: [], sources: []) }
        var edges = await castEdges(r, film: film.id)
        if edges.isEmpty {
            await hooks.enrich(film.id)
            edges = await castEdges(r, film: film.id)
        }
        let top = Array(edges.prefix(MusicSoundtrackLimits.castShown))
        let people: [MusicSoundtrackPerson?] = await r.boundedMap(top) { await r.person($0.object) }
        var rows: [(MusicSoundtrackPerson, MusicEdge)] = []
        for (i, p) in people.enumerated() { if let p { rows.append((p, top[i])) } }
        let details = MusicSoundtrackDisambiguator.details(for: rows.map(\.0))
        let cast = rows.enumerated().map { i, row in
            MusicSoundtrackCast(person: MusicSoundtrackDisambiguator.apply(row.0, details), character: row.1.attributes.characterName, billing: i, status: row.1.status)
        }
        return MusicSoundtrackCastResult(film: film, cast: cast, sources: await sourcesOf(r, Array(top.prefix(2))))
    }

    // MARK: facts about an album (ranking input)

    /// What the ranking needs about one album: creators, singers, the film and its cast, language, genres. Local reads only, about six per album.
    static func albumFacts(_ r: MusicSoundtrackReader, id: MusicEntityID, withCast: Bool = true, knownFilm: MusicSoundtrackFilm? = nil) async -> MusicSoundtrackAlbumFacts? {
        guard let snap = await r.entity(id), snap.kind == .album || snap.kind == .release else { return nil }
        let family = await r.family(of: snap.id)
        let film: MusicSoundtrackFilm? = knownFilm != nil ? knownFilm : await r.filmLink(family)
        var f = MusicSoundtrackAlbumFacts(id: snap.id, title: snap.name, year: snap.year, imageRef: snap.imageRef, subkind: snap.subkind, film: film)
        for m in family.members {
            for e in await r.edges(m, nil, .outgoing, limit: 100) where e.status != .conflicted {
                switch e.predicate {
                case .musicDirectedBy: if let n = await r.name(e.object) { f.musicDirectors[e.object] = n }
                case .composedBy: if let n = await r.name(e.object) { f.composers[e.object] = n }
                case .performedBy:
                    let role = e.role ?? .performer
                    if role == .singer || role == .performer || role == .featured, let n = await r.name(e.object) { f.singers[e.object] = n }
                case .hasGenre: if let n = await r.name(e.object), !f.genres.contains(n) { f.genres.append(n) }
                default: break
                }
            }
        }
        if f.singers.isEmpty {
            // no album-level singer claim: the singers of its first songs stand in (bounded to ten songs)
            for t in await r.edges(family.trackOwners.first ?? snap.id, .trackOn, .incoming, limit: 10) {
                for e in await r.edges(t.subject, .performedBy, .outgoing, limit: 6) where e.status != .conflicted && MusicSoundtrackSinging.isSinger(e) {
                    if let n = await r.name(e.object) { f.singers[e.object] = n }
                }
            }
        }
        if let film {
            f.evidenceStatus = film.linkStatus; f.evidenceConfidence = film.linkConfidence
            for e in await r.edges(film.id, nil, .outgoing, limit: 80) where e.status != .conflicted {
                if e.predicate == .musicDirectedBy, let n = await r.name(e.object) { f.musicDirectors[e.object] = n }
                if e.predicate == .composedBy, let n = await r.name(e.object) { f.composers[e.object] = n }
            }
            if withCast { for e in await castEdges(r, film: film.id).prefix(12) { if let n = await r.name(e.object) { f.cast[e.object] = n } } }
        }
        if let lang = await r.facet(of: family.members, .inLanguage) { f.languageName = lang.name }
        else if let film, let lang = (await r.entity(film.id))?.lang ?? film.language { f.languageName = languageName(lang) }
        else { f.languageName = languageName(snap.lang) }
        return f
    }
}
