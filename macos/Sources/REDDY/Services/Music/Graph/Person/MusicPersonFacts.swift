import Foundation

// About facts of a person from Wikidata, no key needed: where they were born (P19), where they studied (P69), the instruments they play (P1303), their official website
// (P856), their genres (P136), their record labels (P264) and the years they were really active (P2031 and P2032, or for a group P571 and P576). The rules that read the
// answer are pure so they are checked without the network; the loader below remembers an answer for a month, asks once however many pages want it, and never keeps a
// failure. Nothing here names where a fact came from: the page shows the fact.

struct MusicPersonFacts: Codable, Equatable, Sendable {
    var birthPlace: String?
    var education: [String] = []
    var instruments: [String] = []
    var genres: [String] = []
    var labels: [String] = []
    /// The person's own site (an https or http address).
    var website: String?
    var activeFrom: Int?
    var activeTo: Int?
    var fetchedAt: Date = Date()

    var isEmpty: Bool { birthPlace == nil && education.isEmpty && instruments.isEmpty && genres.isEmpty && labels.isEmpty && website == nil && activeFrom == nil && activeTo == nil }
}

enum MusicPersonFactsRules {
    /// The items one claim list points at, before their labels are known.
    struct Raw: Equatable, Sendable {
        var birthPlace: [String] = []
        var education: [String] = []
        var instruments: [String] = []
        var genres: [String] = []
        var labels: [String] = []
        var website: String?
        var activeFrom: Int?
        var activeTo: Int?

        /// Every item whose label is needed.
        var itemIDs: [String] {
            var seen = Set<String>(), out: [String] = []
            for q in birthPlace + education + instruments + genres + labels where seen.insert(q).inserted { out.append(q) }
            return out
        }
    }

    static let maxPerList = 6

    /// The claims of one `wbgetentities` answer asked for `claims`. Deprecated claims are left out; a preferred claim comes before a normal one.
    static func parse(_ data: Data, qid: String) -> Raw? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let entity = (root["entities"] as? [String: Any])?[qid] as? [String: Any],
              let claims = entity["claims"] as? [String: Any] else { return nil }
        func values(_ p: String) -> [Any] {
            let list = ((claims[p] as? [[String: Any]]) ?? []).filter { ($0["rank"] as? String) != "deprecated" }
            let ordered = list.filter { ($0["rank"] as? String) == "preferred" } + list.filter { ($0["rank"] as? String) != "preferred" }
            return ordered.compactMap { (($0["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"] }
        }
        func items(_ p: String) -> [String] {
            var seen = Set<String>()
            return values(p).compactMap { ($0 as? [String: Any])?["id"] as? String }.filter { $0.hasPrefix("Q") && seen.insert($0).inserted }.prefix(maxPerList).map { $0 }
        }
        /// The earliest year for a start (formed, born), the latest for an end (a person or band with a reunion was active until the last period, not the first).
        func year(_ p: String, latest: Bool = false) -> Int? {
            let years = values(p).compactMap { ($0 as? [String: Any])?["time"] as? String }.compactMap(MusicPersonAwardsRules.yearOf)
            return latest ? years.max() : years.min()
        }
        var raw = Raw()
        raw.birthPlace = Array(items("P19").prefix(1))
        raw.education = items("P69"); raw.instruments = items("P1303"); raw.genres = items("P136"); raw.labels = items("P264")
        raw.website = values("P856").compactMap { $0 as? String }.compactMap(cleanWebsite).first
        // A person's years of work, else a group's years from forming to disbanding.
        raw.activeFrom = year("P2031") ?? year("P571")
        raw.activeTo = year("P2032", latest: true) ?? year("P576", latest: true)
        return raw
    }

    /// Only a plain web address: a scheme of http or https and a host.
    static func cleanWebsite(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = u.host, host.contains(".") else { return nil }
        return t
    }

    /// The facts with their labels. An item whose label is unknown is dropped (a bare item number says nothing), and a span that runs backwards is not shown.
    static func facts(_ raw: Raw, labels: [String: String], now: Date = Date()) -> MusicPersonFacts {
        func named(_ ids: [String]) -> [String] {
            var seen = Set<String>()
            return ids.compactMap { labels[$0] }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        }
        var f = MusicPersonFacts(fetchedAt: now)
        f.birthPlace = named(raw.birthPlace).first
        f.education = named(raw.education); f.instruments = named(raw.instruments); f.genres = named(raw.genres); f.labels = named(raw.labels)
        f.website = raw.website
        if let a = raw.activeFrom, (1000...2999).contains(a) {
            if let b = raw.activeTo, b < a { f.activeFrom = a } else { f.activeFrom = a; f.activeTo = raw.activeTo }
        }
        return f
    }

    /// "Active 1975–2005", "Active since 1975" (no end stated), or nil when no start year is known.
    static func activeYears(_ f: MusicPersonFacts?) -> (from: Int, to: Int?)? {
        guard let a = f?.activeFrom else { return nil }
        return (a, f?.activeTo)
    }

    /// The host of an address for the About line ("example.com").
    static func displayHost(_ website: String) -> String {
        guard let h = URL(string: website)?.host else { return website }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

actor MusicPersonFactsLoader {
    static let shared = MusicPersonFactsLoader()
    private var memory: [String: (facts: MusicPersonFacts, at: Date)] = [:]
    private var inFlight: [String: Task<MusicPersonFacts?, Never>] = [:]
    private var wipes = 0
    /// A whole answer is kept a month; one that says "nothing known" a day, so a person with no such claims is not asked again at every visit.
    static let hit: TimeInterval = 30 * 86_400, empty: TimeInterval = 86_400

    /// A folder of the caller's own (tests); nil is the app's own folder.
    private let customDirectory: URL?
    init(directory: URL? = nil) { customDirectory = directory }

    private var directory: URL {
        if let d = customDirectory { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d }
        return MusicStorage.ensureUnbacked(MusicStorage.subfolder("PersonFacts"))
    }
    private func file(_ key: String) -> URL { directory.appendingPathComponent(key.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined() + ".json") }

    static func keep(_ f: MusicPersonFacts) -> TimeInterval { f.isEmpty ? empty : hit }

    /// The privacy wipe: the saved answers are named by Wikidata item, so together they list every artist the person opened.
    func wipe() {
        wipes += 1   // an answer still on its way when the wipe happens must not write itself back afterwards
        for (_, t) in inFlight { t.cancel() }
        inFlight = [:]; memory = [:]
        try? FileManager.default.removeItem(at: directory)
    }

    /// The facts of this Wikidata item, or nil when they could not be read (a failure is never remembered, so the next visit asks again).
    func facts(qid: String, readingLanguages: [String], transport: any MusicMetadataTransport) async -> MusicPersonFacts? {
        guard qid.hasPrefix("Q"), qid.dropFirst().allSatisfy(\.isNumber) else { return nil }
        let langs = (readingLanguages.prefix(2) + ["en"]).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let key = qid + "|" + langs.joined(separator: ",")
        if let m = memory[key], Date().timeIntervalSince(m.at) < Self.keep(m.facts) { return m.facts }
        if let data = try? Data(contentsOf: file(key)), let saved = try? Self.decoder.decode(MusicPersonFacts.self, from: data), Date().timeIntervalSince(saved.fetchedAt) < Self.keep(saved) {
            memory[key] = (saved, saved.fetchedAt); return saved
        }
        if let running = inFlight[key] { return await running.value }
        let task = Task<MusicPersonFacts?, Never> { await Self.fetch(qid: qid, languages: langs, transport: transport) }
        inFlight[key] = task
        let epoch = wipes
        let result = await task.value
        if epoch == wipes { inFlight[key] = nil }
        guard let result, epoch == wipes else { return epoch == wipes ? nil : result }   // after a wipe the answer is returned to its caller but not kept
        memory[key] = (result, Date())
        if !result.isEmpty, let data = try? Self.encoder.encode(result) { try? data.write(to: file(key), options: .atomic) }
        return result
    }

    private static func fetch(qid: String, languages: [String], transport: any MusicMetadataTransport) async -> MusicPersonFacts? {
        let api = URL(string: "https://www.wikidata.org/w/api.php")!
        guard let data = try? await transport.get(api, query: ["action": "wbgetentities", "ids": qid, "props": "claims", "format": "json"], headers: MusicSourceKit.headers),
              let raw = MusicPersonFactsRules.parse(data, qid: qid) else { return nil }
        if Task.isCancelled { return nil }
        let ids = raw.itemIDs
        var labels: [String: String] = [:]
        if !ids.isEmpty {
            // One call for every label; when it fails the whole answer is a failure, not a person with no facts.
            guard let labelData = try? await transport.get(api, query: ["action": "wbgetentities", "ids": ids.prefix(50).joined(separator: "|"), "props": "labels", "languages": languages.joined(separator: "|"), "format": "json"], headers: MusicSourceKit.headers) else { return nil }
            labels = MusicPersonAwardsRules.parseLabels(labelData, languages: languages)
        }
        return MusicPersonFactsRules.facts(raw, labels: labels)
    }

    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    private static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
