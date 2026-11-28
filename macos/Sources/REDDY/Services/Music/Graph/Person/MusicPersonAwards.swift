import Foundation

// Awards of a person from Wikidata (property P166, "award received"), with the award's name from its label. No key is needed; the page shows them only when the
// person's Wikidata item lists some. Parsing is pure so it is checked without the network.

struct MusicPersonAward: Hashable, Sendable, Identifiable {
    var qid: String
    var label: String
    var year: Int?
    var id: String { qid + "|" + String(year ?? 0) }
}

enum MusicPersonAwardsRules {
    struct Claim: Equatable, Sendable { var qid: String; var year: Int? }

    /// P166 claims of one `wbgetentities` answer: the award item and, when a point in time (P585) is stated, its year. Deprecated claims are left out.
    static func parseClaims(_ data: Data, qid: String) -> [Claim] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let entity = (root["entities"] as? [String: Any])?[qid] as? [String: Any],
              let claims = (entity["claims"] as? [String: Any])?["P166"] as? [[String: Any]] else { return [] }
        var out: [Claim] = []
        var seen = Set<String>()
        for c in claims where (c["rank"] as? String) != "deprecated" {
            guard let id = (((c["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"] as? [String: Any])?["id"] as? String, id.hasPrefix("Q") else { continue }
            let time = ((((c["qualifiers"] as? [String: Any])?["P585"] as? [[String: Any]])?.first?["datavalue"] as? [String: Any])?["value"] as? [String: Any])?["time"] as? String
            let year = time.flatMap(yearOf)
            if seen.insert(id + "|" + String(year ?? 0)).inserted { out.append(Claim(qid: id, year: year)) }
        }
        return out
    }

    /// "+1994-00-00T00:00:00Z" gives 1994.
    static func yearOf(_ time: String) -> Int? {
        var t = Substring(time)
        if t.hasPrefix("+") { t = t.dropFirst() }
        guard let y = Int(t.prefix { $0.isNumber }), (1000...2999).contains(y) else { return nil }
        return y
    }

    /// Labels of one `wbgetentities` answer asked for `labels`, the first of `languages` that has one.
    static func parseLabels(_ data: Data, languages: [String]) -> [String: String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let entities = root["entities"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (id, v) in entities {
            let labels = (v as? [String: Any])?["labels"] as? [String: Any] ?? [:]
            for l in languages { if let text = (labels[l] as? [String: Any])?["value"] as? String, !text.isEmpty { out[id] = text; break } }
        }
        return out
    }

    /// Awards newest first, those without a year last; a claim whose label is unknown is dropped (a bare item number says nothing).
    static func awards(claims: [Claim], labels: [String: String]) -> [MusicPersonAward] {
        claims.compactMap { c in labels[c.qid].map { MusicPersonAward(qid: c.qid, label: $0, year: c.year) } }
            .sorted { ($0.year ?? 0) != ($1.year ?? 0) ? ($0.year ?? 0) > ($1.year ?? 0) : $0.label < $1.label }
    }
}

actor MusicPersonAwardsLoader {
    static let shared = MusicPersonAwardsLoader()
    private var memory: [String: [MusicPersonAward]] = [:]
    private var inFlight: [String: Task<[MusicPersonAward], Never>] = [:]

    /// The privacy wipe: what was read for the artists the person opened is forgotten.
    func wipe() { for (_, t) in inFlight { t.cancel() }; inFlight = [:]; memory = [:] }

    func awards(qid: String, readingLanguages: [String], transport: any MusicMetadataTransport) async -> [MusicPersonAward] {
        guard qid.hasPrefix("Q"), qid.dropFirst().allSatisfy(\.isNumber) else { return [] }
        let langs = (readingLanguages.prefix(2) + ["en"]).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let key = qid + "|" + langs.joined(separator: ",")
        if let m = memory[key] { return m }
        // About and Timeline ask at the same moment: one request answers both.
        if let running = inFlight[key] { return await running.value }
        let task = Task { await self.fetch(qid: qid, langs: langs, key: key, transport: transport) }
        inFlight[key] = task
        let out = await task.value
        inFlight[key] = nil
        return out
    }

    private func fetch(qid: String, langs: [String], key: String, transport: any MusicMetadataTransport) async -> [MusicPersonAward] {
        let api = URL(string: "https://www.wikidata.org/w/api.php")!
        guard let data = try? await transport.get(api, query: ["action": "wbgetentities", "ids": qid, "props": "claims", "format": "json"], headers: MusicSourceKit.headers) else { return [] }
        // Newest first before the cut, so the 50 kept are the 50 most recent (claims with no year last), not the first 50 in Wikidata's order.
        let claims = Array(MusicPersonAwardsRules.parseClaims(data, qid: qid).sorted { ($0.year ?? 0) > ($1.year ?? 0) }.prefix(50))
        guard !claims.isEmpty else { memory[key] = []; return [] }
        let ids = Array(Set(claims.map(\.qid))).sorted().joined(separator: "|")
        guard let labelData = try? await transport.get(api, query: ["action": "wbgetentities", "ids": ids, "props": "labels", "languages": langs.joined(separator: "|"), "format": "json"], headers: MusicSourceKit.headers) else { return [] }
        let result = MusicPersonAwardsRules.awards(claims: claims, labels: MusicPersonAwardsRules.parseLabels(labelData, languages: langs))
        memory[key] = result
        return result
    }
}
