import Foundation

/// Wikidata (CC0) as graph drafts: films with cast, crew and ids, people with their ids and portrait file names, search hits, and the sitelinks that
/// point the Wikipedia source at the right articles (including the Indian-language editions). Pure parsers; the source makes the calls.
enum MusicWikidataParser {
    static let source = MusicSourceID.wikidata
    /// Cast read from a film item: a large ensemble film lists far more than thirty (the film page says how many it shows).
    static let castCap = 80

    struct Person: Sendable, Hashable {
        var qid: String
        var name: String
        var isGroup: Bool
        /// Wikidata says it is a human (instance of Q5). Influences are kept only for humans and groups, never for movements or works.
        var isHuman: Bool = true
        var ids: [ExternalID]
        var photoFile: String?
        var birthYear: Int?
    }

    static let languageByQID: [String: String] = [
        "Q1568": "hi", "Q8097": "te", "Q5885": "ta", "Q36236": "ml", "Q33673": "kn", "Q9610": "bn", "Q1571": "mr", "Q58635": "pa", "Q5137": "gu",
        "Q1860": "en", "Q9176": "ko", "Q5287": "ja", "Q11059": "ur", "Q7737": "ru", "Q188": "de", "Q150": "fr", "Q1321": "es",
    ]
    private static let groupClasses: Set<String> = ["Q215380", "Q10648343", "Q2088357", "Q16010345", "Q5741069", "Q56816954", "Q1076968", "Q55655", "Q9212979", "Q112902062", "Q109288825"]

    // MARK: statement readers

    private static func statements(_ claims: [String: Any], _ p: String) -> [[String: Any]] {
        ((claims[p] as? [[String: Any]]) ?? []).filter { ($0["rank"] as? String) != "deprecated" }
    }
    private static func value(_ st: [String: Any]) -> Any? { ((st["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"] }
    private static func qid(_ st: [String: Any]) -> String? { (value(st) as? [String: Any])?["id"] as? String }
    private static func text(_ st: [String: Any]) -> String? { value(st) as? String }
    private static func qualifierText(_ st: [String: Any], _ p: String) -> String? {
        let q = ((st["qualifiers"] as? [String: Any])?[p] as? [[String: Any]])?.first
        let v = (q?["datavalue"] as? [String: Any])?["value"]
        return (v as? String) ?? ((v as? [String: Any])?["text"] as? String)
    }
    private static func year(_ st: [String: Any]) -> Int? {
        guard let t = (value(st) as? [String: Any])?["time"] as? String else { return nil }
        let digits = t.drop { $0 == "+" || $0 == "-" }.prefix(4)
        return Int(digits)
    }

    /// External ids of an item by the Wikidata properties the app maps (MusicBrainz, TMDB, IMDb).
    static func externalIDs(_ claims: [String: Any], kind: MusicEntityKind) -> [ExternalID] {
        var out: [ExternalID] = []
        func add(_ p: String, _ make: (String) -> ExternalID) { for s in statements(claims, p) { if let v = text(s), !v.isEmpty { out.append(make(v)) } } }
        switch kind {
        case .film, .series:
            add("P345") { .init(.imdbTitle, $0) }; add("P4947") { .init(.tmdbMovie, $0) }; add("P4983") { .init(.tmdbTV, $0) }
        case .person, .group:
            add("P345") { .init(.imdbName, $0) }; add("P4985") { .init(.tmdbPerson, $0) }; add("P434") { .init(.mbid, $0) }
        case .album: add("P436") { .init(.mbReleaseGroup, $0) }
        case .work: add("P435") { .init(.mbWork, $0) }
        case .recording: add("P4404") { .init(.mbid, $0) }
        default: break
        }
        return out
    }

    // MARK: people

    /// `wbgetentities&props=labels|claims&languages=en`: names and ids of the people a film item lists.
    static func people(_ data: Data) -> [String: Person] {
        guard let entities = MusicSourceKit.json(data)?["entities"] as? [String: Any] else { return [:] }
        var out: [String: Person] = [:]
        for (id, v) in entities {
            guard let e = v as? [String: Any], let labels = e["labels"] as? [String: Any], let name = (labels["en"] as? [String: Any])?["value"] as? String
                    ?? (labels.values.first as? [String: Any])?["value"] as? String else { continue }
            let claims = (e["claims"] as? [String: Any]) ?? [:]
            let group = statements(claims, "P31").compactMap(qid).contains { groupClasses.contains($0) }
            let kind: MusicEntityKind = group ? .group : .person
            let human = statements(claims, "P31").compactMap(qid).contains("Q5")
            out[id] = Person(qid: id, name: name, isGroup: group, isHuman: human, ids: [ExternalID(.wikidata, id)] + externalIDs(claims, kind: kind),
                             photoFile: statements(claims, "P18").compactMap(text).first, birthYear: statements(claims, "P569").compactMap(year).first)
        }
        return out
    }

    static func personDraft(_ p: Person) -> MusicSourceDraft {
        let kind: MusicEntityKind = p.isGroup ? .group : .person
        let ids = p.ids
        return MusicSourceDraft(.external(kind, ExternalID(.wikidata, p.qid)), MusicEntityDraft(kind: kind, name: p.name, year: p.birthYear, externalIDs: ids))
    }

    // MARK: films and other items

    /// The QIDs of the people a film item names (cast first, then crew), for the follow-up label call. Capped.
    static func peopleIDs(inEntity data: Data, qid item: String, castLimit: Int = castCap) -> [String] {
        guard let e = ((MusicSourceKit.json(data)?["entities"] as? [String: Any])?[item]) as? [String: Any], let claims = e["claims"] as? [String: Any] else { return [] }
        var seen = Set<String>(); var out: [String] = []
        func add(_ p: String, limit: Int) { for s in statements(claims, p).prefix(limit) { if let q = qid(s), seen.insert(q).inserted { out.append(q) } } }
        add("P179", limit: 1); add("P737", limit: 6); add("P161", limit: castLimit); add("P57", limit: 4); add("P86", limit: 4); add("P162", limit: 4); add("P175", limit: 8); add("P676", limit: 4)
        return out
    }

    /// The film (or song or album) item with its claims. `people` supplies names for the QIDs; a person with no label is left out.
    static func item(_ data: Data, qid item: String, kind: MusicEntityKind, people: [String: Person], retrievedAt: Date = Date()) -> MusicClaimBatch? {
        guard let e = ((MusicSourceKit.json(data)?["entities"] as? [String: Any])?[item]) as? [String: Any], let claims = e["claims"] as? [String: Any] else { return nil }
        let labels = (e["labels"] as? [String: Any]) ?? [:]
        func label(_ l: String) -> String? { (labels[l] as? [String: Any])?["value"] as? String }
        guard let name = label("en") ?? (labels.values.first as? [String: Any])?["value"] as? String else { return nil }
        var b = MusicClaimBatch(source: source, license: .cc0, retrievedAt: retrievedAt)
        let lang = statements(claims, "P364").compactMap(qid).compactMap { languageByQID[$0] }.first
        var ids = [ExternalID(.wikidata, item)] + externalIDs(claims, kind: kind)
        if kind == .film { ids += (e["labels"] != nil ? [] : []) }
        var attrs: [String: String] = [:]
        if let d = ((e["descriptions"] as? [String: Any])?["en"] as? [String: Any])?["value"] as? String { attrs["description"] = d }
        let links = ((e["sitelinks"] as? [String: Any]) ?? [:]).compactMap { k, v -> String? in
            guard let t = (v as? [String: Any])?["title"] as? String, k.hasSuffix("wiki"), !["commonswiki", "specieswiki", "metawiki"].contains(k) else { return nil }
            return k + ":" + t
        }.sorted()
        if !links.isEmpty { attrs["sitelinks"] = links.joined(separator: "|") }
        var franchise: (qid: String, name: String)?
        // "Part of the series" (P179): the franchise a film belongs to, named as Wikidata names it. Only films and series carry it.
        if kind == .film || kind == .series, let q = statements(claims, "P179").compactMap(qid).first, let series = people[q] {
            attrs["franchise"] = series.name; attrs["franchiseQID"] = q
            franchise = (q, series.name)
        }
        var aliases: [NameAlias] = []
        // The title of each other-language article is a name of the film there (the Telugu article of a Tamil film is the dub's title).
        for l in links {
            guard let i = l.firstIndex(of: ":"), l[..<i].hasSuffix("wiki"), l[..<i] != "enwiki" else { continue }
            let code = String(l[..<i].dropLast(4)), t = String(l[l.index(after: i)...])
            if t != name, !aliases.contains(where: { $0.text == t }) { aliases.append(NameAlias(t, lang: code, source: "wikipedia-title")) }
        }
        for (l, v) in labels where l != "en" { if let t = (v as? [String: Any])?["value"] as? String, t != name { aliases.append(NameAlias(t, lang: l, source: "wikidata")) } }
        let y = statements(claims, "P577").compactMap(year).min()
        let film = MusicDraftRef.external(kind, ExternalID(.wikidata, item))
        b.drafts.append(MusicSourceDraft(film, MusicEntityDraft(kind: kind, name: name, lang: lang, year: y, attrs: attrs, externalIDs: ids, aliases: aliases)))
        if let f = statements(claims, "P18").compactMap(text).first { b.imageHints[film] = "commons:" + f }
        if let fr = franchise, fr.qid != item {
            // The franchise is its own entity (a series), so every film that names it can be found from it.
            let fd = MusicSourceDraft(.external(.series, ExternalID(.wikidata, fr.qid)), MusicEntityDraft(kind: .series, name: fr.name, subkind: "franchise", externalIDs: [ExternalID(.wikidata, fr.qid)]))
            if !b.drafts.contains(where: { $0.ref == fd.ref }) { b.drafts.append(fd) }
            b.claims.append(MusicClaimDraft(subject: film, predicate: .inFranchise, object: fd.ref, creditLevel: .film, confidence: 0.85, evidence: ["wikidata-statement", "P179"], sourceRef: item))
        }

        func person(_ st: [String: Any]) -> (MusicDraftRef, MusicSourceDraft)? {
            guard let q = qid(st), let p = people[q] else { return nil }
            let d = personDraft(p)
            if let f = p.photoFile { b.imageHints[d.ref] = "commons:" + f }
            return (d.ref, d)
        }
        func emit(_ prop: String, _ pred: MusicPredicate, _ role: MusicRole, limit: Int, level: CreditLevel, cast: Bool = false) {
            for (i, st) in statements(claims, prop).prefix(limit).enumerated() {
                guard let (r, d) = person(st), pred.accepts(subject: kind, object: r.kind) else { continue }
                if !b.drafts.contains(where: { $0.ref == r }) { b.drafts.append(d) }
                var a = EdgeAttributes()
                if cast { a.characterName = qualifierText(st, "P4633"); a.creditOrder = i }
                b.claims.append(MusicClaimDraft(subject: film, predicate: pred, object: r, role: role, attributes: a, order: cast ? i : nil, creditLevel: level, confidence: 0.95,
                                                evidence: ["wikidata-statement", prop], sourceRef: item))
            }
        }
        switch kind {
        case .film, .series:
            emit("P161", .hasCast, .actor, limit: castCap, level: .film, cast: true)
            emit("P57", .directedBy, .director, limit: 4, level: .film)
            emit("P86", .composedBy, .composer, limit: 4, level: .film)
            emit("P162", .producedBy, .producer, limit: 4, level: .film)
        case .recording:
            emit("P175", .performedBy, .performer, limit: 8, level: .song)
            emit("P86", .composedBy, .composer, limit: 4, level: .song)
            emit("P676", .writtenBy, .lyricist, limit: 4, level: .song)
        case .work:
            emit("P86", .composedBy, .composer, limit: 4, level: .song)
            emit("P676", .writtenBy, .lyricist, limit: 4, level: .song)
        case .album:
            emit("P175", .performedBy, .performer, limit: 8, level: .album)
        case .person, .group:
            // "Influenced by" (P737): stated by Wikidata, kept as a link between the two, never worked out from genre or era.
            for st in statements(claims, "P737").prefix(6) {
                guard let q = qid(st), let who = people[q], who.isHuman || who.isGroup, let (r, d) = person(st), MusicPredicate.influencedBy.accepts(subject: kind, object: r.kind), r != film else { continue }
                if !b.drafts.contains(where: { $0.ref == r }) { b.drafts.append(d) }
                b.claims.append(MusicClaimDraft(subject: film, predicate: .influencedBy, object: r, creditLevel: .unknown, confidence: 0.8,
                                                evidence: ["wikidata-statement", "P737"], sourceRef: item))
            }
        default: break
        }
        return b
    }

    // MARK: search

    /// `wbsearchentities`: candidate items. A film is told from a soundtrack album, a song and a recording by its description (no instance query is made).
    static func search(_ data: Data, retrievedAt: Date = Date()) -> MusicClaimBatch {
        var b = MusicClaimBatch(source: source, license: .cc0, retrievedAt: retrievedAt); b.isSearch = true
        for r in ((MusicSourceKit.json(data)?["search"] as? [[String: Any]]) ?? []) {
            guard let id = r["id"] as? String, id.hasPrefix("Q"), let label = r["label"] as? String else { continue }
            let d = (r["description"] as? String) ?? ""
            let l = d.lowercased()
            let kind: MusicEntityKind
            if l.contains("vocal track") || l.contains("recording") { kind = .recording }
            else if l.contains("soundtrack") || l.contains("album") { kind = .album }
            else if l.contains("song") { kind = .work }
            else if l.contains("film") || l.contains("movie") { kind = (l.contains("short film") || l.contains("documentary")) ? .work : .film }
            else { continue }
            if kind == .work, !l.contains("song") { continue }
            let year = d.range(of: #"(?:18|19|20)\d\d"#, options: .regularExpression).flatMap { Int(d[$0]) }
            let sub = kind == .album ? MusicAlbumSubkind.soundtrack.rawValue : nil
            b.drafts.append(MusicSourceDraft(.external(kind, ExternalID(.wikidata, id)),
                                             MusicEntityDraft(kind: kind, name: label, subkind: sub, year: year, attrs: ["description": d], externalIDs: [ExternalID(.wikidata, id)])))
        }
        return b
    }

    /// SPARQL `?x wdt:Pnnn "value"` result: the QIDs found.
    static func sparqlItems(_ data: Data) -> [String] {
        (((MusicSourceKit.json(data)?["results"] as? [String: Any])?["bindings"] as? [[String: Any]]) ?? []).compactMap { row in
            guard let uri = (row["f"] as? [String: Any])?["value"] as? String, let q = uri.split(separator: "/").last, q.hasPrefix("Q") else { return nil }
            return String(q)
        }
    }

    /// Entity ids of Wikipedia articles an item links to: `["enwiki": "Awaara", "tewiki": "..."]`.
    static func sitelinks(of draft: MusicEntityDraft) -> [String: String] {
        var out: [String: String] = [:]
        for part in (draft.attrs["sitelinks"] ?? "").split(separator: "|") {
            if let i = part.firstIndex(of: ":") { out[String(part[..<i])] = String(part[part.index(after: i)...]) }
        }
        return out
    }
}

struct WikidataSource: MusicMetadataSource {
    var transport: any MusicMetadataTransport
    var id: MusicSourceID { .wikidata }
    static let api = URL(string: "https://www.wikidata.org/w/api.php")!
    static let entityData = URL(string: "https://www.wikidata.org/wiki/Special:EntityData/")!
    static let sparql = URL(string: "https://query.wikidata.org/sparql")!

    var policy: MusicSourcePolicy {
        MusicSourcePolicy(hosts: ["www.wikidata.org", "query.wikidata.org"], license: .cc0, retention: nil, attribution: nil,
                          ttl: [MusicFacet.filmCredits: 90 * 86_400, MusicFacet.entityLinks: 90 * 86_400], defaultTTL: 90 * 86_400, defaultOn: true,
                          privacyNote: "Film, song and person names and ids are sent to Wikidata (wikidata.org) to find cast, crew and links. No account, and never your listening history.")
    }

    private func kindParam(_ r: MusicSourceRequest) -> MusicEntityKind { r.param("kind").flatMap(MusicEntityKind.init(slug:)) ?? .film }

    func fetch(_ r: MusicSourceRequest, context: MusicFetchContext) async throws -> MusicClaimBatch {
        let now = context.now()
        switch r.facet {
        case MusicFacet.filmSearch:
            guard let q = r.param("title") else { throw MusicSourceError.badRequest("title") }
            let d = try await transport.get(Self.api, query: ["action": "wbsearchentities", "search": q, "language": r.param("lang") ?? "en", "type": "item", "limit": "10", "format": "json"],
                                            headers: MusicSourceKit.headers)
            return MusicWikidataParser.search(d, retrievedAt: now)
        case MusicFacet.filmCredits, MusicFacet.entityLinks:
            guard let q = r.param("qid"), q.hasPrefix("Q"), q.dropFirst().allSatisfy(\.isNumber) else { throw MusicSourceError.badRequest("qid") }
            let kind = kindParam(r)
            let entity = try await transport.get(Self.entityData.appendingPathComponent(q + ".json"), query: [:], headers: MusicSourceKit.headers)
            var people: [String: MusicWikidataParser.Person] = [:]
            let ids = MusicWikidataParser.peopleIDs(inEntity: entity, qid: q)
            if !ids.isEmpty, r.facet == MusicFacet.filmCredits || kind == .person || kind == .group {
                // wbgetentities takes at most 50 ids per call.
                for start in stride(from: 0, to: ids.count, by: 50) {
                    let chunk = ids[start..<min(start + 50, ids.count)]
                    let d = try await transport.get(Self.api, query: ["action": "wbgetentities", "ids": chunk.joined(separator: "|"), "props": "labels|claims", "languages": "en", "format": "json"],
                                                    headers: MusicSourceKit.headers)
                    people.merge(MusicWikidataParser.people(d)) { $1 }
                }
            }
            guard let b = MusicWikidataParser.item(entity, qid: q, kind: kind, people: people, retrievedAt: now) else { throw MusicError.network("unexpected reply") }
            return b
        case MusicFacet.reverseLookup:
            // Bounded SPARQL (one triple, limit 3), background only.
            let allowed: Set<String> = ["P345", "P4947", "P436", "P434", "P4985", "P435"]
            guard let p = r.param("property"), allowed.contains(p), let v = r.param("value"), v.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { throw MusicSourceError.badRequest("property") }
            let kind = kindParam(r)
            let d = try await transport.get(Self.sparql, query: ["query": "SELECT ?f WHERE { ?f wdt:\(p) \"\(v)\" } LIMIT 3", "format": "json"], headers: MusicSourceKit.headers.merging(["Accept": "application/sparql-results+json"]) { $1 })
            var b = MusicClaimBatch(source: .wikidata, license: .cc0, retrievedAt: now); b.isSearch = true
            for q in MusicWikidataParser.sparqlItems(d) {
                b.drafts.append(MusicSourceDraft(.external(kind, ExternalID(.wikidata, q)), MusicEntityDraft(kind: kind, name: q, externalIDs: [ExternalID(.wikidata, q)])))
            }
            return b
        default: throw MusicSourceError.unsupported(r.facet)
        }
    }
}
