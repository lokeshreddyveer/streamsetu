import Foundation

/// Parsers for the replies the artwork sources read. Pure functions from bytes to small values; each was written against a live reply captured on
/// 2026-11-25 (the fixtures in the test target). A reply that is not the expected shape gives an empty list, never a crash.
enum MusicArtworkParsers {
    private static let maxBytes = 1_500_000

    private static func json(_ data: Data) -> [String: Any]? {
        guard data.count < maxBytes else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private static func str(_ v: Any?) -> String? { (v as? String).flatMap { $0.isEmpty ? nil : $0 } }
    private static func https(_ v: Any?) -> String? { str(v).flatMap { $0.hasPrefix("https://") ? $0 : ($0.hasPrefix("http://") ? "https://" + $0.dropFirst(7) : nil) } }
    private static func int(_ v: Any?) -> Int? { (v as? Int) ?? (v as? String).flatMap(Int.init) }

    // MARK: Wikidata

    struct WikidataHit: Hashable, Sendable {
        var id: String
        var label: String
        var description: String
        /// Every spelling the hit can be matched by: label, the matched alias or label, the aliases list.
        var names: [String]
    }

    /// `action=wbsearchentities`: `label`, `description`, `match.text`, `aliases`.
    static func wikidataSearch(_ data: Data) -> [WikidataHit] {
        guard let rows = json(data)?["search"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let id = str(r["id"]), id.hasPrefix("Q"), let label = str(r["label"]) else { return nil }
            var names = [label]
            if let m = str((r["match"] as? [String: Any])?["text"]) { names.append(m) }
            names += (r["aliases"] as? [String]) ?? []
            return WikidataHit(id: id, label: label, description: str(r["description"]) ?? "", names: names)
        }
    }

    struct WikidataFacts: Hashable, Sendable {
        var id: String
        var names: [String]
        /// P18, the general image (a Commons file name).
        var image: String?
        /// P3383, the film poster (a Commons file name).
        var poster: String?
        var imdb: String?
        var musicBrainz: String?
        var tmdbPerson: String?
        var tmdbMovie: String?
        var enwikiTitle: String?
    }

    /// `action=wbgetentities&props=claims|labels|aliases|sitelinks`. Deprecated statements are ignored; a preferred one wins over a normal one.
    static func wikidataEntities(_ data: Data) -> [String: WikidataFacts] {
        guard let entities = json(data)?["entities"] as? [String: Any] else { return [:] }
        var out: [String: WikidataFacts] = [:]
        for (qid, raw) in entities {
            guard let e = raw as? [String: Any], str(e["id"]) == qid else { continue }
            let claims = e["claims"] as? [String: Any] ?? [:]
            func value(_ p: String) -> String? {
                guard let list = claims[p] as? [[String: Any]] else { return nil }
                let usable = list.filter { ($0["rank"] as? String) != "deprecated" }
                let best = usable.first { ($0["rank"] as? String) == "preferred" } ?? usable.first
                return str(((best?["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"])
            }
            var names: [String] = []
            if let label = str(((e["labels"] as? [String: Any])?["en"] as? [String: Any])?["value"]) { names.append(label) }
            for a in ((e["aliases"] as? [String: Any])?["en"] as? [[String: Any]]) ?? [] { if let v = str(a["value"]) { names.append(v) } }
            let enwiki = str(((e["sitelinks"] as? [String: Any])?["enwiki"] as? [String: Any])?["title"])
            out[qid] = WikidataFacts(id: qid, names: names, image: value("P18"), poster: value("P3383"), imdb: value("P345"), musicBrainz: value("P434"),
                                     tmdbPerson: value("P4985"), tmdbMovie: value("P4947"), enwikiTitle: enwiki)
        }
        return out
    }

    // MARK: Wikipedia and Commons

    struct WikipediaImage: Hashable, Sendable {
        var title: String
        var wikibaseItem: String?
        var thumbnail: String?
    }

    /// `prop=pageimages|pageprops` for ONE exact title. The caller compares `wikibaseItem` with the id it already verified.
    static func wikipediaPageImage(_ data: Data) -> WikipediaImage? {
        guard let pages = (json(data)?["query"] as? [String: Any])?["pages"] as? [String: Any], pages.count == 1, let page = pages.values.first as? [String: Any],
              let title = str(page["title"]) else { return nil }
        let item = str((page["pageprops"] as? [String: Any])?["wikibase_item"])
        return WikipediaImage(title: title, wikibaseItem: item, thumbnail: https((page["thumbnail"] as? [String: Any])?["source"]))
    }

    struct CommonsImage: Hashable, Sendable {
        var thumbnail: String
        var pageURL: String?
        var licence: String?
        var author: String?
        var attributionRequired: Bool

        /// "Author · Licence · Wikimedia Commons" when the licence asks for a credit or names an author.
        var creditLine: String? {
            let parts = [author, licence, "Wikimedia Commons"].compactMap { $0 }.filter { !$0.isEmpty }
            return attributionRequired || author != nil ? parts.joined(separator: " · ") : "Wikimedia Commons"
        }
    }

    /// `action=query&prop=imageinfo&iiprop=url|extmetadata&iiurlwidth=500&formatversion=2`.
    static func commonsImage(_ data: Data) -> CommonsImage? {
        guard let page = ((json(data)?["query"] as? [String: Any])?["pages"] as? [[String: Any]])?.first,
              let info = (page["imageinfo"] as? [[String: Any]])?.first, let thumb = https(info["thumburl"]) else { return nil }
        let meta = info["extmetadata"] as? [String: Any] ?? [:]
        func m(_ k: String) -> String? { str((meta[k] as? [String: Any])?["value"]) }
        let author = m("Artist").map { stripTags($0) }.flatMap { $0.isEmpty ? nil : $0 }
        return CommonsImage(thumbnail: thumb, pageURL: https(info["descriptionurl"]), licence: m("LicenseShortName"), author: author,
                            attributionRequired: (m("AttributionRequired") ?? "false").lowercased() == "true")
    }

    static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: MusicBrainz

    struct MBArtistHit: Hashable, Sendable { var id: String; var name: String; var sortName: String?; var score: Int }

    static func musicBrainzArtists(_ data: Data) -> [MBArtistHit] {
        guard let rows = json(data)?["artists"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let id = str(r["id"]), let name = str(r["name"]) else { return nil }
            return MBArtistHit(id: id, name: name, sortName: str(r["sort-name"]), score: int(r["score"]) ?? 0)
        }
    }

    struct MBArtistLinks: Hashable, Sendable { var wikidata: String?; var imdbName: String? }

    /// `artist/{mbid}?inc=url-rels`: the Wikidata item and the IMDb name page the artist is linked to.
    static func musicBrainzArtistLinks(_ data: Data) -> MBArtistLinks {
        var links = MBArtistLinks()
        for r in (json(data)?["relations"] as? [[String: Any]]) ?? [] {
            guard let url = str((r["url"] as? [String: Any])?["resource"]) else { continue }
            switch str(r["type"]) {
            case "wikidata": if let q = url.components(separatedBy: "/wiki/").last, q.hasPrefix("Q"), q.dropFirst().allSatisfy(\.isNumber) { links.wikidata = q }
            case "IMDb": if let nm = url.components(separatedBy: "/name/").dropFirst().first?.split(separator: "/").first, nm.hasPrefix("nm") { links.imdbName = String(nm) }
            default: break
            }
        }
        return links
    }

    struct MBReleaseGroupHit: Hashable, Sendable { var id: String; var title: String; var artists: [String]; var score: Int; var primaryType: String? }

    static func musicBrainzReleaseGroups(_ data: Data) -> [MBReleaseGroupHit] {
        guard let rows = json(data)?["release-groups"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let id = str(r["id"]), let title = str(r["title"]) else { return nil }
            let names = ((r["artist-credit"] as? [[String: Any]]) ?? []).compactMap { str($0["name"]) }
            return MBReleaseGroupHit(id: id, title: title, artists: names, score: int(r["score"]) ?? 0, primaryType: str(r["primary-type"]))
        }
    }

    // MARK: TMDB (documented shapes: developer.themoviedb.org search/person, search/movie, person, movie)

    struct TMDBPerson: Hashable, Sendable { var id: Int; var name: String; var department: String?; var profilePath: String?; var knownFor: [String] }
    struct TMDBMovie: Hashable, Sendable { var id: Int; var title: String; var originalTitle: String?; var year: Int?; var posterPath: String? }

    static func tmdbPeople(_ data: Data) -> [TMDBPerson] {
        guard let rows = json(data)?["results"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let id = int(r["id"]), let name = str(r["name"]) else { return nil }
            let titles = ((r["known_for"] as? [[String: Any]]) ?? []).compactMap { str($0["title"]) ?? str($0["name"]) }
            return TMDBPerson(id: id, name: name, department: str(r["known_for_department"]), profilePath: str(r["profile_path"]), knownFor: titles)
        }
    }

    /// One person's detail (`/3/person/{id}`) as a single-item list.
    static func tmdbPerson(_ data: Data) -> TMDBPerson? {
        guard let j = json(data), let id = int(j["id"]), let name = str(j["name"]) else { return nil }
        return TMDBPerson(id: id, name: name, department: str(j["known_for_department"]), profilePath: str(j["profile_path"]), knownFor: [])
    }

    static func tmdbMovies(_ data: Data) -> [TMDBMovie] {
        guard let rows = json(data)?["results"] as? [[String: Any]] else { return [] }
        return rows.compactMap(movie)
    }
    static func tmdbMovie(_ data: Data) -> TMDBMovie? { json(data).flatMap(movie) }
    private static func movie(_ r: [String: Any]) -> TMDBMovie? {
        guard let id = int(r["id"]), let title = str(r["title"]) ?? str(r["name"]) else { return nil }
        let date = str(r["release_date"]) ?? str(r["first_air_date"])
        return TMDBMovie(id: id, title: title, originalTitle: str(r["original_title"]) ?? str(r["original_name"]), year: date.flatMap { Int($0.prefix(4)) }, posterPath: str(r["poster_path"]))
    }

    // MARK: IMDb suggestion (undocumented; shape observed live)

    struct IMDbHit: Hashable, Sendable { var id: String; var label: String; var year: Int?; var type: String?; var line: String?; var image: String? }

    static func imdbSuggestions(_ data: Data) -> [IMDbHit] {
        guard let rows = json(data)?["d"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let id = str(r["id"]), id.hasPrefix("nm") || id.hasPrefix("tt"), let label = str(r["l"]) else { return nil }
            return IMDbHit(id: id, label: label, year: int(r["y"]), type: str(r["qid"]), line: str(r["s"]), image: https((r["i"] as? [String: Any])?["imageUrl"]))
        }
    }

    // MARK: Deezer

    struct DeezerAlbum: Hashable, Sendable { var id: Int; var title: String; var cover: String?; var artist: String; var artistID: Int?; var artistPicture: String? }
    struct DeezerArtist: Hashable, Sendable { var id: Int; var name: String; var picture: String? }

    private static func deezerArtistBlock(_ a: [String: Any]?) -> (name: String, id: Int?, picture: String?)? {
        guard let a, let name = str(a["name"]) else { return nil }
        let pic = https(a["picture_big"]) ?? https(a["picture_medium"])
        return (name, int(a["id"]), pic.flatMap { MusicArtworkMatch.isDeezerPlaceholder($0) ? nil : $0 })
    }

    /// `search/album`: the album and the artist block it carries (`picture_big`), which is how a person's picture is found through a work they made.
    static func deezerAlbums(_ data: Data) -> [DeezerAlbum] {
        guard let rows = json(data)?["data"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let id = int(r["id"]), let title = str(r["title"]), let a = deezerArtistBlock(r["artist"] as? [String: Any]) else { return nil }
            let cover = https(r["cover_big"]) ?? https(r["cover_medium"])
            return DeezerAlbum(id: id, title: title, cover: cover.flatMap { MusicArtworkMatch.isDeezerPlaceholder($0) ? nil : $0 }, artist: a.name, artistID: a.id, artistPicture: a.picture)
        }
    }

    /// `search/track`: a song's own album cover (`album.cover_big`) and its artist block.
    static func deezerTracks(_ data: Data) -> [DeezerAlbum] {
        guard let rows = json(data)?["data"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let id = int(r["id"]), let title = str(r["title"]), let a = deezerArtistBlock(r["artist"] as? [String: Any]) else { return nil }
            let cover = https((r["album"] as? [String: Any])?["cover_big"]) ?? https((r["album"] as? [String: Any])?["cover_medium"])
            return DeezerAlbum(id: id, title: title, cover: cover.flatMap { MusicArtworkMatch.isDeezerPlaceholder($0) ? nil : $0 }, artist: a.name, artistID: a.id, artistPicture: a.picture)
        }
    }

    /// `artist/{id}` (also one row of `search/artist`).
    static func deezerArtist(_ data: Data) -> DeezerArtist? {
        guard let j = json(data), let id = int(j["id"]), let a = deezerArtistBlock(j) else { return nil }
        return DeezerArtist(id: id, name: a.name, picture: a.picture)
    }

    // MARK: iTunes

    struct ITunesItem: Hashable, Sendable {
        var title: String
        var collection: String
        var artist: String
        var art100: String
        var year: Int?
        var genre: String?
    }

    /// `search?entity=album|song`: an album row has `collectionName`, a song row `trackName`.
    static func itunes(_ data: Data) -> [ITunesItem] {
        guard let rows = json(data)?["results"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let art = https(r["artworkUrl100"]), let collection = str(r["collectionName"]) else { return nil }
            let artist = str(r["collectionArtistName"]) ?? str(r["artistName"]) ?? ""
            return ITunesItem(title: str(r["trackName"]) ?? collection, collection: collection, artist: artist, art100: art,
                              year: str(r["releaseDate"]).flatMap { Int($0.prefix(4)) }, genre: str(r["primaryGenreName"]))
        }
    }

    // MARK: JioSaavn (unofficial `autocomplete.get`; shape observed live)

    struct SaavnItem: Hashable, Sendable {
        enum Kind: String, Sendable { case album, song, artist }
        var kind: Kind
        var id: String
        var title: String
        var image: String
        /// Albums: music director; songs: the line "Album · Artists"; artists: the role ("Music director").
        var detail: String
        var year: Int?
    }

    static func saavnAutocomplete(_ data: Data) -> [SaavnItem] {
        guard let j = json(data) else { return [] }
        var out: [SaavnItem] = []
        for (key, kind) in [("albums", SaavnItem.Kind.album), ("songs", .song), ("artists", .artist)] {
            for r in ((j[key] as? [String: Any])?["data"] as? [[String: Any]]) ?? [] {
                guard let id = str(r["id"]), let title = str(r["title"]), let image = https(r["image"]) else { continue }
                let detail: String
                switch kind {
                case .album: detail = [str(r["music"]), str(r["description"])].compactMap { $0 }.joined(separator: " · ")
                case .song: detail = str(r["description"]) ?? ""
                case .artist: detail = [str(r["extra"]), str(r["description"])].compactMap { $0 }.joined(separator: " ")
                }
                out.append(SaavnItem(kind: kind, id: id, title: title, image: image, detail: detail, year: int((r["more_info"] as? [String: Any])?["year"])))
            }
        }
        return out
    }
}
