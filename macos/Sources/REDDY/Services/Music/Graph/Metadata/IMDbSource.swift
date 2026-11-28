import Foundation

/// A switch a source flips on itself when its host refuses automated clients; it stays off until `until`.
final class MusicBlockLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var until: Date?
    private let hold: TimeInterval
    init(hold: TimeInterval = 6 * 3600) { self.hold = hold }
    func trip(now: Date = Date()) { lock.lock(); until = now.addingTimeInterval(hold); lock.unlock() }
    func isBlocked(now: Date = Date()) -> Bool { lock.lock(); defer { lock.unlock() }; return until.map { now < $0 } ?? false }
    func reset() { lock.lock(); until = nil; lock.unlock() }
}

/// IMDb through its public, unofficial pages: the suggestion endpoint (titles with year, type, top-cast names, poster) and the title page's JSON-LD.
/// Neither is a licensed feed; the posture is gentle pacing, an honest User-Agent, and giving up when the host challenges or refuses. The licensed
/// datasets are never used. Hardened pure parsers: size caps, type checks, no scripts or HTML are ever interpreted.
enum MusicIMDbParser {
    static let source = MusicSourceID.imdb
    static let maxPage = 3_000_000

    struct Suggestion: Equatable, Sendable {
        var id: String
        var title: String
        var year: Int?
        var kind: String?
        var topCast: [String]
        var imageURL: String?
        var isTitle: Bool { id.hasPrefix("tt") }
    }

    static func suggestions(_ data: Data) -> [Suggestion] {
        guard data.count < 600_000, let rows = MusicSourceKit.json(data)?["d"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let id = r["id"] as? String, id.hasPrefix("tt") || id.hasPrefix("nm"), id.dropFirst(2).allSatisfy(\.isNumber), let l = MusicSourceKit.string(r["l"]) else { return nil }
            let cast = ((r["s"] as? String) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let img = (r["i"] as? [String: Any])?["imageUrl"] as? String
            return Suggestion(id: id, title: l, year: r["y"] as? Int, kind: r["qid"] as? String, topCast: id.hasPrefix("tt") ? cast : [], imageURL: img.flatMap { $0.hasPrefix("https://") ? $0 : nil })
        }
    }

    private static let filmKinds: Set<String> = ["movie", "tvMovie", "video", "tvSeries", "tvMiniSeries"]

    /// Film candidates from the suggestion list. Each carries its top-cast names as low-weight claims (name-only people).
    static func search(_ data: Data, retrievedAt: Date = Date()) -> MusicClaimBatch {
        var b = MusicClaimBatch(source: source, license: .termsRestricted, retrievedAt: retrievedAt, retention: 30 * 86_400, attribution: "IMDb"); b.isSearch = true
        for s in suggestions(data) where s.isTitle && (s.kind.map { filmKinds.contains($0) } ?? false) {
            let ref = MusicDraftRef.external(.film, ExternalID(.imdbTitle, s.id))
            var attrs: [String: String] = [:]
            if !s.topCast.isEmpty { attrs["topCast"] = s.topCast.joined(separator: "|") }
            if let k = s.kind { attrs["imdbType"] = k }
            b.drafts.append(MusicSourceDraft(ref, MusicEntityDraft(kind: .film, name: s.title, year: s.year, attrs: attrs, externalIDs: [ExternalID(.imdbTitle, s.id)])))
            if let i = s.imageURL { b.imageHints[ref] = i }
        }
        return b
    }

    /// True for a reply that is a challenge or refusal rather than a page: a missing JSON-LD block, a WAF marker, or a tiny body.
    static func looksBlocked(_ html: String) -> Bool {
        let l = html.lowercased()
        return html.utf8.count < 4_000 && !l.contains("application/ld+json") || l.contains("awswaf") || l.contains("captcha") && !l.contains("application/ld+json")
    }

    /// The first JSON-LD block of a title page that describes a movie or series.
    static func jsonLD(inHTML html: String) -> [String: Any]? {
        guard html.utf8.count < maxPage else { return nil }
        var rest = Substring(html)
        while let open = rest.range(of: "application/ld+json"), let gt = rest[open.upperBound...].firstIndex(of: ">"), let close = rest[gt...].range(of: "</script>") {
            let body = rest[rest.index(after: gt)..<close.lowerBound]
            if let d = body.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) {
                let cands: [[String: Any]] = (o as? [[String: Any]]) ?? ((o as? [String: Any]).map { [$0] } ?? [])
                if let hit = cands.first(where: { ["Movie", "TVSeries", "TVMovie", "TVMiniSeries", "Film"].contains($0["@type"] as? String ?? "") }) { return hit }
            }
            rest = rest[close.upperBound...]
        }
        return nil
    }

    private static func people(_ v: Any?, wanted: Set<String> = ["Person"]) -> [(id: String?, name: String)] {
        let list: [[String: Any]] = (v as? [[String: Any]]) ?? ((v as? [String: Any]).map { [$0] } ?? [])
        return list.compactMap { p in
            guard wanted.contains(p["@type"] as? String ?? "Person"), let n = MusicSourceKit.string(p["name"]), n.count <= 80 else { return nil }
            let id = (p["url"] as? String)?.split(separator: "/").first { $0.hasPrefix("nm") && $0.dropFirst(2).allSatisfy(\.isNumber) }.map(String.init)
            return (id, n)
        }
    }

    /// The title page JSON-LD as a film with cast and director, people keyed by their IMDb name id.
    static func film(html: String, imdbID: String, retrievedAt: Date = Date()) -> MusicClaimBatch? {
        guard let j = jsonLD(inHTML: html), let name = MusicSourceKit.string(j["name"]) else { return nil }
        var b = MusicClaimBatch(source: source, license: .termsRestricted, retrievedAt: retrievedAt, retention: 30 * 86_400, attribution: "IMDb")
        let film = MusicDraftRef.external(.film, ExternalID(.imdbTitle, imdbID))
        var attrs: [String: String] = [:]
        if let r = (j["aggregateRating"] as? [String: Any])?["ratingValue"] { attrs["imdbRating"] = "\(r)" }
        if let g = j["genre"] as? [String] { attrs["imdbGenres"] = g.prefix(5).joined(separator: "|") }
        b.drafts.append(MusicSourceDraft(film, MusicEntityDraft(kind: .film, name: name, year: MusicSourceKit.year(j["datePublished"] as? String), attrs: attrs, externalIDs: [ExternalID(.imdbTitle, imdbID)])))
        if let img = j["image"] as? String, img.hasPrefix("https://") { b.imageHints[film] = img }
        func add(_ list: [(id: String?, name: String)], _ pred: MusicPredicate, _ role: MusicRole, limit: Int) {
            for (i, p) in list.prefix(limit).enumerated() {
                let r: MusicDraftRef; var d = MusicEntityDraft(kind: .person, name: p.name, provisional: p.id == nil)
                if let id = p.id { r = .external(.person, ExternalID(.imdbName, id)); d.externalIDs = [ExternalID(.imdbName, id)] }
                else { let k = "imdb|" + imdbID + "|" + MusicGraphText.latin(p.name); r = .local(.person, k); d.externalIDs = [ExternalID(.canon, k)]; d.attrs["nameOnly"] = "1" }
                if !b.drafts.contains(where: { $0.ref == r }) { b.drafts.append(MusicSourceDraft(r, d)) }
                var a = EdgeAttributes(); if pred == .hasCast { a.creditOrder = i }
                var c = MusicClaimDraft(subject: film, predicate: pred, object: r, role: role, attributes: a, order: pred == .hasCast ? i : nil, creditLevel: .film, confidence: 0.85,
                                        evidence: ["imdb-json-ld"], sourceRef: imdbID)
                c.attribution = "IMDb"
                b.claims.append(c)
            }
        }
        add(people(j["actor"]), .hasCast, .actor, limit: 30)
        add(people(j["director"]), .directedBy, .director, limit: 4)
        return b
    }
}

struct IMDbSource: MusicMetadataSource {
    var transport: any MusicMetadataTransport
    var latch = MusicBlockLatch()
    var id: MusicSourceID { .imdb }
    static let suggestion = URL(string: "https://v2.sg.media-imdb.com/suggestion/")!
    static let titleBase = URL(string: "https://www.imdb.com/title/")!

    var policy: MusicSourcePolicy {
        MusicSourcePolicy(hosts: ["v2.sg.media-imdb.com", "www.imdb.com"], license: .termsRestricted, retention: 30 * 86_400, attribution: "IMDb",
                          ttl: [MusicFacet.filmCredits: 14 * 86_400, MusicFacet.filmSearch: 14 * 86_400], defaultTTL: 14 * 86_400, defaultOn: true,
                          privacyNote: "Film titles are sent to IMDb's public search and title pages (imdb.com) to read cast names. Unofficial: it switches itself off if IMDb refuses. No account, and never your listening history.")
    }

    /// The suggestion path segment: first letter, lower-cased query with spaces as underscores.
    static func suggestionPath(_ query: String) -> String? {
        let q = query.lowercased().unicodeScalars.map { ($0.isASCII && (CharacterSet.alphanumerics.contains($0))) ? Character($0) : "_" }
        let s = String(q).trimmingCharacters(in: CharacterSet(charactersIn: "_")).prefix(40)
        guard let f = s.first, f.isLetter || f.isNumber else { return nil }
        return String(f) + "/" + s + ".json"
    }

    func fetch(_ r: MusicSourceRequest, context: MusicFetchContext) async throws -> MusicClaimBatch {
        if latch.isBlocked(now: context.now()) { throw MusicSourceError.disabled }
        let now = context.now()
        do {
            switch r.facet {
            case MusicFacet.filmSearch:
                guard let t = r.param("title"), let path = Self.suggestionPath(t) else { throw MusicSourceError.badRequest("title") }
                let d = try await transport.get(URL(string: Self.suggestion.absoluteString + path)!, query: [:], headers: MusicSourceKit.headers)
                return MusicIMDbParser.search(d, retrievedAt: now)
            case MusicFacet.filmCredits:
                guard let id = r.param("imdb"), id.hasPrefix("tt"), id.dropFirst(2).allSatisfy(\.isNumber) else { throw MusicSourceError.badRequest("imdb") }
                var h = MusicSourceKit.headers; h["Accept"] = "text/html"; h["Accept-Language"] = "en"
                let d = try await transport.get(Self.titleBase.appendingPathComponent(id + "/"), query: [:], headers: h)
                let html = String(decoding: d.prefix(MusicIMDbParser.maxPage), as: UTF8.self)
                guard let b = MusicIMDbParser.film(html: html, imdbID: id, retrievedAt: now) else {
                    if MusicIMDbParser.looksBlocked(html) { latch.trip(now: now); throw MusicSourceError.blocked }
                    throw MusicError.network("unexpected reply")
                }
                return b
            default: throw MusicSourceError.unsupported(r.facet)
            }
        } catch let e as MusicError {
            if case .refused = e { latch.trip(now: now) }
            throw e
        }
    }
}

/// OMDb: only when the person has put their own key in. Names and ids of a film by IMDb id or title.
struct OMDbSource: MusicMetadataSource {
    var transport: any MusicMetadataTransport
    /// The person's key (Keychain); nil means the source is off.
    var key: @Sendable () -> String?
    var id: MusicSourceID { .omdb }
    static let base = URL(string: "https://www.omdbapi.com/")!

    var policy: MusicSourcePolicy {
        MusicSourcePolicy(hosts: ["www.omdbapi.com"], license: .termsRestricted, retention: 30 * 86_400, attribution: "OMDb", ttl: [:], defaultTTL: 14 * 86_400, defaultOn: false,
                          privacyNote: "Film titles and IMDb ids are sent to OMDb (omdbapi.com) together with the key you entered. Off until you add a key.")
    }

    static func film(_ data: Data, retrievedAt: Date = Date()) -> MusicClaimBatch? {
        guard let j = MusicSourceKit.json(data), (j["Response"] as? String) == "True", let id = j["imdbID"] as? String, let title = MusicSourceKit.string(j["Title"]) else { return nil }
        var b = MusicClaimBatch(source: .omdb, license: .termsRestricted, retrievedAt: retrievedAt, retention: 30 * 86_400, attribution: "OMDb")
        let film = MusicDraftRef.external(.film, ExternalID(.imdbTitle, id))
        b.drafts.append(MusicSourceDraft(film, MusicEntityDraft(kind: .film, name: title, year: MusicSourceKit.year(j["Year"] as? String), externalIDs: [ExternalID(.imdbTitle, id)])))
        func names(_ k: String) -> [String] { ((j[k] as? String) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "N/A" } }
        for (pred, role, key) in [(MusicPredicate.hasCast, MusicRole.actor, "Actors"), (.directedBy, .director, "Director")] {
            for (i, n) in names(key).enumerated() {
                let k = "omdb|" + id + "|" + MusicGraphText.latin(n)
                let r = MusicDraftRef.local(.person, k)
                b.drafts.append(MusicSourceDraft(r, MusicEntityDraft(kind: .person, name: n, attrs: ["nameOnly": "1"], externalIDs: [ExternalID(.canon, k)], provisional: true)))
                var c = MusicClaimDraft(subject: film, predicate: pred, object: r, role: role, order: pred == .hasCast ? i : nil, creditLevel: .film, confidence: 0.7, evidence: ["omdb"], sourceRef: id)
                c.attribution = "OMDb"
                b.claims.append(c)
            }
        }
        return b
    }

    func fetch(_ r: MusicSourceRequest, context: MusicFetchContext) async throws -> MusicClaimBatch {
        guard let k = key(), !k.isEmpty else { throw MusicSourceError.disabled }
        guard r.facet == MusicFacet.filmCredits, let imdb = r.param("imdb") else { throw MusicSourceError.unsupported(r.facet) }
        let d = try await transport.get(Self.base, query: ["i": imdb, "apikey": k], headers: MusicSourceKit.headers)
        guard let b = Self.film(d, retrievedAt: context.now()) else { throw MusicError.network("unexpected reply") }
        return b
    }
}
