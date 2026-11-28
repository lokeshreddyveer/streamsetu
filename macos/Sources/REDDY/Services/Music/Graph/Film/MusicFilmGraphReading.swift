import Foundation

// Bounded reads of the graph for the film page. Everything here takes a `MusicGraphStoring` and nothing else: no player, no network, no app type.
// Each function checks cancellation between reads, so leaving the page stops the walk.

/// Entity snapshots read once per walk.
struct MusicFilmSnapshots {
    let store: any MusicGraphStoring
    private var found: [MusicEntityID: MusicEntitySnapshot] = [:]
    private var absent: Set<MusicEntityID> = []
    init(store: any MusicGraphStoring) { self.store = store }

    mutating func get(_ id: MusicEntityID) async -> MusicEntitySnapshot? {
        if let s = found[id] { return s }
        if absent.contains(id) { return nil }
        if let s = try? await store.entity(id), s.state == .live { found[id] = s; return s }
        absent.insert(id)
        return nil
    }
}

/// A language code in a person's words ("hi" and "hin" are Hindi).
enum MusicFilmLanguageNames {
    private static let three: [String: String] = ["hin": "hi", "tel": "te", "tam": "ta", "mal": "ml", "kan": "kn", "kor": "ko", "eng": "en", "ben": "bn",
                                                  "mar": "mr", "pan": "pa", "guj": "gu", "urd": "ur", "jpn": "ja", "zho": "zh", "fra": "fr", "spa": "es"]
    /// In the app's own language (not the Mac's): a Telugu page on an English Mac names languages in Telugu.
    static func name(for code: String, locale: Locale = Locale(identifier: Localized.activeCode)) -> String {
        let c = code.lowercased()
        if c == "xx" || c == "zxx" || c == "und" { return "" }   // the source's "no language" code: nothing to name
        let two = three[c] ?? c
        return locale.localizedString(forLanguageCode: two)?.capitalized(with: locale) ?? code.uppercased()
    }
}

enum MusicFilmGraphReading {
    /// How many of a film's own edges are read at once. Cast, crew, language and the people's filmography edges share them, so the window is wide: a film with more than a few hundred
    /// would otherwise lose its director or music director from the header.
    static let edgeWindow = 2000

    static let castCap = 80
    static let crewPerRole = 12
    static let albumsWithSongs = 6
    static let songsPerAlbum = 60
    static let songsTotal = 200

    // MARK: people

    static func person(_ s: MusicEntitySnapshot, edge: MusicEdge, role: MusicRole) -> MusicFilmPersonItem {
        MusicFilmPersonItem(person: s.id, name: s.name, imageRef: s.imageRef, role: role, character: edge.attributes.characterName,
                            order: edge.order ?? edge.attributes.creditOrder, status: edge.status, creditLevel: edge.creditLevel,
                            nameOnly: s.attrs["nameOnly"] == "1", attribution: edge.attributes["attribution"], birthYear: s.kind == .person ? s.year : nil)
    }

    /// The cast in billing order. A name-only entry that repeats the name of a person with an id is dropped (one person, once).
    static func cast(film: MusicEntityID, store: any MusicGraphStoring, report: ((MusicSectionResult) async -> Void)? = nil) async throws -> [MusicFilmPersonItem] {
        let raw = try await store.edges(of: film, predicate: .hasCast, direction: .outgoing, limit: 500)
        // The cap below must cut the tail of the billing, not whichever edges the store listed last: order first.
        let edges = raw.enumerated().sorted { a, b in
            let x = a.element.order ?? a.element.attributes.creditOrder ?? Int.max, y = b.element.order ?? b.element.attributes.creditOrder ?? Int.max
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
        var snaps = MusicFilmSnapshots(store: store)
        var out: [MusicFilmPersonItem] = []
        for e in edges {
            try Task.checkCancellation()
            guard let s = await snaps.get(e.object) else { continue }
            out.append(person(s, edge: e, role: .actor))
            if out.count % 12 == 0, let report { await report(MusicSectionResult(items: MusicFilmPageBuilders.cast(out).map { $0 as AnyHashable })) }
            if out.count >= castCap { break }
        }
        return MusicFilmPageBuilders.cast(out)
    }

    /// The crew by role, from every credit edge of the film that is not cast.
    static func crew(film: MusicEntityID, store: any MusicGraphStoring) async throws -> [MusicFilmCrewItem] {
        let edges = try await store.edges(of: film, predicate: nil, direction: .outgoing, limit: MusicFilmGraphReading.edgeWindow)
        var snaps = MusicFilmSnapshots(store: store)
        var people: [MusicFilmPersonItem] = []
        for e in edges {
            guard let role = MusicFilmPageBuilders.crewRole(of: e) else { continue }
            try Task.checkCancellation()
            guard let s = await snaps.get(e.object) else { continue }
            people.append(person(s, edge: e, role: role))
        }
        let groups = MusicFilmPageBuilders.crew(people)
        let extra = try await extraCrew(film: film, store: store, snaps: &snaps, graphPeople: people)
        return groups + extra
    }

    /// Roles that name one job: a writing credit may be stored as `writer` or `screenwriter`.
    static func sameCreditRole(_ a: MusicRole?, _ b: MusicRole?) -> Bool {
        let writing: Set<MusicRole?> = [.writer, .screenwriter]
        return a == b || (writing.contains(a) && writing.contains(b))
    }

    /// The crew departments TMDB listed for the film (camera, editing, writing, art, sound, costume, effects, choreography), each person found by their TMDB id.
    /// A person the graph already credits under the matching role is not listed twice.
    static func extraCrew(film: MusicEntityID, store: any MusicGraphStoring, snaps: inout MusicFilmSnapshots, graphPeople: [MusicFilmPersonItem]) async throws -> [MusicFilmCrewItem] {
        guard let s = await snaps.get(film) else { return [] }
        let credits = MusicFilmExtraCrew.decode(s.attrs["crewExtra"])
        guard !credits.isEmpty else { return [] }
        var byDepartment: [MusicFilmDepartment: [MusicFilmPersonItem]] = [:]
        for (i, c) in credits.enumerated() {
            try Task.checkCancellation()
            guard let id = try? await store.resolveAlias(for: ExternalID(.tmdbPerson, String(c.tmdb)), kind: .person), let p = await snaps.get(id) else { continue }
            // A person the graph already credits under the same role is not listed twice; writing is one role under two names (`writer` and `screenwriter`).
            if graphPeople.contains(where: { $0.person == p.id && Self.sameCreditRole($0.role, c.department.placeholderRole) && c.department.placeholderRole != .producer }) { continue }
            if byDepartment[c.department, default: []].contains(where: { $0.person == p.id }) { continue }
            byDepartment[c.department, default: []].append(MusicFilmPersonItem(person: p.id, name: p.name, imageRef: p.imageRef, role: c.department.placeholderRole, character: nil, order: i,
                                                                               status: .verified, creditLevel: .film, nameOnly: false, attribution: nil,
                                                                               birthYear: p.kind == .person ? p.year : nil, job: c.job))
        }
        return MusicFilmDepartment.allCases.compactMap { d in
            guard let people = byDepartment[d], !people.isEmpty else { return nil }
            return MusicFilmCrewItem(role: d.placeholderRole, people: people, department: d)
        }
    }

    // MARK: header facts

    static func overview(film: MusicEntityID, store: any MusicGraphStoring) async throws -> MusicFilmOverview? {
        var snaps = MusicFilmSnapshots(store: store)
        guard let s = await snaps.get(film) else { return nil }
        let outgoing = try await store.edges(of: film, predicate: nil, direction: .outgoing, limit: MusicFilmGraphReading.edgeWindow)
        var languages: [String] = []
        if let l = s.lang, !l.isEmpty { let n = MusicFilmLanguageNames.name(for: l); if !n.isEmpty { languages.append(n) } }
        for e in outgoing where e.predicate == .inLanguage {
            try Task.checkCancellation()
            if let l = await snaps.get(e.object) {
                let n = (l.attrs["iso639"] ?? l.lang).map { MusicFilmLanguageNames.name(for: $0) } ?? l.name
                if !n.isEmpty, !languages.contains(n) { languages.append(n) }
            }
        }
        var attributions = Set(outgoing.compactMap { $0.attributes["attribution"] })
        if let src = s.attrs["synopsisSource"], s.attrs["synopsis"] != nil { attributions.insert(src) }
        var o = MusicFilmOverview(title: s.name, year: s.year, languages: languages, description: s.attrs["description"], synopsis: s.attrs["synopsis"],
                                  synopsisSource: s.attrs["synopsis"] == nil ? nil : s.attrs["synopsisSource"], seasons: s.attrs["seasons"].flatMap(Int.init),
                                  imageRef: s.imageRef, isSeries: film.kind == .series, attributions: attributions.sorted())
        o.originalTitle = s.attrs["originalTitle"].flatMap { $0 == s.name ? nil : $0 }
        o.releaseDate = s.attrs["releaseDate"]
        o.runtimeMinutes = s.attrs["runtimeMinutes"].flatMap(Int.init)
        o.tagline = s.attrs["tagline"]
        o.genres = (s.attrs["genres"] ?? "").split(separator: "|").map(String.init)
        o.rating = s.attrs["rating"]; o.ratingVotes = s.attrs["ratingVotes"].flatMap(Int.init)
        o.certification = s.attrs["certification"]; o.certificationRegion = s.attrs["certificationRegion"]
        o.trailerKey = s.attrs["trailerKey"]
        o.backdropURL = s.attrs["backdropURL"]
        o.gallery = MusicFilmGallery.decode(s.attrs["gallery"])
        o.companies = MusicFilmAboutFacts.list(s.attrs["companies"])
        o.productionCountries = MusicFilmAboutFacts.list(s.attrs["countryNames"])
        o.spokenLanguages = MusicFilmAboutFacts.list(s.attrs["spokenLanguages"])
        o.status = s.attrs["status"]
        o.budget = MusicFilmAboutFacts.money(s.attrs["budget"]); o.revenue = MusicFilmAboutFacts.money(s.attrs["revenue"])
        o.videos = MusicFilmVideos.decode(s.attrs["videos"])
        return o
    }

    // MARK: soundtracks

    /// The film's soundtrack albums: matched ones only (see `MusicFilmSoundtrackRules`), originals first, dubbed editions after.
    static func soundtrackAlbums(film: MusicEntityID, store: any MusicGraphStoring) async throws -> [MusicFilmAlbumItem] {
        let incoming = try await store.edges(of: film, predicate: .soundtrackOf, direction: .incoming, limit: 100)
        let accepted = incoming.filter(MusicFilmSoundtrackRules.accepts)
        var snaps = MusicFilmSnapshots(store: store)
        var items: [MusicFilmAlbumItem] = []
        let subjects = Set(accepted.map(\.subject))
        for e in accepted {
            try Task.checkCancellation()
            guard let s = await snaps.get(e.subject) else { continue }
            if e.subject.kind == .release,
               let group = try? await store.edges(of: e.subject, predicate: .editionOf, direction: .outgoing, limit: 4).first?.object, subjects.contains(group) { continue }
            var evidence: [String] = []
            if e.status != .verified, let facts = try? await store.facts(for: e.key) {
                evidence = MusicFilmSoundtrackRules.evidence(from: facts)
            }
            items.append(MusicFilmAlbumItem(album: s.id, name: s.name, year: s.year, imageRef: s.imageRef, lang: s.lang, dubLanguage: e.attributes.dubLanguage,
                                            status: e.status, confidence: e.confidence, matchEvidence: evidence, via: nil, film: nil, filmName: nil))
        }
        return MusicFilmSoundtrackRules.ordered(items)
    }

    // MARK: songs

    /// The albums whose songs are read: the first few (originals come first), plus one album for every dub language the first few missed, so a language chip never opens an empty list.
    static func walked(_ albums: [MusicFilmAlbumItem]) -> [MusicFilmAlbumItem] {
        let head = Array(albums.prefix(albumsWithSongs))
        var langs = Set(head.compactMap(\.dubLanguage))
        var extra: [MusicFilmAlbumItem] = []
        for a in albums.dropFirst(albumsWithSongs) {
            if let l = a.dubLanguage, langs.insert(l).inserted { extra.append(a) }
        }
        return head + extra
    }

    /// Whether `album` is still read once `n` songs are held: the cap stops the original albums, but a dubbed edition (kept by `walked` so a language chip is never empty) is always read.
    static func reads(_ album: MusicFilmAlbumItem, haveSongs n: Int) -> Bool { n < songsTotal || album.dubLanguage != nil }

    /// Every recording on the soundtrack albums (and their editions), in album then track order, with singers and the playable copy's uid.
    static func songs(albums: [MusicFilmAlbumItem], store: any MusicGraphStoring, report: ((MusicSectionResult) async -> Void)? = nil) async throws -> [MusicFilmSongItem] {
        var snaps = MusicFilmSnapshots(store: store)
        var releaseUIDs: [MusicEntityID: String?] = [:]
        var all: [MusicFilmSongItem] = []
        for album in walked(albums) {
            try Task.checkCancellation()
            guard reads(album, haveSongs: all.count) else { continue }
            var targets: [MusicEntityID] = [album.album]
            let editions = (try? await store.edges(of: album.album, predicate: .editionOf, direction: .incoming, limit: 12)) ?? []
            targets += editions.map(\.subject).filter { $0 != album.album }
            var seen = Set<MusicEntityID>()
            var rows: [MusicFilmSongItem] = []
            for target in targets.prefix(9) {
                try Task.checkCancellation()
                if releaseUIDs[target] == nil {
                    let ids = (try? await store.externalIDs(of: target)) ?? []
                    releaseUIDs[target] = .some(MusicFilmSongRules.pickProviderUID(ids, preferring: nil))
                }
                let tracks = (try? await store.edges(of: target, predicate: .trackOn, direction: .incoming, limit: 200)) ?? []
                for t in tracks where rows.count < songsPerAlbum * 2 {
                    try Task.checkCancellation()
                    guard seen.insert(t.subject).inserted, let rec = await snaps.get(t.subject) else { continue }
                    let ids = (try? await store.externalIDs(of: rec.id)) ?? []
                    let releaseUID = releaseUIDs[target] ?? nil
                    let performers = (try? await store.edges(of: rec.id, predicate: .performedBy, direction: .outgoing, limit: 24)) ?? []
                    var singers: [MusicFilmSingerRef] = []
                    for p in performers where MusicFilmSongRules.isSingerRole(p.role) {
                        if let ps = await snaps.get(p.object), !singers.contains(where: { $0.person == ps.id }) { singers.append(MusicFilmSingerRef(person: ps.id, name: ps.name, imageRef: ps.imageRef, established: !ps.provisional)) }
                    }
                    rows.append(MusicFilmSongItem(recording: rec.id, title: rec.name, durationMs: rec.durationMs, imageRef: rec.imageRef ?? album.imageRef, album: album.album,
                                                  albumName: album.name, dubLanguage: album.dubLanguage, disc: t.attributes.disc, position: t.attributes.position ?? t.order,
                                                  singers: MusicFilmSongRules.collapse(singers), providerUID: MusicFilmSongRules.pickProviderUID(ids, preferring: releaseUID.flatMap { MusicFilmSongRules.split(providerUID: $0)?.provider }),
                                                  releaseProviderUID: releaseUID, status: t.status))
                }
            }
            all += MusicFilmSongRules.arranged(rows, limit: songsPerAlbum)
            if let report { await report(MusicSectionResult(items: all.map { $0 as AnyHashable })) }
        }
        return all
    }

    // MARK: versions

    /// Other forms of the film that the graph states: dubbed soundtrack editions and the film's other names. Two films are never merged here.
    static func versions(film: MusicEntityID, albums: [MusicFilmAlbumItem], store: any MusicGraphStoring) async throws -> [MusicFilmVersionItem] {
        var snaps = MusicFilmSnapshots(store: store)
        var out: [MusicFilmVersionItem] = []
        for a in albums.filter({ $0.dubLanguage != nil }).prefix(12) {
            out.append(MusicFilmVersionItem(kind: .dubbedAlbum, text: a.name, language: a.dubLanguage.map { MusicFilmLanguageNames.name(for: $0) }.flatMap { $0.isEmpty ? nil : $0 }, album: a.album))
        }
        guard let s = await snaps.get(film) else { return out }
        let aliases = (try? await store.aliases(of: film)) ?? []
        var seen: Set<String> = [MusicGraphText.latin(s.name)]
        for a in aliases {
            let text = MusicFilmSongRules.withoutDisambiguator(a.text)
            let k = MusicGraphText.latin(text)
            guard !k.isEmpty, seen.insert(k).inserted else { continue }
            out.append(MusicFilmVersionItem(kind: .alias, text: text, language: a.lang.map { MusicFilmLanguageNames.name(for: $0) }.flatMap { $0.isEmpty ? nil : $0 }, album: nil))
            if out.count >= 12 { break }
        }
        return out
    }
}
