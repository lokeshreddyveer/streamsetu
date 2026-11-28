import Foundation

// The catalogue sources of the artwork chain: TMDB (through the app's own client), IMDb's suggestion list, Deezer, iTunes and JioSaavn.
// A person's picture is only taken when the source can show it is that person (a known id, or name plus job or a work they made).

/// TMDB through the app's gate. A person needs their TMDB id, or an exact name that is the only one whose department fits and whose known work is one we know.
struct TMDBArtworkSource: MusicArtworkSource {
    var id: MusicArtworkSourceID { .tmdb }
    var switchID: MusicSourceID? { .tmdb }
    func applies(to kind: MusicEntityKind) -> Bool { kind.isAgent || kind == .film || kind == .series }

    /// TMDB's department names that fit our jobs.
    static func departmentFits(_ department: String?, roles: [MusicArtworkRole]) -> Bool {
        guard let d = department?.lowercased(), !roles.isEmpty else { return false }
        return roles.contains { r in
            switch r {
            case .actor: d == "acting"
            case .director: d == "directing"
            case .composer, .singer, .group: d == "sound"
            case .lyricist: d == "writing" || d == "sound"
            }
        }
    }

    func candidates(for s: MusicArtworkSubject, context: MusicArtworkContext) async throws -> [MusicArtworkCandidate] {
        guard let tmdb = context.tmdb else { return [] }
        if s.isPersonLike { return try await person(s, tmdb) }
        return try await film(s, tmdb)
    }

    private func person(_ s: MusicArtworkSubject, _ tmdb: @Sendable (String, [URLQueryItem]) async throws -> Data) async throws -> [MusicArtworkCandidate] {
        if let known = s.externalID(.tmdbPerson) {
            guard let p = MusicArtworkParsers.tmdbPerson(try await tmdb("/3/person/" + known, [])), let path = p.profilePath, MusicArtworkMatch.namesMatch(p.name, s.name) else { return [] }
            return [MusicArtworkCandidate(address: MusicArtworkMatch.tmdbProfile(path), source: .tmdb, confidence: 1, evidence: ["tmdb-id"], credit: "TMDB")]
        }
        let people = MusicArtworkParsers.tmdbPeople(try await tmdb("/3/search/person", [URLQueryItem(name: "query", value: s.name), URLQueryItem(name: "include_adult", value: "false")]))
        let exact = people.filter { MusicArtworkMatch.namesMatch($0.name, s.name) }
        let workKeys = Set(s.works.map(MusicArtworkMatch.workKey))
        func evidence(_ p: MusicArtworkParsers.TMDBPerson) -> [String] {
            var e = ["name"]
            if Self.departmentFits(p.department, roles: s.roles) { e.append("department") }
            if p.knownFor.contains(where: { workKeys.contains(MusicArtworkMatch.workKey($0)) }) { e.append("known-work") }
            return e
        }
        // With several people of this name only one known work can pick one; with one, a fitting department or a known work is enough.
        let pool = exact.count == 1 ? exact : exact.filter { evidence($0).contains("known-work") }
        guard pool.count == 1, let p = pool.first, let path = p.profilePath else { return [] }
        let ev = evidence(p)
        guard ev.count >= 2 else { return [] }
        return [MusicArtworkCandidate(address: MusicArtworkMatch.tmdbProfile(path), source: .tmdb, confidence: ev.count >= 3 ? 0.92 : 0.8, evidence: ev, credit: "TMDB")]
    }

    private func film(_ s: MusicArtworkSubject, _ tmdb: @Sendable (String, [URLQueryItem]) async throws -> Data) async throws -> [MusicArtworkCandidate] {
        let tv = s.kind == .series
        if let known = s.externalID(.tmdbMovie) ?? s.externalID(.tmdbTV) {
            guard let m = MusicArtworkParsers.tmdbMovie(try await tmdb((tv ? "/3/tv/" : "/3/movie/") + known, [])), let path = m.posterPath else { return [] }
            return [MusicArtworkCandidate(address: MusicArtworkMatch.tmdbPoster(path), source: .tmdb, confidence: 1, evidence: ["tmdb-id"], credit: "TMDB")]
        }
        var q = [URLQueryItem(name: "query", value: s.name)]
        if let y = s.year, !tv { q.append(URLQueryItem(name: "year", value: String(y))) }
        let movies = MusicArtworkParsers.tmdbMovies(try await tmdb(tv ? "/3/search/tv" : "/3/search/movie", q))
        let fits = movies.filter { m in
            (MusicArtworkMatch.titlesMatch(m.title, s.name) || (m.originalTitle.map { MusicArtworkMatch.titlesMatch($0, s.name) } ?? false)) && (s.year == nil || m.year == s.year)
        }
        guard fits.count == 1, let m = fits.first, let path = m.posterPath else { return [] }
        return [MusicArtworkCandidate(address: MusicArtworkMatch.tmdbPoster(path), source: .tmdb, confidence: s.year == nil ? 0.72 : 0.9, evidence: s.year == nil ? ["title"] : ["title", "year"], credit: "TMDB")]
    }
}

/// IMDb's public suggestion list (undocumented, best effort, behind the IMDb breaker). A person needs name and a job or work on the one-line description;
/// a film needs title and year.
struct IMDbArtworkSource: MusicArtworkSource {
    var id: MusicArtworkSourceID { .imdb }
    var switchID: MusicSourceID? { .imdb }
    func applies(to kind: MusicEntityKind) -> Bool { kind.isAgent || kind == .film || kind == .series }

    /// The lower-case, underscore form of the query IMDb's suggestion path takes. Non-Latin names are romanised first.
    static func slug(_ name: String) -> String {
        let ascii = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let base = ascii.unicodeScalars.allSatisfy { $0.isASCII } ? ascii : MusicGraphText.latin(name)
        return base.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
            .replacingOccurrences(of: "_+", with: "_", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    func candidates(for s: MusicArtworkSubject, context: MusicArtworkContext) async throws -> [MusicArtworkCandidate] {
        let slug = Self.slug(s.name)
        guard let first = slug.first, let raw = try await MusicArtworkNet.get(context, "https://v2.sg.media-imdb.com/suggestion/\(first)/\(slug).json") else { return [] }
        let hits = MusicArtworkParsers.imdbSuggestions(raw)
        if s.isPersonLike {
            let workKeys = Set(s.works.map(MusicArtworkMatch.workKey))
            let people = hits.filter { $0.id.hasPrefix("nm") && MusicArtworkMatch.namesMatch($0.label, s.name) }
            func evidence(_ h: MusicArtworkParsers.IMDbHit) -> [String] {
                let line = (h.line ?? "")
                var e = ["name"]
                if !s.roles.isEmpty, MusicArtworkMatch.roleFits(description: line, roles: s.roles) { e.append("role") }
                if workKeys.contains(where: { !$0.isEmpty && MusicArtworkMatch.workKey(line).contains($0) }) { e.append("known-work") }
                return e
            }
            let strong = people.filter { evidence($0).count >= 2 }
            guard strong.count == 1, let h = strong.first, let image = h.image else { return [] }
            if let known = s.externalID(.imdbName), known != h.id { return [] }
            let ev = evidence(h)
            return [MusicArtworkCandidate(address: image, source: .imdb, confidence: ev.count >= 3 ? 0.9 : 0.8, evidence: ev, credit: "IMDb")]
        }
        let kinds: Set<String> = ["movie", "tvMovie", "video", "tvSeries", "tvMiniSeries"]
        let films = hits.filter { $0.id.hasPrefix("tt") && ($0.type.map(kinds.contains) ?? false) && MusicArtworkMatch.titlesMatch($0.label, s.name) && (s.year == nil || $0.year == s.year) }
        guard films.count == 1, let f = films.first, let image = f.image else { return [] }
        if let known = s.externalID(.imdbTitle), known != f.id { return [] }
        return [MusicArtworkCandidate(address: image, source: .imdb, confidence: s.year == nil ? 0.72 : 0.88, evidence: s.year == nil ? ["title"] : ["title", "year"], credit: "IMDb")]
    }
}

/// Deezer. A person's picture comes from the artist block of an album they made (title plus exact artist name), or from a Deezer id the graph holds.
/// Works come from the album or song search when title and artist agree. A film borrows its soundtrack album's cover.
struct DeezerArtworkSource: MusicArtworkSource {
    var id: MusicArtworkSourceID { .deezer }
    var switchID: MusicSourceID? { nil }
    func applies(to kind: MusicEntityKind) -> Bool { true }

    private static let api = "https://api.deezer.com/"

    func candidates(for s: MusicArtworkSubject, context: MusicArtworkContext) async throws -> [MusicArtworkCandidate] {
        switch s.kind {
        case .person, .group: return try await person(s, context)
        case .album, .release: return try await album(s, context)
        case .recording, .track, .work: return try await song(s, context)
        case .film, .series: return try await soundtrack(s, context)
        default: return []
        }
    }

    private func person(_ s: MusicArtworkSubject, _ context: MusicArtworkContext) async throws -> [MusicArtworkCandidate] {
        if s.providerID == "deezer", let item = s.providerItemID, Int(item) != nil, let raw = try await MusicArtworkNet.get(context, Self.api + "artist/" + item),
           let a = MusicArtworkParsers.deezerArtist(raw), MusicArtworkMatch.namesMatch(a.name, s.name), let pic = a.picture {
            return [MusicArtworkCandidate(address: pic, source: .deezer, confidence: 1, evidence: ["provider-id"], credit: "Deezer")]
        }
        for work in s.works.prefix(3) {
            guard let raw = try await MusicArtworkNet.get(context, Self.api + "search/album", ["q": work + " " + s.name, "limit": "10"]) else { continue }
            let hit = MusicArtworkParsers.deezerAlbums(raw).first { MusicArtworkMatch.titlesMatch($0.title, work) && MusicArtworkMatch.namesMatch($0.artist, s.name) && $0.artistPicture != nil }
            if let pic = hit?.artistPicture {
                return [MusicArtworkCandidate(address: pic, source: .deezer, confidence: 0.88, evidence: ["name", "work:" + work], credit: "Deezer")]
            }
        }
        return []
    }

    private func album(_ s: MusicArtworkSubject, _ context: MusicArtworkContext) async throws -> [MusicArtworkCandidate] {
        guard let raw = try await MusicArtworkNet.get(context, Self.api + "search/album", ["q": s.name + " " + (s.creator ?? ""), "limit": "10"]) else { return [] }
        let matches = MusicArtworkParsers.deezerAlbums(raw).filter { h in
            MusicArtworkMatch.titlesMatch(h.title, s.name) && (s.creator.map { MusicArtworkMatch.creatorsOverlap($0, h.artist) } ?? true) && h.cover != nil
        }
        // With no artist to compare, a title shared by several different albums proves nothing: only a unique one is taken.
        let hit = s.creator == nil ? (matches.count == 1 ? matches.first : nil) : matches.first
        guard let cover = hit?.cover else { return [] }
        return [MusicArtworkCandidate(address: cover, source: .deezer, confidence: s.creator == nil ? 0.7 : 0.85, evidence: s.creator == nil ? ["title"] : ["title+artist"], credit: "Deezer")]
    }

    private func song(_ s: MusicArtworkSubject, _ context: MusicArtworkContext) async throws -> [MusicArtworkCandidate] {
        guard let raw = try await MusicArtworkNet.get(context, Self.api + "search/track", ["q": s.name + " " + (s.creator ?? ""), "limit": "10"]) else { return [] }
        let hit = MusicArtworkParsers.deezerTracks(raw).first { h in
            MusicArtworkMatch.titlesMatch(h.title, s.name) && (s.creator.map { MusicArtworkMatch.creatorsOverlap($0, h.artist) } ?? false) && h.cover != nil
        }
        guard let cover = hit?.cover else { return [] }
        return [MusicArtworkCandidate(address: cover, source: .deezer, confidence: 0.85, evidence: ["title+artist"], credit: "Deezer")]
    }

    /// A film with no poster: the cover of its soundtrack album (title equal, "soundtrack" in the album title).
    private func soundtrack(_ s: MusicArtworkSubject, _ context: MusicArtworkContext) async throws -> [MusicArtworkCandidate] {
        guard let raw = try await MusicArtworkNet.get(context, Self.api + "search/album", ["q": s.name + " soundtrack", "limit": "10"]) else { return [] }
        let hit = MusicArtworkParsers.deezerAlbums(raw).first { h in
            let t = h.title.lowercased()
            return MusicArtworkMatch.titlesMatch(h.title, s.name) && (t.contains("soundtrack") || t.contains("motion picture") || t.contains("ost")) && h.cover != nil
        }
        guard let cover = hit?.cover else { return [] }
        return [MusicArtworkCandidate(address: cover, source: .deezer, confidence: 0.72, evidence: ["soundtrack-title"], credit: "Deezer")]
    }
}

/// iTunes Search (Indian store first). About 20 calls a minute, so its lane is slow and every answer is cached.
struct ITunesArtworkSource: MusicArtworkSource {
    var id: MusicArtworkSourceID { .itunes }
    var switchID: MusicSourceID? { nil }
    func applies(to kind: MusicEntityKind) -> Bool { !kind.isAgent && (kind.isWork || kind == .film) }

    func candidates(for s: MusicArtworkSubject, context: MusicArtworkContext) async throws -> [MusicArtworkCandidate] {
        let song = s.isSongLike
        let term = s.isFilmLike ? s.name + " soundtrack" : s.name + " " + (s.creator ?? "")
        guard let raw = try await MusicArtworkNet.get(context, "https://itunes.apple.com/search", ["term": term, "entity": song ? "song" : "album", "country": "in", "limit": "10"]) else { return [] }
        let items = MusicArtworkParsers.itunes(raw)
        let hit: MusicArtworkParsers.ITunesItem?
        var evidence = ["title+artist"]
        var confidence = 0.85
        if s.isFilmLike {
            hit = items.first { i in
                let c = i.collection.lowercased()
                return MusicArtworkMatch.titlesMatch(i.collection, s.name) && (c.contains("soundtrack") || c.contains("motion picture") || c.contains("from \"") || (i.genre ?? "").lowercased().contains("soundtrack"))
                    && (s.year == nil || i.year.map { abs($0 - s.year!) <= 1 } ?? true)
            }
            evidence = ["soundtrack-title"]; confidence = 0.72
        } else {
            hit = items.first { i in
                MusicArtworkMatch.titlesMatch(song ? i.title : i.collection, s.name) && (s.creator.map { MusicArtworkMatch.creatorsOverlap($0, i.artist) } ?? false)
            }
            let sameTitle = items.filter { MusicArtworkMatch.titlesMatch(song ? $0.title : $0.collection, s.name) }
            if hit == nil, s.creator == nil, sameTitle.count == 1, let only = sameTitle.first {
                return [MusicArtworkCandidate(address: MusicArtworkMatch.iTunesLarge(only.art100), source: .itunes, confidence: 0.7, evidence: ["title"], credit: "Apple Music"),
                        MusicArtworkCandidate(address: only.art100, source: .itunes, confidence: 0.69, evidence: ["title"], credit: "Apple Music")]
            }
        }
        guard let hit else { return [] }
        return [MusicArtworkCandidate(address: MusicArtworkMatch.iTunesLarge(hit.art100), source: .itunes, confidence: confidence, evidence: evidence, credit: "Apple Music"),
                MusicArtworkCandidate(address: hit.art100, source: .itunes, confidence: confidence - 0.01, evidence: evidence, credit: "Apple Music")]
    }
}

/// JioSaavn's public search (unofficial, may change). Indian albums, songs and soundtrack covers; a person only with a JioSaavn artist id or an exact,
/// unique name whose role line ("Music director") fits.
struct JioSaavnArtworkSource: MusicArtworkSource {
    var id: MusicArtworkSourceID { .jiosaavn }
    var switchID: MusicSourceID? { nil }
    func applies(to kind: MusicEntityKind) -> Bool { kind.isAgent || kind.isWork || kind == .film }

    func candidates(for s: MusicArtworkSubject, context: MusicArtworkContext) async throws -> [MusicArtworkCandidate] {
        let query = s.isPersonLike ? s.name : s.name + " " + (s.creator ?? "")
        guard let raw = try await MusicArtworkNet.get(context, "https://www.jiosaavn.com/api.php",
                                                      ["__call": "autocomplete.get", "_format": "json", "_marker": "0", "cc": "in", "includeMetaTags": "1", "query": query]) else { return [] }
        let items = MusicArtworkParsers.saavnAutocomplete(raw)
        func candidate(_ item: MusicArtworkParsers.SaavnItem, _ conf: Double, _ ev: [String]) -> [MusicArtworkCandidate] {
            [MusicArtworkCandidate(address: MusicArtworkMatch.saavnLarge(item.image), source: .jiosaavn, confidence: conf, evidence: ev, credit: "JioSaavn")]
        }
        if s.isPersonLike {
            let people = items.filter { $0.kind == .artist && MusicArtworkMatch.namesMatch($0.title, s.name) }
            if s.providerID == "jiosaavn", let id = s.providerItemID, let p = people.first(where: { $0.id == id }) { return candidate(p, 1, ["provider-id"]) }
            guard people.count == 1, let p = people.first, !s.roles.isEmpty, MusicArtworkMatch.roleFits(description: p.detail, roles: s.roles) else { return [] }
            return candidate(p, 0.78, ["name", "role"])
        }
        if s.isFilmLike {
            let a = items.first { $0.kind == .album && MusicArtworkMatch.titlesMatch($0.title, s.name) && (s.year == nil || $0.year == s.year) }
            return a.map { candidate($0, 0.72, ["soundtrack-title"]) } ?? []
        }
        if s.isSongLike {
            let hit = items.first { i in i.kind == .song && MusicArtworkMatch.titlesMatch(i.title, s.name) && (s.creator.map { MusicArtworkMatch.lineMentions(i.detail, creator: $0) } ?? false) }
            return hit.map { candidate($0, 0.82, ["title+artist"]) } ?? []
        }
        let hit = items.first { i in
            i.kind == .album && MusicArtworkMatch.titlesMatch(i.title, s.name) && (s.creator.map { MusicArtworkMatch.lineMentions(i.detail, creator: $0) } ?? false)
        }
        return hit.map { candidate($0, 0.84, ["title+artist"]) } ?? []
    }
}
