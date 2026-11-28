import Foundation
@testable import REDDY

/// Replies written inline (small, hand-trimmed shapes of the public APIs' JSON). Nothing here touches the network.
enum CompletenessFixtures {
    static func data(_ s: String) -> Data { Data(s.utf8) }

    /// One SPARQL binding row as the Query Service returns it.
    static func row(_ qid: String, _ label: String, rel: String, date: String? = nil, inst: String? = nil, imdb: String? = nil, rg: String? = nil, st: String? = nil, stLabel: String? = nil) -> String {
        func lit(_ v: String) -> String { "{\"type\":\"literal\",\"value\":\"\(v)\"}" }
        func uri(_ q: String) -> String { "{\"type\":\"uri\",\"value\":\"http://www.wikidata.org/entity/\(q)\"}" }
        var f = ["\"item\":" + uri(qid), "\"itemLabel\":" + lit(label), "\"rel\":" + lit(rel)]
        if let date { f.append("\"date\":" + lit(date)) }
        if let inst { f.append("\"inst\":" + uri(inst)) }
        if let imdb { f.append("\"imdb\":" + lit(imdb)) }
        if let rg { f.append("\"rg\":" + lit(rg)) }
        if let st { f.append("\"st\":" + uri(st)) }
        if let stLabel { f.append("\"stLabel\":" + lit(stLabel)) }
        return "{" + f.joined(separator: ",") + "}"
    }
    static func sparql(_ rows: [String]) -> Data { data("{\"head\":{\"vars\":[]},\"results\":{\"bindings\":[" + rows.joined(separator: ",") + "]}}") }

    static let vaathiRows = [
        row("Q111", "Vaathi", rel: "composer", date: "2023-02-17T00:00:00Z", inst: "Q11424", imdb: "tt15327088", st: "Q211", stLabel: "Vaathi (Original Motion Picture Soundtrack)"),
        row("Q111", "Vaathi", rel: "composer", date: "2023-02-16T00:00:00Z", inst: "Q11424", imdb: "tt15327088", st: "Q211", stLabel: "Vaathi (Original Motion Picture Soundtrack)"),
        row("Q112", "Soorarai Pottru", rel: "composer", date: "2020-11-12T00:00:00Z", inst: "Q11424", imdb: "tt10189514"),
        row("Q113", "Asuran", rel: "composer", date: "2019-10-04T00:00:00Z", imdb: "tt9314358"),
        row("Q114", "Aadukalam", rel: "composer", date: "2011-01-14T00:00:00Z", imdb: "tt1704594"),
        row("Q115", "Aadukalam", rel: "cast", date: "2011-01-14T00:00:00Z", imdb: "tt1704594"),
        row("Q211", "Vaathi (Original Motion Picture Soundtrack)", rel: "composer", date: "2023-02-02T00:00:00Z", inst: "Q482994", rg: "11111111-1111-1111-1111-111111111111"),
        row("Q300", "Q300", rel: "composer"),   // no label: its own id shows, skipped
    ]

    static let searchGV = data("""
    {"search":[{"id":"Q444","label":"G. V. Prakash Kumar","description":"Indian music composer, singer and actor"},
               {"id":"Q445","label":"G. V. Prakash","description":"village in India"}]}
    """)
    static func factsGV(qid: String = "Q444", mb: String? = "22222222-2222-2222-2222-222222222222", imdb: String? = "nm2111287") -> Data {
        var claims = "\"P31\":[{\"mainsnak\":{\"datavalue\":{\"value\":{\"id\":\"Q5\"}}}}]"
        if let mb { claims += ",\"P434\":[{\"mainsnak\":{\"datavalue\":{\"value\":\"\(mb)\"}}}]" }
        if let imdb { claims += ",\"P345\":[{\"mainsnak\":{\"datavalue\":{\"value\":\"\(imdb)\"}}}]" }
        claims += ",\"P569\":[{\"mainsnak\":{\"datavalue\":{\"value\":{\"time\":\"+1987-06-13T00:00:00Z\"}}}}]"
        return data("{\"entities\":{\"\(qid)\":{\"labels\":{\"en\":{\"value\":\"G. V. Prakash Kumar\"}},\"claims\":{\(claims)}}}}")
    }

    static func rgPage(_ n: Int, offset: Int = 0, total: Int) -> Data {
        let rows = (0..<n).map { i in "{\"id\":\"rg-\(offset + i)\",\"title\":\"Album \(offset + i)\",\"first-release-date\":\"\(2000 + (offset + i) % 24)-05-01\",\"primary-type\":\"Album\",\"secondary-types\":[],\"artist-credit\":[{\"name\":\"G. V. Prakash Kumar\"}]}" }
        return data("{\"release-group-count\":\(total),\"release-group-offset\":\(offset),\"release-groups\":[" + rows.joined(separator: ",") + "]}")
    }
}

/// Answers by the first route whose text the request address contains. Counts calls; can hold every reply until released (for cancellation tests).
final class CompletenessTransport: MusicMetadataTransport, @unchecked Sendable {
    struct Route { var match: String; var reply: Data?; var error: MusicError? }
    private let lock = NSLock()
    private var routes: [Route] = []
    private(set) var calls: [String] = []
    var hold = false

    init(_ routes: [Route] = []) { self.routes = routes }
    func add(_ match: String, _ reply: Data) { lock.withLock { routes.append(Route(match: match, reply: reply, error: nil)) } }
    func fail(_ match: String, _ e: MusicError = .network("down")) { lock.withLock { routes.append(Route(match: match, reply: nil, error: e)) } }
    var count: Int { lock.withLock { calls.count } }
    func count(containing s: String) -> Int { lock.withLock { calls.filter { $0.contains(s) }.count } }

    func get(_ url: URL, query: [String: String], headers: [String: String]) async throws -> Data {
        let key = url.absoluteString + "?" + query.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "&")
        let r: Route? = lock.withLock { calls.append(key); return routes.first { key.contains($0.match) } }
        if hold { while hold { try await Task.sleep(nanoseconds: 5_000_000) } }
        try Task.checkCancellation()
        guard let r else { throw MusicError.notFound }
        if let e = r.error { throw e }
        return r.reply ?? Data()
    }
}

/// Gate that refuses chosen sources.
struct CompletenessGate: MusicEnrichmentGating {
    var off: Set<MusicSourceID> = []
    func decision(for source: MusicSourceID) -> MusicEnrichmentDecision { off.contains(source) ? .skipped(.switchOff) : .allowed }
}

/// A catalogue that answers from values.
struct CompletenessCatalogue: MusicPersonCatalogueFetching {
    var byArtist: [MusicPersonWork] = []
    var byTitle: [MusicPersonWork] = []
    func albums(forArtist name: String, providerIDs: [String: String], maxPages: Int) async -> [MusicPersonWork] { byArtist }
    func albums(titled title: String, maxPerProvider: Int) async -> [MusicPersonWork] { byTitle }
}

func providerAlbum(_ id: String, _ title: String, year: Int?, provider: String = "jiosaavn", artists: [String] = ["G. V. Prakash Kumar"], type: String? = nil) -> MusicPersonWork {
    var w = MusicPersonWork(kind: .album, title: title, year: year, subkind: MusicGraphAdapters.albumSubkind(type: type, title: title) ?? "album", relations: [.performer],
                            ids: [ExternalID(.provider, provider + ":" + id)], source: MusicSourceID(provider), sourceRef: id)
    w.artists = artists; w.providerUID = provider + ":" + id
    return w
}
