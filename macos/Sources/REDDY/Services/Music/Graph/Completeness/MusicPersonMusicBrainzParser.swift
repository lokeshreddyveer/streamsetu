import Foundation

/// MusicBrainz (CC0 core data) for the person completeness pass: artist ids and links, and the browse lists that give the full discography.
/// `release-group?artist=` (albums, EPs, singles, with their secondary types), `work?artist=&inc=artist-rels` (compositions with composer and
/// lyricist relations) and `recording?artist=` (recordings the artist is credited on). Browse pages hold at most 100 rows; callers page by `offset`.
enum MusicPersonMusicBrainzParser {
    static let source = MusicSourceID.musicbrainz
    static let pageSize = 100

    struct ArtistHit: Sendable, Equatable { var mbid: String; var name: String; var score: Int; var type: String?; var disambiguation: String? }

    static func artistSearch(_ data: Data) -> [ArtistHit] {
        ((MusicSourceKit.json(data)?["artists"] as? [[String: Any]]) ?? []).compactMap { a in
            guard let id = MusicSourceKit.string(a["id"]), let n = MusicSourceKit.string(a["name"]) else { return nil }
            return ArtistHit(mbid: id, name: n, score: (a["score"] as? Int) ?? 0, type: a["type"] as? String, disambiguation: a["disambiguation"] as? String)
        }
    }

    /// Ids an artist lookup with `inc=url-rels` links to (Wikidata, IMDb name, TMDB person...).
    static func artistLinks(_ data: Data) -> [ExternalID] {
        (((MusicSourceKit.json(data)?["relations"]) as? [[String: Any]]) ?? []).compactMap { r in
            guard (r["target-type"] as? String) == "url", let res = (r["url"] as? [String: Any])?["resource"] as? String else { return nil }
            return MusicExternalLinks.externalID(fromURL: res)
        }
    }

    /// The artist whose own links name the person's Wikidata item or IMDb name id: the only way a name search result is accepted without Wikidata saying it.
    static func linked(_ links: [ExternalID], to ids: [ExternalID]) -> Bool {
        let mine = Set(ids.filter { [.wikidata, .imdbName, .tmdbPerson].contains($0.scheme) })
        return !mine.isEmpty && !mine.isDisjoint(with: links)
    }

    struct Page<T: Sendable>: Sendable { var items: [T]; var total: Int?; var raw: Int
        /// The offset of the next page, nil when this was the last (by the reply's own count, else by a short page).
        func next(offset: Int) -> Int? {
            guard raw > 0 else { return nil }
            if let t = total { return offset + raw < t ? offset + raw : nil }
            return raw >= MusicPersonMusicBrainzParser.pageSize ? offset + raw : nil
        }
    }

    private static func creditNames(_ credits: Any?) -> [String] {
        ((credits as? [[String: Any]]) ?? []).compactMap { c in
            let n = MusicSourceKit.string(c["name"]) ?? MusicSourceKit.string((c["artist"] as? [String: Any])?["name"])
            return n.flatMap { MusicCompilationArtist.isCompilation($0) ? nil : $0 }
        }
    }

    /// `release-group?artist=<mbid>&type=album|ep|single&limit=100&offset=N`.
    static func releaseGroups(_ data: Data) -> Page<MusicPersonWork> {
        let j = MusicSourceKit.json(data)
        let rows = (j?["release-groups"] as? [[String: Any]]) ?? []
        let items: [MusicPersonWork] = rows.compactMap { r in
            guard let id = MusicSourceKit.string(r["id"]), let t = MusicSourceKit.string(r["title"]) else { return nil }
            var w = MusicPersonWork(kind: .album, title: t, year: MusicSourceKit.year(r["first-release-date"] as? String),
                                    subkind: MusicBrainzParser.subkind(primary: r["primary-type"] as? String, secondary: (r["secondary-types"] as? [String]) ?? []),
                                    relations: [.performer], ids: [ExternalID(.mbReleaseGroup, id)], source: source, sourceRef: id)
            w.artists = creditNames(r["artist-credit"])
            return w
        }
        return Page(items: items, total: j?["release-group-count"] as? Int, raw: rows.count)
    }

    /// `work?artist=<mbid>&inc=artist-rels&limit=100&offset=N`: a work counts for the artist only through a composer, lyricist or writer relation to that artist.
    static func works(_ data: Data, artist mbid: String) -> Page<MusicPersonWork> {
        let j = MusicSourceKit.json(data)
        let rows = (j?["works"] as? [[String: Any]]) ?? []
        let items: [MusicPersonWork] = rows.compactMap { r in
            guard let id = MusicSourceKit.string(r["id"]), let t = MusicSourceKit.string(r["title"]) else { return nil }
            var rels: Set<MusicPersonRelation> = []
            for rel in (r["relations"] as? [[String: Any]]) ?? [] {
                guard (rel["target-type"] as? String) == "artist", ((rel["artist"] as? [String: Any])?["id"] as? String) == mbid, let type = rel["type"] as? String else { continue }
                switch type { case "composer", "arranger", "orchestrator": rels.insert(.composer); case "lyricist", "writer", "librettist": rels.insert(.lyricist); default: break }
            }
            guard !rels.isEmpty else { return nil }
            var w = MusicPersonWork(kind: .work, title: t, relations: rels, ids: [ExternalID(.mbWork, id)] + ((r["iswcs"] as? [String]) ?? []).map { ExternalID(.iswc, $0) },
                                    source: source, sourceRef: id)
            w.lang = MusicSourceKit.language(MusicSourceKit.string(r["language"]) ?? ((r["languages"] as? [String])?.first))
            return w
        }
        return Page(items: items, total: j?["work-count"] as? Int, raw: rows.count)
    }

    /// `recording?artist=<mbid>&inc=artist-credits+isrcs&limit=100&offset=N`.
    static func recordings(_ data: Data) -> Page<MusicPersonWork> {
        let j = MusicSourceKit.json(data)
        let rows = (j?["recordings"] as? [[String: Any]]) ?? []
        let items: [MusicPersonWork] = rows.compactMap { r in
            guard let id = MusicSourceKit.string(r["id"]), let t = MusicSourceKit.string(r["title"]) else { return nil }
            var w = MusicPersonWork(kind: .recording, title: t, year: MusicSourceKit.year(r["first-release-date"] as? String), relations: [.performer],
                                    ids: [ExternalID(.mbid, id)] + ((r["isrcs"] as? [String]) ?? []).map { ExternalID(.isrc, $0.uppercased()) }, source: source, sourceRef: id)
            w.artists = creditNames(r["artist-credit"])
            return w
        }
        return Page(items: items, total: j?["recording-count"] as? Int, raw: rows.count)
    }
}
