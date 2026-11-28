import Foundation

// The open sources of the artwork chain: Wikidata, Wikipedia and Wikimedia Commons (free pictures, verified ids), MusicBrainz (the id links) and the
// Cover Art Archive (album covers). Every request goes through the governed transport (host lanes, single flight, circuit breaker).

enum MusicArtworkNet {
    /// One GET. A "not found" reply is an empty answer (nil), anything else that fails is thrown so the resolver can remember it briefly.
    static func get(_ context: MusicArtworkContext, _ url: String, _ query: [String: String] = [:]) async throws -> Data? {
        guard let u = URL(string: url) else { return nil }
        do { return try await context.transport.get(u, query: query, headers: MusicSourceKit.headers) }
        catch let e as MusicError where e == .notFound { return nil }
    }

    static let wikidataAPI = "https://www.wikidata.org/w/api.php"
    static let wikipediaAPI = "https://en.wikipedia.org/w/api.php"
    static let commonsAPI = "https://commons.wikimedia.org/w/api.php"
    static let musicBrainz = "https://musicbrainz.org/ws/2/"
}

/// Free pictures through Wikidata: the person's P18 image, a film's P3383 poster or P18 image, and the lead image of the matching Wikipedia article.
/// The identity is settled FIRST (a known id, a MusicBrainz link, or a unique name-and-job match), and a picture is only taken from that one item.
struct WikimediaArtworkSource: MusicArtworkSource {
    var id: MusicArtworkSourceID { .wikimedia }
    var switchID: MusicSourceID? { .wikidata }
    func applies(to kind: MusicEntityKind) -> Bool { kind.isAgent || kind == .film || kind == .series }

    struct Identity: Sendable { var facts: MusicArtworkParsers.WikidataFacts; var confidence: Double; var evidence: [String] }

    func candidates(for subject: MusicArtworkSubject, context: MusicArtworkContext) async throws -> [MusicArtworkCandidate] {
        guard let who = try await identify(subject, context) else { return [] }
        let f = who.facts
        var out: [MusicArtworkCandidate] = []
        let files = subject.isFilmLike ? [(f.poster, "P3383"), (f.image, "P18")] : [(f.image, "P18")]
        for case let (file?, property) in files {
            if let info = try await commonsInfo(file, context) {
                out.append(MusicArtworkCandidate(address: info.thumbnail, source: .wikimedia, confidence: who.confidence, evidence: who.evidence + [property], credit: info.creditLine))
            }
        }
        if let title = f.enwikiTitle, let lead = try await wikipediaLead(title: title, context: context), lead.wikibaseItem == f.id, let thumb = lead.thumbnail {
            out.append(MusicArtworkCandidate(address: thumb, source: .wikimedia, confidence: max(0, who.confidence - 0.02), evidence: who.evidence + ["wikipedia-lead"], credit: "Wikipedia"))
        }
        return out
    }

    // MARK: identity

    func identify(_ s: MusicArtworkSubject, _ context: MusicArtworkContext) async throws -> Identity? {
        // 1. a Wikidata id the graph holds
        if let q = s.externalID(.wikidata), let facts = try await facts([q], context)[q], !conflicts(s, facts) {
            return Identity(facts: facts, confidence: 1, evidence: ["wikidata-id"])
        }
        // 2. a MusicBrainz id the graph holds: MusicBrainz links the person to Wikidata
        if s.isPersonLike, let mb = s.externalID(.mbid), let links = try await mbLinks(mb, context), let q = links.wikidata,
           let facts = try await facts([q], context)[q], !conflicts(s, facts) {
            return Identity(facts: facts, confidence: 0.95, evidence: ["musicbrainz-link"])
        }
        // 3. a unique name-and-job (or title-and-year) match on Wikidata
        if let found = try await searchIdentity(s, context) { return found }
        // 4. a person only: exactly one exact-name artist at MusicBrainz that links to Wikidata
        if s.isPersonLike { return try await musicBrainzIdentity(s, context) }
        return nil
    }

    private func searchIdentity(_ s: MusicArtworkSubject, _ context: MusicArtworkContext) async throws -> Identity? {
        guard let raw = try await MusicArtworkNet.get(context, MusicArtworkNet.wikidataAPI,
                                                      ["action": "wbsearchentities", "search": s.name, "language": "en", "type": "item", "limit": "10", "format": "json"]) else { return nil }
        let hits = MusicArtworkParsers.wikidataSearch(raw)
        let passing: [MusicArtworkParsers.WikidataHit]
        var confidence = 0.88
        var evidence: [String]
        if s.isPersonLike {
            passing = hits.filter { h in h.names.contains { MusicArtworkMatch.namesMatch($0, s.name) } && MusicArtworkMatch.roleFits(description: h.description, roles: s.roles) }
            evidence = ["name", "role"]
        } else {
            let d: (String) -> String = { $0.lowercased() }
            passing = hits.filter { h in
                let desc = d(h.description)
                guard !desc.contains("soundtrack"), !desc.contains("album"), desc.contains(s.kind == .series ? "series" : "film") else { return false }
                guard h.names.contains(where: { MusicArtworkMatch.titlesMatch($0, s.name) }) else { return false }
                if let y = s.year { return MusicArtworkMatch.mentionsYear(h.description, y) }
                return true
            }
            evidence = s.year == nil ? ["title"] : ["title", "year"]
            if s.year == nil { confidence = 0.72 }
        }
        guard !passing.isEmpty else { return nil }
        let loaded = try await facts(passing.prefix(4).map(\.id), context)
        let usable = passing.compactMap { loaded[$0.id] }.filter { !conflicts(s, $0) }
        if usable.count == 1, let f = usable.first { return Identity(facts: f, confidence: confidence, evidence: evidence) }
        // Several fit: only an id the graph already holds can tell them apart.
        let byID = usable.filter { f in
            (s.externalID(.imdbName).map { $0 == f.imdb } ?? false) || (s.externalID(.imdbTitle).map { $0 == f.imdb } ?? false)
                || (s.externalID(.mbid).map { $0 == f.musicBrainz } ?? false) || (s.externalID(.tmdbPerson).map { $0 == f.tmdbPerson } ?? false)
                || (s.externalID(.tmdbMovie).map { $0 == f.tmdbMovie } ?? false)
        }
        if byID.count == 1, let f = byID.first { return Identity(facts: f, confidence: 0.95, evidence: evidence + ["id-tiebreak"]) }
        return nil
    }

    private func musicBrainzIdentity(_ s: MusicArtworkSubject, _ context: MusicArtworkContext) async throws -> Identity? {
        guard let raw = try await MusicArtworkNet.get(context, MusicArtworkNet.musicBrainz + "artist/", ["query": "artist:\"" + s.name.replacingOccurrences(of: "\"", with: "") + "\"", "fmt": "json", "limit": "5"]) else { return nil }
        let exact = MusicArtworkParsers.musicBrainzArtists(raw).filter { MusicArtworkMatch.namesMatch($0.name, s.name) && $0.score >= 95 }
        guard exact.count == 1, let hit = exact.first, let links = try await mbLinks(hit.id, context), let q = links.wikidata,
              let facts = try await facts([q], context)[q], !conflicts(s, facts), facts.names.contains(where: { MusicArtworkMatch.namesMatch($0, s.name) }) else { return nil }
        return Identity(facts: facts, confidence: 0.8, evidence: ["musicbrainz-name", "musicbrainz-link"])
    }

    /// An id the graph holds that disagrees with the same kind of id on the item means the item is someone else.
    func conflicts(_ s: MusicArtworkSubject, _ f: MusicArtworkParsers.WikidataFacts) -> Bool {
        func differs(_ mine: String?, _ theirs: String?) -> Bool { if let mine, let theirs { return mine != theirs }; return false }
        return differs(s.externalID(.imdbName), f.imdb) || differs(s.externalID(.imdbTitle), f.imdb) || differs(s.externalID(.mbid), f.musicBrainz)
            || differs(s.externalID(.tmdbPerson), f.tmdbPerson) || differs(s.externalID(.tmdbMovie), f.tmdbMovie)
    }

    // MARK: requests

    private func facts(_ ids: [String], _ context: MusicArtworkContext) async throws -> [String: MusicArtworkParsers.WikidataFacts] {
        let clean = ids.filter { $0.hasPrefix("Q") && $0.dropFirst().allSatisfy(\.isNumber) }
        guard !clean.isEmpty, let raw = try await MusicArtworkNet.get(context, MusicArtworkNet.wikidataAPI,
              ["action": "wbgetentities", "ids": clean.joined(separator: "|"), "props": "claims|labels|aliases|sitelinks", "languages": "en", "sitefilter": "enwiki", "format": "json"]) else { return [:] }
        return MusicArtworkParsers.wikidataEntities(raw)
    }

    private func mbLinks(_ mbid: String, _ context: MusicArtworkContext) async throws -> MusicArtworkParsers.MBArtistLinks? {
        guard UUID(uuidString: mbid) != nil, let raw = try await MusicArtworkNet.get(context, MusicArtworkNet.musicBrainz + "artist/" + mbid, ["inc": "url-rels", "fmt": "json"]) else { return nil }
        return MusicArtworkParsers.musicBrainzArtistLinks(raw)
    }

    private func commonsInfo(_ file: String, _ context: MusicArtworkContext) async throws -> MusicArtworkParsers.CommonsImage? {
        guard let raw = try await MusicArtworkNet.get(context, MusicArtworkNet.commonsAPI,
              ["action": "query", "titles": "File:" + file, "prop": "imageinfo", "iiprop": "url|extmetadata", "iiurlwidth": "500", "format": "json", "formatversion": "2"]) else { return nil }
        return MusicArtworkParsers.commonsImage(raw)
    }

    private func wikipediaLead(title: String, context: MusicArtworkContext) async throws -> MusicArtworkParsers.WikipediaImage? {
        guard let raw = try await MusicArtworkNet.get(context, MusicArtworkNet.wikipediaAPI,
              ["action": "query", "titles": title, "prop": "pageimages|pageprops", "piprop": "thumbnail", "pithumbsize": "500", "ppprop": "wikibase_item", "format": "json"]) else { return nil }
        return MusicArtworkParsers.wikipediaPageImage(raw)
    }
}

/// Album covers from the Cover Art Archive: through a MusicBrainz release-group id the graph knows, or one MusicBrainz search that agrees on title and artist.
struct CoverArtArtworkSource: MusicArtworkSource {
    var id: MusicArtworkSourceID { .coverArtArchive }
    var switchID: MusicSourceID? { .musicbrainz }
    func applies(to kind: MusicEntityKind) -> Bool { kind == .album || kind == .release }

    func candidates(for s: MusicArtworkSubject, context: MusicArtworkContext) async throws -> [MusicArtworkCandidate] {
        if let rg = s.externalID(.mbReleaseGroup) {
            return MusicArtworkMatch.coverArtArchive(releaseGroup: rg).map { MusicArtworkCandidate(address: $0, source: .coverArtArchive, confidence: 1, evidence: ["mb-release-group-id"], credit: "Cover Art Archive") }
        }
        if s.kind == .release, let r = s.externalID(.mbid) {
            return MusicArtworkMatch.coverArtArchive(release: r).map { MusicArtworkCandidate(address: $0, source: .coverArtArchive, confidence: 1, evidence: ["mb-release-id"], credit: "Cover Art Archive") }
        }
        var q = "releasegroup:\"" + s.name.replacingOccurrences(of: "\"", with: "") + "\""
        if let c = s.creator, !c.isEmpty { q += " AND artist:\"" + c.replacingOccurrences(of: "\"", with: "") + "\"" }
        guard let raw = try await MusicArtworkNet.get(context, MusicArtworkNet.musicBrainz + "release-group/", ["query": q, "fmt": "json", "limit": "5"]) else { return [] }
        let good = MusicArtworkParsers.musicBrainzReleaseGroups(raw).filter { hit in
            hit.score >= 90 && MusicArtworkMatch.titlesMatch(hit.title, s.name)
                && (s.creator.map { c in hit.artists.contains { MusicArtworkMatch.creatorsOverlap($0, c) } } ?? true)
        }
        guard let best = good.first else { return [] }
        let conf = s.creator == nil ? 0.7 : 0.9
        return MusicArtworkMatch.coverArtArchive(releaseGroup: best.id).map { MusicArtworkCandidate(address: $0, source: .coverArtArchive, confidence: conf, evidence: ["title", s.creator == nil ? "mb-score" : "title+artist"], credit: "Cover Art Archive") }
    }
}
