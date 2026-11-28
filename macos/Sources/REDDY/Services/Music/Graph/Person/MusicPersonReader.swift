import Foundation

/// Reads one person's graph neighbourhood for the page, bounded and cancellable (section 5.4 of the design): every store read spends from one budget,
/// results are cached for the life of the reader, and when the budget is gone the reader keeps what it has and says `truncated`. It writes nothing and
/// never touches the player. One reader serves one view load; a new load makes a new reader (so nothing here goes stale).
actor MusicPersonReader {
    /// One page build reads the person's credits, a snapshot per film and album, and the soundtrack links of each film: a full filmography is a few hundred.
    static let defaultMaxReads = 9000
    /// Section sizes: the shelf shows `shelf` entries and says how many more there are.
    static let shelf = 12
    static let songs = 20
    static let grid = 500
    /// Film and album credits read for one page (a prolific music director has well over a hundred films), and songs listed under compositions.
    static let filmCap = 600
    static let albumCap = 400
    static let compositions = 400
    /// Songs a singer's page reads and lists: the whole of what the graph holds up to this many (the shelf on the Overview still shows the first few).
    static let singerSongs = 400

    let store: any MusicGraphStoring
    let person: MusicEntityID
    private let maxReads: Int
    private var reads = 0
    private(set) var truncated = false
    private(set) var snapCache: [MusicEntityID: MusicEntitySnapshot] = [:]
    private var snapMissing: Set<MusicEntityID> = []
    private var outCache: [MusicEntityID: [MusicEdge]] = [:]
    private var inCache: [String: [MusicEdge]] = [:]
    private var creditCache: [MusicEdge]?
    private var filmCache: [MusicEntityID: FilmLink?] = [:]

    /// A song's film and how sure the graph is of it.
    struct FilmLink: Hashable, Sendable { var film: MusicEntityID; var status: EdgeStatus; var confidence: Float; var viaRelease: Bool }

    init(store: any MusicGraphStoring, person: MusicEntityID, maxReads: Int = MusicPersonReader.defaultMaxReads) {
        self.store = store; self.person = person; self.maxReads = max(1, maxReads)
    }

    var readsSpent: Int { reads }

    private func spend() -> Bool {
        guard reads < maxReads else { truncated = true; return false }
        reads += 1
        return true
    }

    // MARK: reads

    func snapshot(_ id: MusicEntityID) async -> MusicEntitySnapshot? {
        if let s = snapCache[id] { return s }
        if snapMissing.contains(id) { return nil }
        guard spend() else { return nil }
        let s = (try? await store.entity(id)) ?? nil
        if let s, s.state == .live { snapCache[id] = s; return s }
        snapMissing.insert(id)
        return nil
    }

    func snapshots(_ ids: [MusicEntityID]) async -> [MusicEntitySnapshot] {
        var out: [MusicEntitySnapshot] = []
        for id in ids {
            if Task.isCancelled { break }
            if let s = await snapshot(id) { out.append(s) }
        }
        return out
    }

    /// Edges leaving an entity that count as claims (no tombstones). One read serves every predicate.
    func outgoing(_ id: MusicEntityID) async -> [MusicEdge] {
        if let e = outCache[id] { return e }
        guard spend() else { return [] }
        let e = ((try? await store.edges(of: id, predicate: nil, direction: .outgoing, limit: 100)) ?? []).filter { !$0.tombstone }
        outCache[id] = e
        return e
    }

    func incoming(_ id: MusicEntityID, _ p: MusicPredicate, limit: Int = 60) async -> [MusicEdge] {
        let key = id.rawValue + "|\(p.rawValue)"
        if let e = inCache[key] { return e }
        guard spend() else { return [] }
        let e = ((try? await store.edges(of: id, predicate: p, direction: .incoming, limit: limit)) ?? []).filter { !$0.tombstone }
        inCache[key] = e
        return e
    }

    /// The edges that give this person a role (everything pointing at them that counts), best first.
    func credits() async -> [MusicEdge] {
        if let c = creditCache { return c }
        guard spend() else { return [] }
        var all = (try? await store.edges(of: person, predicate: nil, direction: .incoming, limit: 500)) ?? []
        // The store caps one read at 500 edges, and a prolific artist has more (hundreds of album and release credits come first, so their song credits sat past
        // the cap and the page showed albums but no songs). Read the following pages of the same ordered list, up to `creditPages` in all.
        var page = 1
        while all.count >= 500 * page, page < Self.creditPages, spend() {
            let more = (try? await store.edges(of: person, predicate: nil, direction: .incoming, limit: 500, offset: 500 * page)) ?? []
            all += more
            page += 1
            if more.count < 500 { break }
        }
        // Still capped (an extreme fan-in): read the credit predicates one by one so a film or album credit is never pushed out by hundreds of song credits.
        if all.count >= 500 * Self.creditPages {
            var seen = Set(all.map(\.key))
            for p in Self.creditPredicates {
                guard spend() else { break }
                for e in (try? await store.edges(of: person, predicate: p, direction: .incoming, limit: 500)) ?? [] where seen.insert(e.key).inserted { all.append(e) }
            }
        }
        let c = all.filter(MusicPersonRoles.counts).sorted(by: Self.better)
        creditCache = c
        return c
    }

    /// Pages of 500 incoming edges read for one page build (3,000 credits).
    static let creditPages = 6
    static let creditPredicates: [MusicPredicate] = [.hasCast, .directedBy, .musicDirectedBy, .composedBy, .writtenBy, .performedBy, .producedBy]

    /// Roles from the credits (one read, plus one per predicate when the store's cap was hit; cached).
    func roleSummary() async -> MusicPersonRoleSummary { MusicPersonRoles.summarize(incoming: await credits()) }

    /// Groups this person belongs to (outgoing `memberOf`), as entries.
    func groupsOfPerson() async -> [MusicPersonEntry] {
        let out = await outgoing(person).filter { $0.predicate == .memberOf }
        var entries: [MusicPersonEntry] = []
        for e in out { if let s = await snapshot(e.object), s.kind == .group { var x = MusicPersonEntry(snapshot: s); x.status = e.status; x.confidence = e.confidence; entries.append(x) } }
        return entries.sorted { $0.name < $1.name }
    }

    /// Members of this group (incoming `memberOf`), only when a source listed them.
    func membersOfGroup() async -> [MusicPersonEntry] {
        let inc = await incoming(person, .memberOf, limit: 40)
        var entries: [MusicPersonEntry] = []
        for e in inc where e.subject.kind == .person { if let s = await snapshot(e.subject) { var x = MusicPersonEntry(snapshot: s); x.status = e.status; x.confidence = e.confidence; entries.append(x) } }
        return entries.sorted { $0.name != $1.name ? $0.name < $1.name : $0.id < $1.id }
    }

    /// People and groups a source states as this one's influences (outgoing `influencedBy`).
    func influences() async -> [MusicPersonEntry] {
        var entries: [MusicPersonEntry] = []
        for e in await outgoing(person) where e.predicate == .influencedBy { if let s = await snapshot(e.object) { var x = MusicPersonEntry(snapshot: s); x.status = e.status; x.confidence = e.confidence; entries.append(x) } }
        return entries.sorted { $0.name != $1.name ? $0.name < $1.name : $0.id < $1.id }
    }

    /// People and groups whose stated influences include this one (incoming `influencedBy`).
    func influenced() async -> [MusicPersonEntry] {
        var entries: [MusicPersonEntry] = []
        for e in await incoming(person, .influencedBy, limit: 40) { if let s = await snapshot(e.subject) { var x = MusicPersonEntry(snapshot: s); x.status = e.status; x.confidence = e.confidence; entries.append(x) } }
        return entries.sorted { $0.name != $1.name ? $0.name < $1.name : $0.id < $1.id }
    }

    // MARK: ordering

    /// Verified before inferred, then more confident, then a stable id.
    static func better(_ a: MusicEdge, _ b: MusicEdge) -> Bool {
        if (a.status == .verified) != (b.status == .verified) { return a.status == .verified }
        if a.confidence != b.confidence { return a.confidence > b.confidence }
        return a.subject != b.subject ? a.subject < b.subject : a.qualifier < b.qualifier
    }

    static func popularity(_ s: MusicEntitySnapshot) -> Int { s.attrs["popularity"].flatMap(Int.init) ?? 0 }

    /// Score of a work for "top" lists: the source's popularity when it gave one, then how sure the credit is.
    static func score(_ s: MusicEntitySnapshot, _ e: MusicEdge) -> Double {
        Double(popularity(s)) * 10 + (e.status == .verified ? 50 : 0) + Double(e.confidence) * 20
    }

    static func byScoreThenName(_ a: (MusicEntitySnapshot, MusicEdge), _ b: (MusicEntitySnapshot, MusicEdge)) -> Bool {
        let (sa, sb) = (score(a.0, a.1), score(b.0, b.1))
        if sa != sb { return sa > sb }
        if a.0.nameLatin != b.0.nameLatin { return a.0.nameLatin < b.0.nameLatin }
        return a.0.id < b.0.id
    }

    /// The person's credits in a view, on works of these kinds, resolved to live snapshots (at most `cap`), best first.
    func works(view: MusicPersonView, kinds: Set<MusicEntityKind>, cap: Int) async -> [(snap: MusicEntitySnapshot, edge: MusicEdge)] {
        let edges = await credits().filter { e in kinds.contains(e.subject.kind) && (MusicPersonRoles.effectiveRole(e).map(view.roles.contains) ?? false) }
        // The credits come ordered by how sure the graph is, not by how well known the work is, so cutting them at `cap` first would keep an arbitrary `cap` of a prolific
        // artist's songs and only then rank those. A wider window (three times the cap) is read, ranked, and then cut: the top songs are the best of many, not of a few.
        let window = cap * 3
        var seen = Set<MusicEntityID>(), picked: [(MusicEntitySnapshot, MusicEdge)] = []
        for e in edges where seen.insert(e.subject).inserted {
            if picked.count >= window { truncated = truncated || edges.count > window; break }
            if Task.isCancelled { break }
            if let s = await snapshot(e.subject) { picked.append((s, e)) }
        }
        let ranked = picked.sorted(by: Self.byScoreThenName)
        if ranked.count > cap { truncated = true }
        return ranked.prefix(cap).map { (snap: $0.0, edge: $0.1) }
    }

    /// How many credits the person has in a view on works of these kinds (before any cap).
    func creditCount(view: MusicPersonView, kinds: Set<MusicEntityKind>) async -> Int {
        Set(await credits().filter { e in kinds.contains(e.subject.kind) && (MusicPersonRoles.effectiveRole(e).map(view.roles.contains) ?? false) }.map(\.subject)).count
    }

    // MARK: film links

    /// The film a song or album belongs to: a stated `featuredIn` / `soundtrackOf` first, else the soundtrack link of the release it is on.
    func filmLink(of work: MusicEntityID) async -> FilmLink? {
        if let cached = filmCache[work] { return cached }
        let out = await outgoing(work)
        var best: FilmLink?
        func consider(_ e: MusicEdge, via: Bool) {
            guard [.film, .series].contains(e.object.kind) else { return }
            let l = FilmLink(film: e.object, status: e.status, confidence: e.confidence, viaRelease: via)
            if best == nil || (l.status == .verified && best?.status != .verified) || (l.status == best?.status && l.confidence > (best?.confidence ?? 0)) { best = l }
        }
        for e in out where e.predicate == .featuredIn || e.predicate == .soundtrackOf { consider(e, via: false) }
        if best == nil {
            for r in out where r.predicate == .trackOn {
                for e in await outgoing(r.object) where e.predicate == .soundtrackOf { consider(e, via: true) }
            }
        }
        filmCache[work] = .some(best)
        return best
    }

    /// An inferred film link below 0.75 is worded as "possibly" (section 5.2).
    static func reason(for link: FilmLink, filmTitle: String) -> MusicPersonReason {
        link.status != .verified && link.confidence < 0.75 ? .possibleFilmLink(filmTitle) : .fromFilm(filmTitle)
    }

    // MARK: credit observations

    private static func level(_ e: MusicEdge, subject: MusicEntityKind) -> CreditLevel {
        if e.creditLevel != .unknown { return e.creditLevel }
        switch subject { case .film, .series: return .film; case .album, .release: return .album; default: return .song }
    }

    /// Who else is credited on these works, in these roles. Song-level credits first; a song with none of those roles takes its release's credits
    /// (album level), then its film's (film level). The person themself and `excluding` are never reported.
    func observations(of works: [MusicEntityID], roles: Set<MusicRole>, releaseLevel: Bool = true, filmLevel: Bool = true) async -> [MusicCreditObservation] {
        var out: [MusicCreditObservation] = []
        func take(_ edges: [MusicEdge], work: MusicEntityID, level: CreditLevel?) -> Bool {
            var got = false
            for e in edges where MusicPersonRoles.counts(e) && e.object.kind.isAgent && e.object != person {
                guard let r = MusicPersonRoles.effectiveRole(e), roles.contains(r) else { continue }
                out.append(MusicCreditObservation(work: work, agent: e.object, role: r, level: level ?? Self.level(e, subject: e.subject.kind), confidence: e.confidence))
                got = true
            }
            return got
        }
        for w in works {
            if Task.isCancelled { break }
            let own = await outgoing(w)
            if take(own, work: w, level: nil) { continue }
            if releaseLevel {
                var found = false
                for r in own where r.predicate == .trackOn { if take(await outgoing(r.object), work: w, level: .album) { found = true; break } }
                if found { continue }
            }
            if filmLevel, let f = await filmLink(of: w) { _ = take(await outgoing(f.film), work: w, level: .film) }
        }
        return out
    }

    /// Entries for ranked collaborators, with names resolved (those that no longer resolve are dropped).
    func collaboratorEntries(_ ranked: [MusicCollaborator], reason: (MusicCollaborator) -> MusicPersonReason?) async -> [MusicPersonEntry] {
        var out: [MusicPersonEntry] = []
        for c in ranked {
            guard let s = await snapshot(c.id) else { continue }
            var e = MusicPersonEntry(snapshot: s)
            e.count = c.workCount; e.roles = c.roles; e.reason = reason(c)
            out.append(e)
        }
        return out
    }

    func names(_ ids: [MusicEntityID]) async -> [String] { await snapshots(ids).map(\.name) }

    /// The performer line of a song, from its own credits (outgoing `performedBy`), billing order.
    func performerLine(of work: MusicEntityID, excluding: Set<MusicEntityID> = []) async -> String? {
        let ids = await outgoing(work).filter { $0.predicate == .performedBy && MusicPersonRoles.counts($0) && !excluding.contains($0.object) }
            .sorted { ($0.order ?? Int.max) < ($1.order ?? Int.max) }.map(\.object)
        let n = await names(Array(ids.prefix(3)))
        return n.isEmpty ? nil : n.joined(separator: ", ")
    }

    // MARK: entry helpers

    func entry(_ s: MusicEntitySnapshot, edge: MusicEdge?) -> MusicPersonEntry {
        var e = MusicPersonEntry(snapshot: s)
        if let edge {
            e.status = edge.status; e.confidence = edge.confidence
            e.billing = edge.attributes.creditOrder ?? edge.order
            if let c = edge.attributes.characterName, !c.isEmpty { e.detail = c }
            if let r = MusicPersonRoles.effectiveRole(edge) { e.roles = [r] }
        }
        return e
    }

    static func cut(_ id: MusicPersonSectionID, _ entries: [MusicPersonEntry], to n: Int) -> MusicPersonSection {
        MusicPersonSection(id, Array(entries.prefix(n)), total: entries.count)
    }

    /// Year descending (unknown last), then name: the order of a filmography.
    static func newestFirst(_ a: MusicPersonEntry, _ b: MusicPersonEntry) -> Bool {
        switch (a.year, b.year) {
        case let (x?, y?) where x != y: return x > y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.name != b.name ? a.name < b.name : a.id < b.id
        }
    }

    /// Distinct entries by id, first seen wins.
    static func unique(_ entries: [MusicPersonEntry]) -> [MusicPersonEntry] {
        var seen = Set<MusicEntityID>()
        return entries.filter { seen.insert($0.id).inserted }
    }

    // MARK: build

    typealias Report = @Sendable (MusicPersonViewData) async -> Void

    /// Builds one view. `report` receives the partial data after each stage so the page shows its first sections before the last are in.
    func build(_ view: MusicPersonView, report: @escaping Report = { _ in }) async throws -> MusicPersonViewData {
        let data: MusicPersonViewData
        switch view {
        case .singer: data = try await buildSinger(report)
        case .composer: data = try await buildComposer(report)
        case .lyricist: data = try await buildLyricist(report)
        case .actor: data = try await buildActor(report)
        case .director: data = try await buildDirector(report)
        case .producer: data = try await buildCredited(view, songs: .producedSongs, report: report)
        case .instrumentalist: data = try await buildCredited(view, songs: .instrumentSongs, report: report)
        case .conductor: data = try await buildCredited(view, songs: .conductedSongs, report: report)
        case .label: data = try await buildCredited(view, songs: .labelCatalogue, report: report)
        }
        try Task.checkCancellation()
        return data
    }

    func data(_ view: MusicPersonView, _ sections: [MusicPersonSection], complete: Bool) -> MusicPersonViewData {
        MusicPersonViewData(person: person, view: view, sections: sections.filter { !$0.entries.isEmpty }, complete: complete, truncated: truncated)
    }
}
