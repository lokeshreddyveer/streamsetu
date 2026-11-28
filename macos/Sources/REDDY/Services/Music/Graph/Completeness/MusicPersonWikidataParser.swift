import Foundation

/// Wikidata (CC0) for the person completeness pass: who the person is (search, ids), and every film, album and song the person took part in
/// (composer P86, cast member P161, director P57, lyricist P676, performer P175; a film's soundtrack release P406). Pure parsers over replies of
/// `wbsearchentities`, `Special:EntityData`, the Query Service (SPARQL JSON) and `list=search&srsearch=haswbstatement:...` plus `wbgetentities`.
enum MusicPersonWikidataParser {
    static let source = MusicSourceID.wikidata

    // Verified class ids (wikidata.org): film Q11424, album Q482994, studio album Q208569. The rest are hints only; structure (IMDb title id, release-group id) decides first.
    private static let filmClasses: Set<String> = ["Q11424", "Q24862", "Q202866", "Q93204", "Q506240", "Q5398426"]
    private static let albumClasses: Set<String> = ["Q482994", "Q208569", "Q134556", "Q169930", "Q209939"]
    private static let songClasses: Set<String> = ["Q7366"]

    /// Property to relation for the statements "item has property = person".
    static let relationProperty: [(prop: String, rel: MusicPersonRelation)] = [("P86", .composer), ("P161", .cast), ("P57", .director), ("P676", .lyricist), ("P175", .performer)]

    // MARK: who

    struct Candidate: Sendable, Equatable { var qid: String; var label: String; var description: String }

    static func searchCandidates(_ data: Data) -> [Candidate] {
        ((MusicSourceKit.json(data)?["search"] as? [[String: Any]]) ?? []).compactMap { r in
            guard let id = r["id"] as? String, id.hasPrefix("Q"), let l = r["label"] as? String else { return nil }
            return Candidate(qid: id, label: l, description: (r["description"] as? String) ?? "")
        }
    }

    private static let musicWords = ["composer", "singer", "playback", "music director", "musician", "lyricist", "actor", "actress", "film director", "record producer", "songwriter", "film score", "vocalist", "producer"]

    /// The one candidate that is this person, or nil. Needs a near-exact name and an occupation in the description, and refuses a tie.
    static func pick(_ cands: [Candidate], name: String, knownAliases: [String] = []) -> Candidate? {
        let names = [name] + knownAliases
        let scored = cands.compactMap { c -> (Candidate, Float)? in
            let s = names.map { MusicTransliterationKey.similarity(c.label, $0) }.max() ?? 0
            let d = c.description.lowercased()
            guard s >= 0.9, musicWords.contains(where: d.contains) else { return nil }
            return (c, s)
        }.sorted { $0.1 > $1.1 }
        guard let top = scored.first else { return nil }
        if scored.count > 1, scored[1].1 >= top.1 - 0.05 { return nil }   // two plausible people: never guess
        return top.0
    }

    struct Facts: Sendable, Equatable {
        var qid: String
        var name: String
        var isHuman: Bool
        var ids: [ExternalID]
        var birthYear: Int?
        var aliases: [String]
    }

    /// `Special:EntityData/Q.json`.
    static func facts(_ data: Data, qid: String) -> Facts? {
        guard let e = ((MusicSourceKit.json(data)?["entities"] as? [String: Any])?[qid]) as? [String: Any], let claims = e["claims"] as? [String: Any] else { return nil }
        let labels = (e["labels"] as? [String: Any]) ?? [:]
        guard let name = ((labels["en"] as? [String: Any])?["value"] as? String) ?? ((labels.values.first as? [String: Any])?["value"] as? String) else { return nil }
        func values(_ p: String) -> [[String: Any]] { ((claims[p] as? [[String: Any]]) ?? []).filter { ($0["rank"] as? String) != "deprecated" } }
        func dv(_ s: [String: Any]) -> Any? { ((s["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"] }
        func q(_ s: [String: Any]) -> String? { (dv(s) as? [String: Any])?["id"] as? String }
        var ids = [ExternalID(.wikidata, qid)]
        for s in values("P434") { if let v = dv(s) as? String, !v.isEmpty { ids.append(ExternalID(.mbid, v)) } }
        for s in values("P345") { if let v = dv(s) as? String, v.hasPrefix("nm") { ids.append(ExternalID(.imdbName, v)) } }
        for s in values("P4985") { if let v = dv(s) as? String, !v.isEmpty { ids.append(ExternalID(.tmdbPerson, v)) } }
        let human = values("P31").compactMap(q).contains("Q5")
        let birth = values("P569").compactMap { s -> Int? in
            guard let t = (dv(s) as? [String: Any])?["time"] as? String else { return nil }
            return Int(t.drop { $0 == "+" || $0 == "-" }.prefix(4))
        }.first
        var aliases: [String] = []
        for (_, v) in labels { if let t = (v as? [String: Any])?["value"] as? String, t != name { aliases.append(t) } }
        return Facts(qid: qid, name: name, isHuman: human, ids: ids, birthYear: birth, aliases: aliases)
    }

    // MARK: works

    static func isQID(_ s: String) -> Bool { s.hasPrefix("Q") && s.count > 1 && s.count < 14 && s.dropFirst().allSatisfy(\.isNumber) }

    /// One bounded query for everything the person is linked to. The QID is checked before it goes into the text.
    static func worksQuery(qid: String, limit: Int = 3000) -> String? {
        guard isQID(qid) else { return nil }
        let parts = relationProperty.map { "{ ?item wdt:\($0.prop) wd:\(qid) . BIND(\"\($0.rel.rawValue)\" AS ?rel) }" }.joined(separator: " UNION ")
        return "SELECT ?item ?itemLabel ?rel ?date ?inst ?imdb ?rg ?st ?stLabel WHERE { \(parts) OPTIONAL { ?item wdt:P577 ?date } OPTIONAL { ?item wdt:P31 ?inst } "
            + "OPTIONAL { ?item wdt:P345 ?imdb } OPTIONAL { ?item wdt:P436 ?rg } OPTIONAL { ?item wdt:P406 ?st } "
            + "SERVICE wikibase:label { bd:serviceParam wikibase:language \"en,ta,te,hi,ml,kn,bn,mr\" . } } LIMIT \(limit)"
    }

    private static func year(_ s: String?) -> Int? {
        guard let s, !s.isEmpty else { return nil }
        let t = s.drop { $0 == "+" || $0 == "-" }.prefix(4)
        guard let y = Int(t), (1800...2100).contains(y) else { return nil }
        return y
    }

    private static func tail(_ uri: String?) -> String? { uri.flatMap { $0.split(separator: "/").last.map(String.init) } }

    /// Shared row shape: one source item with everything its rows said.
    private struct Acc {
        var qid: String; var label: String?; var rels: Set<MusicPersonRelation> = []; var years: [Int] = []; var inst: Set<String> = []
        var imdb: String?; var rg: String?; var st: [String: String] = [:]
    }

    private static func works(from accs: [String: Acc], retrievedAt: Date) -> [MusicPersonWork] {
        var out: [MusicPersonWork] = []
        for (qid, a) in accs {
            guard let label = a.label, !label.hasPrefix("Q") || label.count > 12 else { continue }   // an unlabelled item shows its own id: skip
            let lower = label.lowercased()
            let isFilm = a.imdb?.hasPrefix("tt") == true || !a.inst.isDisjoint(with: filmClasses) || a.rels.contains(.cast) || a.rels.contains(.director)
            let isAlbum = a.rg != nil || !a.inst.isDisjoint(with: albumClasses) || lower.contains("soundtrack") || lower.contains(" album")
            let isSong = !a.inst.isDisjoint(with: songClasses)
            let kind: MusicPersonWorkKind
            if isFilm && !(isAlbum && a.imdb == nil) { kind = .film } else if isAlbum { kind = .album } else if isSong { kind = .work } else { continue }
            var ids = [ExternalID(.wikidata, qid)]
            if let i = a.imdb, i.hasPrefix("tt") { ids.append(ExternalID(.imdbTitle, i)) }
            if let r = a.rg { ids.append(ExternalID(.mbReleaseGroup, r)) }
            var w = MusicPersonWork(kind: kind, title: label, year: a.years.min(), relations: a.rels, ids: ids, source: source, sourceRef: qid)
            if kind == .album {
                w.subkind = (lower.contains("soundtrack") || MusicPersonWorkKey.parse(label).soundtrackWording) ? MusicAlbumSubkind.soundtrack.rawValue : MusicAlbumSubkind.album.rawValue
                if a.inst.contains("Q169930") { w.subkind = MusicAlbumSubkind.ep.rawValue } else if a.inst.contains("Q134556") { w.subkind = MusicAlbumSubkind.single.rawValue }
            }
            if kind == .film, let st = a.st.sorted(by: { $0.key < $1.key }).first { w.soundtrackQID = st.key; w.soundtrackTitle = st.value.isEmpty ? nil : st.value }
            out.append(w)
        }
        return out.sorted { ($0.sourceRef ?? "") < ($1.sourceRef ?? "") }
    }

    /// SPARQL JSON of `worksQuery`.
    static func works(sparql data: Data, retrievedAt: Date = Date()) -> [MusicPersonWork] {
        var accs: [String: Acc] = [:]
        for row in (((MusicSourceKit.json(data)?["results"] as? [String: Any])?["bindings"] as? [[String: Any]]) ?? []) {
            func v(_ k: String) -> String? { (row[k] as? [String: Any])?["value"] as? String }
            guard let q = tail(v("item")), isQID(q) else { continue }
            var a = accs[q] ?? Acc(qid: q)
            a.label = a.label ?? v("itemLabel")
            if let r = v("rel").flatMap(MusicPersonRelation.init(rawValue:)) { a.rels.insert(r) }
            if let y = year(v("date")) { a.years.append(y) }
            if let i = tail(v("inst")), isQID(i) { a.inst.insert(i) }
            if let i = v("imdb") { a.imdb = a.imdb ?? i }
            if let r = v("rg") { a.rg = a.rg ?? r }
            if let s = tail(v("st")), isQID(s) { let l = v("stLabel") ?? ""; a.st[s] = l.hasPrefix("Q") && l.count < 14 ? "" : l }
            accs[q] = a
        }
        return works(from: accs, retrievedAt: retrievedAt)
    }

    /// The fallback when the Query Service is down or times out: `list=search&srsearch=haswbstatement:P86=Q...` pages (item ids) ...
    static func searchHits(_ data: Data) -> (qids: [String], next: Int?) {
        let j = MusicSourceKit.json(data)
        let hits = (((j?["query"] as? [String: Any])?["search"]) as? [[String: Any]]) ?? []
        let next = ((j?["continue"] as? [String: Any])?["sroffset"] as? Int)
        return (hits.compactMap { ($0["title"] as? String).flatMap { isQID($0) ? $0 : nil } }, next)
    }

    /// ... and `wbgetentities&props=labels|claims` for those ids: the same rows, read from the items' own statements.
    static func works(entities data: Data, relation: MusicPersonRelation, retrievedAt: Date = Date()) -> [MusicPersonWork] {
        guard let ents = MusicSourceKit.json(data)?["entities"] as? [String: Any] else { return [] }
        var accs: [String: Acc] = [:]
        for (qid, v) in ents {
            guard isQID(qid), let e = v as? [String: Any], let claims = e["claims"] as? [String: Any] else { continue }
            let labels = (e["labels"] as? [String: Any]) ?? [:]
            var a = Acc(qid: qid)
            a.label = ((labels["en"] as? [String: Any])?["value"] as? String) ?? ((labels.values.first as? [String: Any])?["value"] as? String)
            a.rels = [relation]
            func st(_ p: String) -> [[String: Any]] { ((claims[p] as? [[String: Any]]) ?? []).filter { ($0["rank"] as? String) != "deprecated" } }
            func dv(_ s: [String: Any]) -> Any? { ((s["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"] }
            for s in st("P577") { a.years.append(contentsOf: [year((dv(s) as? [String: Any])?["time"] as? String)].compactMap { $0 }) }
            for s in st("P31") { if let i = (dv(s) as? [String: Any])?["id"] as? String { a.inst.insert(i) } }
            a.imdb = st("P345").compactMap { dv($0) as? String }.first
            a.rg = st("P436").compactMap { dv($0) as? String }.first
            for s in st("P406") { if let i = (dv(s) as? [String: Any])?["id"] as? String { a.st[i] = "" } }
            accs[qid] = a
        }
        return works(from: accs, retrievedAt: retrievedAt)
    }

    /// The soundtrack releases (P406) a film item states.
    static func soundtrackIDs(entity data: Data, qid: String) -> [String] {
        guard let e = ((MusicSourceKit.json(data)?["entities"] as? [String: Any])?[qid]) as? [String: Any], let claims = e["claims"] as? [String: Any] else { return [] }
        return (((claims["P406"] as? [[String: Any]]) ?? []).filter { ($0["rank"] as? String) != "deprecated" }).compactMap {
            (((($0["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"]) as? [String: Any])?["id"] as? String
        }.filter(isQID)
    }

    /// Albums from a `wbgetentities` reply of soundtrack release items: they are albums whatever their class says, because the film named them.
    static func soundtrackAlbums(entities data: Data, film: String) -> [MusicPersonWork] {
        guard let ents = MusicSourceKit.json(data)?["entities"] as? [String: Any] else { return [] }
        var out: [MusicPersonWork] = []
        for (qid, v) in ents.sorted(by: { $0.key < $1.key }) {
            guard isQID(qid), let e = v as? [String: Any] else { continue }
            let labels = (e["labels"] as? [String: Any]) ?? [:]
            guard let name = ((labels["en"] as? [String: Any])?["value"] as? String) ?? ((labels.values.first as? [String: Any])?["value"] as? String) else { continue }
            let claims = (e["claims"] as? [String: Any]) ?? [:]
            func st(_ p: String) -> [[String: Any]] { ((claims[p] as? [[String: Any]]) ?? []).filter { ($0["rank"] as? String) != "deprecated" } }
            func dv(_ s: [String: Any]) -> Any? { ((s["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"] }
            var ids = [ExternalID(.wikidata, qid)]
            if let rg = st("P436").compactMap({ dv($0) as? String }).first { ids.append(ExternalID(.mbReleaseGroup, rg)) }
            let y = st("P577").compactMap { year((dv($0) as? [String: Any])?["time"] as? String) }.min()
            var w = MusicPersonWork(kind: .album, title: name, year: y, subkind: MusicAlbumSubkind.soundtrack.rawValue, ids: ids, source: source, sourceRef: qid)
            w.statesFilm = true; w.filmTitle = film
            out.append(w)
        }
        return out
    }

    /// Titles of soundtrack ids from a labels-only `wbgetentities` reply.
    static func labels(_ data: Data) -> [String: String] {
        var out: [String: String] = [:]
        for (q, v) in ((MusicSourceKit.json(data)?["entities"] as? [String: Any]) ?? [:]) {
            if let l = (((v as? [String: Any])?["labels"] as? [String: Any])?["en"] as? [String: Any])?["value"] as? String { out[q] = l }
        }
        return out
    }
}
