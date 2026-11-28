import Foundation

// Film info: the film's cast and crew, as shown on an album page. Pure models and parsers; the lookup that fills them is MusicFilmService.

/// Where a fact came from, when, and how sure the match was (0...1). Carried by every film so a graph can merge sources later.
struct MusicFilmProvenance: Codable, Hashable, Sendable {
    var source: MusicFilmInfo.Source
    var retrievedAt: Date
    var confidence: Double
}

struct MusicFilmPerson: Codable, Hashable, Sendable, Identifiable {
    /// TMDB's id for the person, when the source had it.
    var tmdbID: Int?
    var wikidataID: String?
    var imdbID: String?
    var name: String
    /// The role the person played in this film (actors only).
    var character: String?
    /// A portrait address (TMDB w185 or a Wikimedia Commons file), nil for the initials circle.
    var photoURL: String?
    var id: String { tmdbID.map { "tmdb:\($0)" } ?? wikidataID.map { "wd:\($0)" } ?? "name:" + MusicTransliterationKey.key(name) }
}

struct MusicFilmInfo: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable { case tmdb, wikidata, provider }
    var title: String
    var year: Int?
    var language: String?
    var tmdbID: Int?
    /// The Wikidata QID.
    var wikidataID: String?
    var imdbID: String?
    var cast: [MusicFilmPerson] = []
    var directors: [MusicFilmPerson] = []
    var composers: [MusicFilmPerson] = []
    var singers: [String] = []
    var source: Source
    /// Source, time and match confidence of this film's facts (set by the service).
    var provenance: MusicFilmProvenance?
    /// Only TMDB's wording requires the attribution line; the others show their own small credit.
    var attributionName: String { source == .tmdb ? "TMDB" : source == .wikidata ? "Wikidata" : "JioSaavn" }
    var isUseful: Bool { !cast.isEmpty || !directors.isEmpty }
}

/// One film as TMDB lists it (a search result, or a row of an actor's filmography).
struct MusicFilmCredit: Codable, Hashable, Sendable, Identifiable {
    var tmdbID: Int
    var title: String
    var originalTitle: String
    var year: Int?
    var language: String?
    var character: String?
    var popularity: Double
    /// The person's billing in this film (0 is the lead), when the list says it; never the film's place in a filmography.
    var billingOrder: Int? = nil
    /// The poster's path on the image host, kept so the film has its picture the first time it is seen.
    var posterPath: String? = nil
    var id: Int { tmdbID }
}

// MARK: TMDB parsing (documented shapes: search/movie, movie/{id}?append_to_response=credits, person/{id}/movie_credits)

enum MusicFilmTMDBParser {
    static let imageBase = "https://image.tmdb.org/t/p/"

    static func credits(from data: Data, castKey: String = "results") -> [MusicFilmCredit] {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return (j[castKey] as? [[String: Any]] ?? []).compactMap(credit)
    }

    private static func credit(_ r: [String: Any]) -> MusicFilmCredit? {
        guard let id = r.int("id"), let title = r.str("title") ?? r.str("original_title") else { return nil }
        let date = r.str("release_date") ?? ""
        return MusicFilmCredit(tmdbID: id, title: title, originalTitle: r.str("original_title") ?? title, year: MusicFilmResolver.year(of: date),
                               language: r.str("original_language"), character: r.str("character"), popularity: (r["popularity"] as? Double) ?? Double(r.int("popularity") ?? 0), billingOrder: r.int("order"),
                               posterPath: r.str("poster_path"))
    }

    /// A credit that is the person as themselves, uncredited or archive footage: not a role in the film.
    static func isWalkOn(_ character: String?) -> Bool {
        let ch = (character ?? "").lowercased()
        return ch == "self" || ch.hasPrefix("self ") || ch.contains("uncredited") || ch.contains("himself") || ch.contains("herself") || ch.contains("archive footage")
    }

    /// An actor's films from `/3/person/{id}/movie_credits`: released films only, the person as "Self" and uncredited walk-ons left out.
    static func filmography(from data: Data, thisYear: Int = Calendar.current.component(.year, from: Date())) -> [MusicFilmCredit] {
        credits(from: data, castKey: "cast").filter { c in
            guard let y = c.year, y <= thisYear else { return false }
            return !isWalkOn(c.character)
        }
    }

    /// The film, its cast (billing order, top `castLimit`), director(s) and music composer(s) from `/3/movie/{id}?append_to_response=credits`.
    static func film(from data: Data, castLimit: Int = 8) -> MusicFilmInfo? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let id = j.int("id"), let title = j.str("title") ?? j.str("original_title") else { return nil }
        let credits = j.dict("credits") ?? [:]
        func person(_ r: [String: Any], character: Bool) -> MusicFilmPerson? {
            guard let name = r.str("name") else { return nil }
            return MusicFilmPerson(tmdbID: r.int("id"), name: name, character: character ? r.str("character") : nil,
                                   photoURL: r.str("profile_path").map { imageBase + "w185" + $0 })
        }
        let cast = credits.array("cast").filter { !Self.isWalkOn($0.str("character")) }.sorted { ($0.int("order") ?? 999) < ($1.int("order") ?? 999) }.compactMap { person($0, character: true) }
        let crew = credits.array("crew")
        func crewNamed(_ jobs: Set<String>) -> [MusicFilmPerson] {
            var seen = Set<String>(); var out: [MusicFilmPerson] = []
            for r in crew where jobs.contains((r.str("job") ?? "").lowercased()) {
                if let p = person(r, character: false), seen.insert(p.id).inserted { out.append(p) }
            }
            return out
        }
        let languageCode = j.str("original_language")
        return MusicFilmInfo(title: title, year: MusicFilmResolver.year(of: j.str("release_date")), language: languageCode, tmdbID: id, wikidataID: nil, imdbID: j.str("imdb_id"),
                             cast: Array(cast.prefix(castLimit)), directors: crewNamed(["director"]),
                             composers: crewNamed(["original music composer", "music", "composer", "music director"]), source: .tmdb)
    }

    static func personID(from data: Data, matching name: String) -> Int? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let rows = j.array("results")
        let best = rows.filter { MusicTransliterationKey.similarity(name, $0.str("name") ?? "") >= 0.95 }.max { ($0["popularity"] as? Double ?? 0) < ($1["popularity"] as? Double ?? 0) }
        return best?.int("id")
    }
}

// MARK: Wikidata parsing (wbsearchentities, wbgetentities)

enum MusicFilmWikidataParser {
    struct Hit: Hashable, Sendable { var id: String; var label: String; var description: String; var year: Int? }
    struct Film: Hashable, Sendable { var year: Int?; var cast: [String]; var directors: [String]; var composers: [String] }

    /// Only items described as a film are kept; the year comes from the description ("2023 Tamil film directed by ...").
    static func searchHits(from data: Data) -> [Hit] {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return j.array("search").compactMap { r in
            guard let id = r.str("id"), id.hasPrefix("Q"), let label = r.str("label") else { return nil }
            let d = r.str("description") ?? ""
            let lower = d.lowercased()
            guard lower.contains("film") || lower.contains("movie") else { return nil }
            // A soundtrack album, a short, a TV film and a documentary are not the film.
            guard !lower.contains("soundtrack") && !lower.contains("album") && !lower.contains("short film") && !lower.contains("song") else { return nil }
            let year = d.range(of: #"(?:19|20)\d\d"#, options: .regularExpression).flatMap { Int(d[$0]) }
            return Hit(id: id, label: label, description: d, year: year)
        }
    }

    /// P161 cast member, P57 director, P86 composer and P577 publication date of one entity from `wbgetentities`.
    static func film(from data: Data, id: String) -> Film? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let e = j.dict("entities")?.dict(id), let claims = e.dict("claims") else { return nil }
        func ids(_ p: String) -> [String] { claims.array(p).compactMap { $0.dict("mainsnak")?.dict("datavalue")?.dict("value")?.str("id") } }
        let date = claims.array("P577").compactMap { $0.dict("mainsnak")?.dict("datavalue")?.dict("value")?.str("time") }.first
        let year = date.flatMap { t in t.range(of: #"\d{4}"#, options: .regularExpression).flatMap { Int(t[$0]) } }
        return Film(year: year, cast: ids("P161"), directors: ids("P57"), composers: ids("P86"))
    }

    /// English labels and portrait files (P18) of a set of people.
    static func people(from data: Data) -> [String: MusicFilmPerson] {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let entities = j.dict("entities") else { return [:] }
        var out: [String: MusicFilmPerson] = [:]
        for (id, v) in entities {
            guard let e = v as? [String: Any], let label = e.dict("labels")?.dict("en")?.str("value") else { continue }
            let file = e.dict("claims")?.array("P18").compactMap { $0.dict("mainsnak")?.dict("datavalue")?.str("value") }.first
            out[id] = MusicFilmPerson(tmdbID: nil, wikidataID: id, name: label, character: nil, photoURL: file.flatMap(commonsURL))
        }
        return out
    }

    /// A Wikimedia Commons file as a 200-pixel-wide address.
    static func commonsURL(_ file: String) -> String? {
        var c = URLComponents(string: "https://commons.wikimedia.org/wiki/Special:FilePath/")
        c?.path = "/wiki/Special:FilePath/" + file.replacingOccurrences(of: " ", with: "_")
        c?.queryItems = [URLQueryItem(name: "width", value: "200")]
        return c?.url?.absoluteString
    }
}

// MARK: matching a film

enum MusicFilmMatch {
    /// A candidate's score, or nil when it is not the film. A year within one of the soundtrack's is accepted; a wider gap needs an exact title
    /// and a composer that both sources agree on (a soundtrack is often released under a later or earlier year than the film). With no year the
    /// title must be exact.
    static func score(identity: MusicFilmIdentity, titles: [String], year: Int?, language: String?, popularity: Double = 0) -> Double? {
        let sim = Double(titles.map { MusicTransliterationKey.similarity(identity.title, $0) }.max() ?? 0)
        guard sim >= 0.85 else { return nil }
        var s = sim
        if let a = identity.year, let b = year {
            let d = abs(a - b)
            if d > 1 { guard sim >= 1, d <= 4 else { return nil }; s -= 0.15 } else { s -= 0.03 * Double(d) }
        } else if sim < 0.95 { return nil }
        if let want = identity.language, let have = language, want == have { s += 0.08 }
        return s + min(popularity, 100) / 4000
    }

    /// The composer check that lets a wide year gap through: both sides must name a composer, and one must match.
    static func composersAgree(_ info: MusicFilmInfo, identity: MusicFilmIdentity) -> Bool {
        let names = info.composers.map(\.name)
        let mine = identity.musicBy
        guard !names.isEmpty, !mine.isEmpty else { return false }
        return names.contains { n in mine.contains { MusicTransliterationKey.similarity(n, $0) >= 0.9 } }
    }

    /// Final acceptance of a fetched film for an identity.
    static func accepts(_ info: MusicFilmInfo, identity: MusicFilmIdentity) -> Bool {
        if let a = identity.year, let b = info.year, abs(a - b) > 1 { return composersAgree(info, identity: identity) }
        return true
    }
}

// MARK: disk cache

/// A small keyed store on disk: 30 days for a found film, 2 days for "nothing found". `MusicHub.wipeAll` removes it.
final class MusicFilmCache: @unchecked Sendable {
    static let ttl: TimeInterval = 30 * 24 * 3600
    static let missTTL: TimeInterval = 2 * 24 * 3600
    static let shared = MusicFilmCache(directory: MusicStorage.subfolder("Film"))

    private struct Entry<T: Codable>: Codable { var at: Date; var value: T? }
    private let directory: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) { self.directory = directory; self.now = now }

    private func file(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? String($0) : "_" }.joined().prefix(120)
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    /// `.some(value)` for a fresh hit (a found film, or `.some(nil)` for a remembered miss); `nil` when unknown or expired.
    func read<T: Codable>(_ type: T.Type, key: String) -> T?? {
        lock.lock(); defer { lock.unlock() }
        guard let d = try? Data(contentsOf: file(key)), let e = try? JSONDecoder().decode(Entry<T>.self, from: d) else { return nil }
        let age = now().timeIntervalSince(e.at)
        guard age < (e.value == nil ? Self.missTTL : Self.ttl), age > -3600 else { try? FileManager.default.removeItem(at: file(key)); return nil }
        return .some(e.value)
    }

    func write<T: Codable>(_ value: T?, key: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(Entry(at: now(), value: value)) { try? d.write(to: file(key), options: .atomic) }
    }

    func wipe() { lock.lock(); defer { lock.unlock() }; try? FileManager.default.removeItem(at: directory) }
}
