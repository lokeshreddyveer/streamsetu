import Foundation

// A person's complete filmography from TMDB, matched against the library on this device.
// Only a person id or an exact name is ever sent to TMDB; the matching below never leaves the device.

/// One film or series in a person's credits.
struct FilmCredit: Codable, Sendable, Equatable, Identifiable {
    var tmdbID: Int
    var isSeries: Bool
    var title: String
    var originalTitle: String?
    var date: String?
    var posterPath: String?
    var overview: String?
    var rating: Double?
    var votes: Int?
    var popularity: Double
    var role: String?
    /// Billing order in the cast (0 is the lead); nil for a crew credit.
    var order: Int? = nil
    var isCrewMaker = false

    var id: String { (isSeries ? "tv" : "movie") + String(tmdbID) }
    var year: Int? { date.flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil } }
    var posterURL: String? { posterPath.map { MetadataMatchService.imageBase + "w342" + $0 } }
    var kind: FilmRole { FilmRole.classify(character: role, order: order, isCrewMaker: isCrewMaker) }
}

/// What a cast credit is: an on-screen part, a voice or narration, or a cameo or guest appearance.
enum FilmRole: String, Codable, Sendable, Equatable {
    case lead, voice, cameo

    /// A cast order below this is a real part in the story (lead or supporting).
    static let onScreenOrder = 15

    /// The small tag on a tile: "Voice", "Narrator", "Cameo", "Guest"; none for an on-screen part.
    static func tag(character: String?, kind: FilmRole) -> String? {
        let c = (character ?? "").lowercased()
        switch kind {
        case .lead: return nil
        case .voice: return c.contains("narrat") ? "Narrator" : "Voice"
        case .cameo: return c.contains("guest") ? "Guest" : (c.isEmpty ? "Guest" : "Cameo")
        }
    }

    static func classify(character: String?, order: Int?, isCrewMaker: Bool = false) -> FilmRole {
        if isCrewMaker { return .lead }
        let c = (character ?? "").lowercased()
        if ["narrat", "voice", "dub"].contains(where: { c.contains($0) }) { return .voice }
        if ["cameo", "guest", "special appearance", "himself", "herself", "themselves"].contains(where: { c.contains($0) }) { return .cameo }
        if c.trimmingCharacters(in: .whitespaces).isEmpty, let o = order, o >= onScreenOrder { return .cameo }
        return .lead
    }
}

/// The about-the-person facts.
struct PersonProfile: Codable, Sendable, Equatable {
    var tmdbID: Int
    var name: String
    var biography: String?
    var birthday: String?
    var deathday: String?
    var placeOfBirth: String?
    var department: String?
    var profilePath: String?
    var alsoKnownAs: [String] = []
    var photos: [String] = []

    var photoURL: String? { profilePath.map { MetadataMatchService.imageBase + "w342" + $0 } }
}

/// What is kept for one person (30 days).
struct PersonFile: Codable, Sendable, Equatable {
    var profile: PersonProfile
    var credits: [FilmCredit]
    var language: String
    var fetchedAt: Double
}

enum PersonFacts {
    private static func date(_ s: String?) -> Date? { DateText.day(s) }

    /// "Born 5 Aug 1975 (age 51) · Chennai, India", or "Born ... · Died ... (aged 80)". Nil when nothing is known.
    static func bornLine(_ p: PersonProfile, now: Date = Date()) -> String? {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        var parts: [String] = []
        if let b = date(p.birthday) {
            var s = "Born " + DateText.short(b)
            if let d = date(p.deathday) {
                s += " · Died " + DateText.short(d)
                if let a = cal.dateComponents([.year], from: b, to: d).year { s += " (aged \(a))" }
            } else if let a = cal.dateComponents([.year], from: b, to: now).year, a >= 0 { s += " (age \(a))" }
            parts.append(s)
        }
        if let place = p.placeOfBirth?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty { parts.append(parts.isEmpty ? "Born in " + place : place) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Acting · Pokiri, Dookudu, Okkadu": the department and the best-known titles.
    static func knownFor(_ p: PersonProfile, credits: [FilmCredit], count: Int = 4) -> String? {
        let titles = credits.sorted { $0.popularity > $1.popularity }.prefix(count).map(\.title)
        let line = ([p.department?.nilIfBlank].compactMap { $0 } + (titles.isEmpty ? [] : [titles.joined(separator: ", ")])).joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    /// Other names, only when they are few and short.
    static func alsoKnownAs(_ p: PersonProfile) -> String? {
        let names = p.alsoKnownAs.filter { !$0.isEmpty && $0 != p.name }
        guard !names.isEmpty, names.count <= 3, names.joined(separator: ", ").count <= 60 else { return nil }
        return names.joined(separator: " · ")
    }
}

private extension String { var nilIfBlank: String? { let t = trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t } }

// MARK: parsing TMDB's replies

enum PersonParser {
    private static func obj(_ d: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
    private static func str(_ v: Any?) -> String? { (v as? String).flatMap { $0.nilIfBlank } }

    static func profile(_ data: Data) -> PersonProfile? {
        guard let j = obj(data), let id = j["id"] as? Int, let name = str(j["name"]) else { return nil }
        let profiles = (((j["images"] as? [String: Any])?["profiles"]) as? [[String: Any]]) ?? []
        return PersonProfile(tmdbID: id, name: name, biography: str(j["biography"]), birthday: str(j["birthday"]), deathday: str(j["deathday"]),
                             placeOfBirth: str(j["place_of_birth"]), department: str(j["known_for_department"]), profilePath: str(j["profile_path"]),
                             alsoKnownAs: ((j["also_known_as"] as? [String]) ?? []).prefix(6).map { $0 }, photos: profiles.compactMap { str($0["file_path"]) }.prefix(6).map { $0 })
    }

    /// Cast credits for an actor; for a director or creator, the crew credits with that job. Duplicates are merged, talk and news appearances and adult entries dropped, and a credit
    /// with neither a date nor a poster is dropped. `ratings` keep only credible values (the shared junk-rating rule).
    static func credits(_ data: Data, department: String?) -> [FilmCredit] {
        guard let j = obj(data) else { return [] }
        let cast = (j["cast"] as? [[String: Any]]) ?? [], crew = (j["crew"] as? [[String: Any]]) ?? []
        let makers = crew.filter { ["Director", "Creator"].contains(($0["job"] as? String) ?? "") }
        let wantsMaker = department == "Directing"
        let rows = wantsMaker ? (makers.isEmpty ? cast : makers) : (cast.isEmpty ? makers : cast)
        let fromMakers = (wantsMaker && !makers.isEmpty) || cast.isEmpty
        var order: [String] = [], byID: [String: FilmCredit] = [:]
        for r in rows {
            guard let media = r["media_type"] as? String, media == "movie" || media == "tv", let id = r["id"] as? Int, (r["adult"] as? Bool) != true else { continue }
            let isSeries = media == "tv"
            let genres = (r["genre_ids"] as? [Int]) ?? []
            if isSeries, !wantsMaker, genres.contains(10767) || genres.contains(10763) { continue }
            guard let title = str(r[isSeries ? "name" : "title"]) ?? str(r[isSeries ? "original_name" : "original_title"]) else { continue }
            let date = str(r[isSeries ? "first_air_date" : "release_date"]), poster = str(r["poster_path"])
            if date == nil && poster == nil { continue }
            let votes = r["vote_count"] as? Int
            let avg = (r["vote_average"] as? Double) ?? (r["vote_average"] as? Int).map(Double.init)
            let rating = DisplayRating.value(tmdbAverage: avg, tmdbVotes: votes, provider: nil)
            let c = FilmCredit(tmdbID: id, isSeries: isSeries, title: title, originalTitle: str(r[isSeries ? "original_name" : "original_title"]), date: date, posterPath: poster,
                               overview: str(r["overview"]), rating: rating, votes: votes, popularity: (r["popularity"] as? Double) ?? 0, role: str(r["character"]) ?? str(r["job"]),
                               order: r["order"] as? Int, isCrewMaker: fromMakers)
            if byID[c.id] == nil { order.append(c.id); byID[c.id] = c }
            else if var old = byID[c.id] {
                if old.role == nil { old.role = c.role }
                if let o = c.order, o < (old.order ?? Int.max) { old.role = c.role ?? old.role; old.order = o }
                if old.posterPath == nil { old.posterPath = c.posterPath }
                byID[c.id] = old
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// The best search result: one whose known-for titles overlap the title the person was opened from, else the most popular one whose name is exactly the one asked for.
    static func pickPerson(_ data: Data, name: String, hintTitles: [String]) -> Int? {
        guard let results = obj(data)?["results"] as? [[String: Any]] else { return nil }
        let wanted = MetadataNormalizer.normalize(name)
        let exact = results.filter { MetadataNormalizer.normalize(($0["name"] as? String) ?? "") == wanted }
        let hints = Set(hintTitles.map { MetadataNormalizer.normalize($0) }.filter { !$0.isEmpty })
        if !hints.isEmpty {
            for r in exact {
                let known = ((r["known_for"] as? [[String: Any]]) ?? []).flatMap { k in [k["title"], k["name"], k["original_title"], k["original_name"]].compactMap { $0 as? String } }
                if known.contains(where: { hints.contains(MetadataNormalizer.normalize($0)) }) { return r["id"] as? Int }
            }
        }
        let best = exact.max { (($0["popularity"] as? Double) ?? 0) < (($1["popularity"] as? Double) ?? 0) }
        return best?["id"] as? Int
    }
}

// MARK: TMDB and the saved copy

extension MetadataMatchService {
    /// Person credits are kept this long (inside the 180-day cap).
    static let personKeepDays = Retention.personKeepDays

    /// The TMDB language code for the app's wording.
    static func tmdbLanguage(for l: AppLanguage) -> String {
        switch l {
        case .en: return "en-US"
        case .hi: return "hi-IN"
        case .te: return "te-IN"
        case .system:
            let code = Locale.current.language.languageCode?.identifier ?? "en"
            return ["hi": "hi-IN", "te": "te-IN", "en": "en-US"][code] ?? code
        }
    }

    /// The saved copy, when it is newer than 30 days.
    func savedPerson(id: Int, language: String, now: Date = Date()) -> PersonFile? {
        let row: (String, Double)? = try? db.read { c in try c.queryOne("SELECT json, fetched_at FROM title_details WHERE item_id = ?", ["person:\(id):\(language)"]) { ($0.string(0), $0.double(1)) } }
        guard let row, now.timeIntervalSince1970 - row.1 < Double(Self.personKeepDays) * 86400 else { return nil }
        return try? JSONDecoder().decode(PersonFile.self, from: Data(row.0.utf8))
    }

    /// Deletes every saved person (key removed, matching switched off).
    @discardableResult func purgePeople() -> Int {
        (try? db.write { c in try c.execute("DELETE FROM title_details WHERE item_id LIKE 'person:%' OR item_id LIKE 'personq:%'"); return c.changes }) ?? 0
    }

    private func personQueryKey(_ name: String, _ hints: [String]) -> String {
        "personq:" + MetadataNormalizer.normalize(name) + "|" + hints.map { MetadataNormalizer.normalize($0) }.sorted().joined(separator: ",")
    }

    /// The person id remembered for this exact name and hint (30 days).
    func savedPersonID(name: String, hints: [String], now: Date = Date()) -> Int? {
        let row: (String, Double)? = try? db.read { c in try c.queryOne("SELECT json, fetched_at FROM title_details WHERE item_id = ?", [personQueryKey(name, hints)]) { ($0.string(0), $0.double(1)) } }
        guard let row, now.timeIntervalSince1970 - row.1 < Double(Self.personKeepDays) * 86400 else { return nil }
        return Int(row.0)
    }

    /// GET /3/search/person with the exact name; nothing else about the library is sent.
    func resolvePerson(name: String, hints: [String], now: Date = Date()) async throws -> Int? {
        let data = try await get("/3/search/person", query: [URLQueryItem(name: "query", value: name), URLQueryItem(name: "include_adult", value: "false")])
        guard let id = PersonParser.pickPerson(data, name: name, hintTitles: hints) else { return nil }
        try? db.write { try $0.execute("INSERT OR REPLACE INTO title_details(item_id, json, fetched_at) VALUES(?,?,?)", [personQueryKey(name, hints), String(id), now.timeIntervalSince1970]) }
        return id
    }

    /// GET /3/person/{id} (app language, with images; English when the biography is empty) and its combined credits, saved for 30 days.
    func refreshPerson(id: Int, language: String, now: Date = Date()) async throws -> PersonFile {
        let head = try await get("/3/person/\(id)", query: [URLQueryItem(name: "language", value: language), URLQueryItem(name: "append_to_response", value: "images")])
        guard var profile = PersonParser.profile(head) else { throw MatchError.unreadable }
        if profile.biography == nil, !language.hasPrefix("en"), let en = try? await get("/3/person/\(id)", query: [URLQueryItem(name: "language", value: "en-US")]) {
            profile.biography = PersonParser.profile(en)?.biography
        }
        let creditsData = try await get("/3/person/\(id)/combined_credits", query: [URLQueryItem(name: "language", value: "en-US")])
        let file = PersonFile(profile: profile, credits: PersonParser.credits(creditsData, department: profile.department), language: language, fetchedAt: now.timeIntervalSince1970)
        if let json = try? JSONEncoder().encode(file) {
            try? db.write { try $0.execute("INSERT OR REPLACE INTO title_details(item_id, json, fetched_at) VALUES(?,?,?)", ["person:\(id):\(language)", String(decoding: json, as: UTF8.self), now.timeIntervalSince1970]) }
        }
        return file
    }
}

// MARK: matching against the library

/// Matches TMDB credits to library titles on this device: the title's TMDB id when it was matched (exact), else the identity key (the artwork matcher's cleaned name) with the year within one.
/// Every copy (other languages, twin playlists) is folded into one match, best copy first. A title that is restricted, or has a restricted copy, is never matched.
struct FilmographyMatcher: Sendable {
    struct Match: Equatable, Sendable {
        let kind: ContentKind
        /// Every copy, the one to show first.
        let memberIDs: [String]
        /// Languages of the other copies ("Hindi").
        let languages: [String]
        var representative: String { memberIDs[0] }
        var versions: Int { memberIDs.count }
    }

    let db: DatabaseManager
    /// The English name of the audio language from Settings ("Telugu"), or nil.
    var preferredLanguage: String? = nil

    private static func marks(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }
    private static func chunks<T>(_ a: [T], _ n: Int = 300) -> [[T]] { stride(from: 0, to: a.count, by: n).map { Array(a[$0..<min($0 + n, a.count)]) } }

    private static func yearsAgree(_ credit: Int?, _ item: Int?, key: String) -> Bool {
        if let c = credit, let i = item { return abs(c - i) <= MetadataMatchService.yearTolerance(for: key) }
        return key.contains(" ")          // a missing year is accepted for a title of two words or more
    }

    func match(_ credits: [FilmCredit]) -> [String: Match] {
        var out: [String: Match] = [:]
        let health = (try? IdentityStore(db: db).sourceHealth()) ?? []
        let context = CanonicalPick.Context(preferredLanguage: preferredLanguage, sourceRank: PreferredSource.ranking(health))
        for isSeries in [false, true] {
            let list = credits.filter { $0.isSeries == isSeries }
            guard !list.isEmpty else { continue }
            let kind = isSeries ? "series" : "movie", table = isSeries ? "series" : "movies"
            var candidates: [String: Set<String>] = [:]            // credit id -> item ids

            // 1. exact: the title was matched to this TMDB id
            let byTMDB = Dictionary(list.map { ($0.tmdbID, $0) }, uniquingKeysWith: { a, _ in a })
            for chunk in Self.chunks(Array(byTMDB.keys)) {
                let rows: [(Int, String)] = (try? db.read { c in
                    try c.query("SELECT tmdb_id, item_id FROM metadata_matches WHERE kind = ? AND tmdb_id IN (\(Self.marks(chunk.count)))", [kind as (any SQLConvertible)?] + chunk.map { $0 as (any SQLConvertible)? }) { ($0.int(0), $0.string(1)) } }) ?? []
                for (tmdb, item) in rows { if let c = byTMDB[tmdb] { candidates[c.id, default: []].insert(item) } }
            }

            // 2. by cleaned name and year
            var byKey: [String: [FilmCredit]] = [:]
            for c in list { for name in [c.title, c.originalTitle].compactMap({ $0 }) { let k = IdentityKey.make(name); if !k.isEmpty, !(byKey[k]?.contains(c) ?? false) { byKey[k, default: []].append(c) } } }
            var titleHits: [(item: String, key: String, year: Int?)] = []
            for chunk in Self.chunks(Array(byKey.keys)) {
                titleHits += (try? db.read { c in
                    try c.query("SELECT item_id, identity_key, year FROM content_identity WHERE kind = ? AND identity_key IN (\(Self.marks(chunk.count)))", ([kind] + chunk).map { $0 as (any SQLConvertible)? }) { ($0.string(0), $0.string(1), $0.optInt(2)) } }) ?? []
            }
            // A title already known to be another TMDB title is never matched by its name.
            var known: [String: Int] = [:]
            for chunk in Self.chunks(Array(Set(titleHits.map(\.item)))) {
                for (i, t) in (try? db.read { c in try c.query("SELECT item_id, tmdb_id FROM metadata_matches WHERE tmdb_id IS NOT NULL AND item_id IN (\(Self.marks(chunk.count)))", chunk.map { $0 as (any SQLConvertible)? }) { ($0.string(0), $0.int(1)) } }) ?? [] { known[i] = t }
            }
            for h in titleHits {
                for c in byKey[h.key] ?? [] where Self.yearsAgree(c.year, h.year, key: h.key) {
                    if let k = known[h.item], k != c.tmdbID { continue }
                    candidates[c.id, default: []].insert(h.item)
                }
            }
            let all = Array(Set(candidates.values.flatMap { $0 }))
            guard !all.isEmpty else { continue }

            // 3. restrictions: locked, hidden, adult/Kids rules and twins of those, through the recommendation rule
            let allowed = (try? SQLiteCatalogRepository(db: db).recommendableIDs(all)) ?? []
            // 4. facts of the copies still reachable (playlist switched on)
            var facts: [String: IdentityMember] = [:]
            var langs: [String: String] = [:]
            for chunk in Self.chunks(all.filter { allowed.contains($0) }) {
                let sql = """
                    SELECT x.id, x.source_id, ci.lang, COALESCE(ci.quality_rank, 2), COALESCE(ci.is_cam, 0), COALESCE(x.added_at, 0)
                    FROM \(table) x JOIN sources s ON s.id = x.source_id AND s.enabled = 1 LEFT JOIN content_identity ci ON ci.item_id = x.id
                    WHERE x.id IN (\(Self.marks(chunk.count)))
                    """
                let rows = (try? db.read { c in try c.query(sql, chunk.map { $0 as (any SQLConvertible)? }) { r in
                    (IdentityMember(itemID: r.string(0), sourceID: r.uuid(1) ?? UUID(), language: r.optString(2), qualityRank: r.int(3), isCam: r.bool(4), year: nil, addedAt: r.double(5)), r.optString(2)) } }) ?? []
                for (m, l) in rows { facts[m.itemID] = m; if let l { langs[m.itemID] = l } }
            }
            for c in list {
                let members = (candidates[c.id] ?? []).compactMap { facts[$0] }
                guard !members.isEmpty else { continue }
                let ordered = CanonicalPick.ordered(members, context: context)
                let best = ordered[0]
                let others = Array(Set(ordered.dropFirst().compactMap { langs[$0.itemID] }.filter { $0 != langs[best.itemID] })).sorted()
                out[c.id] = Match(kind: isSeries ? .series : .movie, memberIDs: ordered.map(\.itemID), languages: others)
            }
        }
        return out
    }
}
