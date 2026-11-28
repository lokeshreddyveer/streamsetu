import Foundation

/// Pure mappings from the app's existing saved and provider types into graph drafts and mint plans (section 1.7). No page calls these yet; no existing
/// type changes. A provider id becomes a `provider` external id (`providerID:id`), so the same saved item always gets the same stable id.
enum MusicGraphAdapters {
    // MARK: tracks, albums, artists, playlists

    static func plan(for t: MusicTrack) -> MusicMintPlan {
        var primary = MusicEntityDraft(kind: .recording, name: t.title, durationMs: t.durationMs > 0 ? Int(t.durationMs) : nil,
                                       imageRef: t.thumbnails.best(minSide: 300), externalIDs: [ExternalID(.provider, t.uid)], provisional: true)
        if let isrc = t.isrc, !isrc.isEmpty { primary.externalIDs.append(ExternalID(.isrc, isrc.uppercased())) }
        if t.explicit { primary.attrs["explicit"] = "1" }
        if let film = filmHint(inTitle: t.title) { primary.attrs["filmHint"] = film }
        var plan = MusicMintPlan(primary: primary, source: MusicSourceID(t.providerID))
        for (i, a) in t.artists.enumerated() where !MusicCompilationArtist.isCompilation(a.name) {
            plan.links.append(.init(draft: artistDraft(a, providerID: t.providerID), predicate: .performedBy, role: .performer, order: i, creditLevel: .song))
        }
        // An album with no provider id has no identity of its own: "provider:" would be one entity shared by every such album (their tracks, cover and title
        // would merge), so the song is minted without the album link.
        if let al = t.album, !al.id.isEmpty {
            var attrs = EdgeAttributes()
            attrs.disc = t.discNumber; attrs.position = t.trackNumber
            plan.links.append(.init(draft: albumDraft(al, providerID: t.providerID), predicate: .trackOn, attributes: attrs, order: t.trackNumber, creditLevel: .album, score: 0.9))
        }
        return plan
    }

    static func plan(for a: MusicAlbum) -> MusicMintPlan {
        var plan = MusicMintPlan(primary: albumDraft(a), source: MusicSourceID(a.providerID))
        for (i, r) in a.artists.enumerated() where !MusicCompilationArtist.isCompilation(r.name) {
            plan.links.append(.init(draft: artistDraft(r, providerID: a.providerID), predicate: .performedBy, role: .performer, order: i, creditLevel: .album))
        }
        return plan
    }

    static func albumDraft(_ a: MusicAlbum) -> MusicEntityDraft {
        var d = MusicEntityDraft(kind: .release, name: a.title, subkind: albumSubkind(type: a.albumType, title: a.title), year: year(a.releaseDate),
                                 imageRef: a.thumbnails.best(minSide: 300), externalIDs: a.id.isEmpty ? [] : [ExternalID(.provider, a.uid)], provisional: true)
        if let film = filmHint(inTitle: a.title) { d.attrs["filmHint"] = film }
        if let l = a.label { d.attrs["label"] = l }
        return d
    }

    static func albumDraft(_ a: MusicAlbumRef, providerID: String) -> MusicEntityDraft {
        var d = MusicEntityDraft(kind: .release, name: a.title, subkind: albumSubkind(type: a.albumType, title: a.title), year: year(a.releaseDate),
                                 imageRef: a.thumbnails.best(minSide: 300), externalIDs: a.id.isEmpty ? [] : [ExternalID(.provider, providerID + ":" + a.id)], provisional: true)
        if let film = filmHint(inTitle: a.title) { d.attrs["filmHint"] = film }
        return d
    }

    static func artistDraft(_ a: MusicArtist) -> MusicEntityDraft {
        var d = MusicEntityDraft(kind: .person, name: a.name, imageRef: a.thumbnails.best(minSide: 300), externalIDs: a.id.isEmpty ? [] : [ExternalID(.provider, a.uid)], provisional: true)
        if !a.genres.isEmpty { d.attrs["genres"] = a.genres.prefix(5).joined(separator: ",") }
        return d
    }

    /// A credited name. An empty provider id (plain text artist) mints a provisional person by name alone.
    static func artistDraft(_ a: MusicArtistRef, providerID: String) -> MusicEntityDraft {
        MusicEntityDraft(kind: .person, name: a.name, imageRef: a.thumbnails.best(minSide: 300),
                         externalIDs: a.id.isEmpty ? [] : [ExternalID(.provider, providerID + ":" + a.id)], provisional: true)
    }

    static func playlistDraft(_ p: MusicPlaylist) -> MusicEntityDraft {
        MusicEntityDraft(kind: .playlist, name: p.name, imageRef: p.thumbnails.best(minSide: 300), attrs: p.owner.map { ["owner": $0] } ?? [:],
                         externalIDs: [ExternalID(.provider, p.uid)], provisional: true)
    }

    static func plan(for item: MusicBrowseItem) -> MusicMintPlan {
        switch item {
        case .track(let t): plan(for: t)
        case .album(let a): plan(for: a)
        case .artist(let a): MusicMintPlan(primary: artistDraft(a), source: MusicSourceID(a.providerID))
        case .playlist(let p): MusicMintPlan(primary: playlistDraft(p), source: MusicSourceID(p.providerID))
        }
    }

    /// The stable id a browse item will get, with no database read.
    static func provisionalID(for item: MusicBrowseItem) -> MusicEntityID {
        switch item {
        case .track(let t): .provisional(kind: .recording, providerUID: t.uid)
        case .album(let a): .provisional(kind: .release, providerUID: a.uid)
        case .artist(let a): .provisional(kind: .person, providerUID: a.uid)
        case .playlist(let p): .provisional(kind: .playlist, providerUID: p.uid)
        }
    }

    // MARK: catalogue and film

    /// A canonical catalogue entry: its key becomes a `canon` alias, the version tags and film string become hints, and every playable twin a provider uid alias.
    static func draft(for c: MusicCanonicalTrack) -> MusicEntityDraft {
        var d = MusicEntityDraft(kind: .recording, name: c.title, lang: c.language, year: c.year, durationMs: c.durationMs > 0 ? Int(c.durationMs) : nil, imageRef: c.coverURL,
                                 externalIDs: c.seenOn.map { ExternalID(.provider, $0) } + [ExternalID(.canon, c.key)], provisional: true)
        if let isrc = c.isrc, !isrc.isEmpty { d.externalIDs.append(ExternalID(.isrc, isrc.uppercased())) }
        if !c.versionTags.isEmpty { d.attrs["versionTags"] = c.versionTags.joined(separator: ","); d.attrs["versionKind"] = versionKind(tags: c.versionTags).rawValue }
        if let f = c.film, !f.isEmpty { d.attrs["filmHint"] = f }
        return d
    }

    /// The film, its cast, directors and composers as claims from the source that supplied them. TMDB rows expire after 30 days (its retention rule).
    static func plan(for f: MusicFilmInfo) -> MusicMintPlan {
        var ids: [ExternalID] = []
        if let t = f.tmdbID { ids.append(ExternalID(.tmdbMovie, String(t))) }
        if let w = f.wikidataID { ids.append(ExternalID(.wikidata, w)) }
        if let i = f.imdbID { ids.append(ExternalID(.imdbTitle, i)) }
        let film = MusicEntityDraft(kind: .film, name: f.title, lang: f.language, year: f.year, externalIDs: ids, provisional: ids.isEmpty)
        let source: MusicSourceID = f.source == .tmdb ? .tmdb : (f.source == .wikidata ? .wikidata : .jiosaavn)
        var plan = MusicMintPlan(primary: film, source: source, defaultScore: Float(f.provenance?.confidence ?? 0.9))
        plan.license = f.source == .tmdb ? .termsRestricted : (f.source == .wikidata ? .cc0 : .providerCache)
        plan.retrievedAt = f.provenance?.retrievedAt ?? Date()
        if f.source == .tmdb { plan.expiresAt = plan.retrievedAt.addingTimeInterval(30 * 86_400) }
        func person(_ p: MusicFilmPerson) -> MusicEntityDraft {
            var pid: [ExternalID] = []
            if let t = p.tmdbID { pid.append(ExternalID(.tmdbPerson, String(t))) }
            if let w = p.wikidataID { pid.append(ExternalID(.wikidata, w)) }
            if let i = p.imdbID { pid.append(ExternalID(.imdbName, i)) }
            return MusicEntityDraft(kind: .person, name: p.name, imageRef: p.photoURL, externalIDs: pid, provisional: pid.isEmpty)
        }
        for (i, p) in f.cast.enumerated() {
            var attrs = EdgeAttributes(); attrs.characterName = p.character; attrs.creditOrder = i
            plan.links.append(.init(draft: person(p), predicate: .hasCast, role: .actor, attributes: attrs, order: i, creditLevel: .film))
        }
        for p in f.directors { plan.links.append(.init(draft: person(p), predicate: .directedBy, role: .director, creditLevel: .film)) }
        for p in f.composers { plan.links.append(.init(draft: person(p), predicate: .composedBy, role: .composer, creditLevel: .film)) }
        return plan
    }

    // MARK: text helpers

    /// "Pushpa" from `Kantara (From "Pushpa")`-style titles; a hint only, never an edge.
    static func filmHint(inTitle title: String) -> String? {
        guard let r = title.range(of: #"[\(\[]\s*from\s+["“”']?([^"“”'\)\]]+)["“”']?\s*[\)\]]"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let inner = String(title[r])
        guard let q = inner.range(of: "from", options: .caseInsensitive) else { return nil }
        let name = inner[q.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " \"“”'()[]\t"))
        return name.isEmpty ? nil : name
    }

    /// A provider's album type and title as a subkind. "Soundtrack" here is the provider's wording, never proof of a film link.
    static func albumSubkind(type: String?, title: String) -> String? {
        let t = (type ?? "").lowercased(), n = title.lowercased()
        if t.contains("soundtrack") || n.contains("original motion picture soundtrack") || n.contains("(ost)") || n.hasSuffix(" ost") || n.contains("original soundtrack") { return MusicAlbumSubkind.soundtrack.rawValue }
        if t.contains("score") { return MusicAlbumSubkind.score.rawValue }
        if t == "ep" { return MusicAlbumSubkind.ep.rawValue }
        if t.contains("single") { return MusicAlbumSubkind.single.rawValue }
        if t.contains("compil") { return MusicAlbumSubkind.compilation.rawValue }
        if t.contains("album") { return MusicAlbumSubkind.album.rawValue }
        return nil
    }

    static func versionKind(tags: [String]) -> MusicVersionKind {
        let s = Set(tags.map { $0.lowercased() })
        for (tag, kind) in [("karaoke", MusicVersionKind.karaoke), ("remix", .remix), ("live", .live), ("cover", .cover), ("instrumental", .instrumental),
                            ("reprise", .reprise), ("acoustic", .acoustic), ("unplugged", .acoustic)] where s.contains(tag) { return kind }
        return .unknown
    }

    static func year(_ date: String?) -> Int? {
        guard let d = date, d.count >= 4, let y = Int(d.prefix(4)), (1000...2999).contains(y) else { return nil }
        return y
    }
}
