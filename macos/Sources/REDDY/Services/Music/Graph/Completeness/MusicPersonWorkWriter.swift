import Foundation

/// Writes the works of the completeness pass into the graph through the resolver's own ingest (so identity, strong ids, conflicts, provenance and the
/// edge aggregator behave exactly as for every other source). What this adds is the matching that makes the same film or album from different sources
/// one entity: strong ids first, then the stored canonical key, then the name and year, never merging two editions (a provider's album stays its own
/// `release` entity, joined to the album by an `editionOf` claim).
struct MusicPersonWorkWriter: Sendable {
    let resolver: MusicEntityResolver
    var now: @Sendable () -> Date = { Date() }

    struct Result: Sendable {
        /// The entity each input work landed on, by index into the input.
        var ids: [Int: MusicEntityID] = [:]
        var editions: [Int: MusicEntityID] = [:]
        var edgesWritten = 0
        var changed: Set<MusicEntityID> = []
    }

    private var store: any MusicGraphStoring { resolver.store }

    // MARK: matching

    private static func entityKind(_ k: MusicPersonWorkKind) -> MusicEntityKind {
        switch k { case .film: .film; case .album: .album; case .work: .work; case .recording: .recording }
    }

    /// The agents an entity is credited to (outgoing credit edges), used to keep two different artists' same-titled albums apart.
    private func credited(_ id: MusicEntityID) async -> Set<MusicEntityID> {
        let edges = (try? await store.edges(of: id, predicate: nil, direction: .outgoing, limit: 40)) ?? []
        return Set(edges.filter { !$0.tombstone && $0.object.kind.isAgent && [.performedBy, .composedBy, .musicDirectedBy].contains($0.predicate) }.map(\.object))
    }

    /// The entity this work already is in the graph, if any.
    func existing(_ w: MusicPersonWork, person: MusicEntityID?) async -> MusicEntityID? {
        let kind = Self.entityKind(w.kind)
        for x in w.ids where x.isStrong && x.scheme != .provider {
            if let id = try? await store.resolveAlias(for: x, kind: kind) { return id }
        }
        if w.kind == .album, let uid = w.providerUID, let rel = try? await store.resolveAlias(for: ExternalID(.provider, uid), kind: .release),
           let up = (try? await store.edges(of: rel, predicate: .editionOf, direction: .outgoing, limit: 3))?.first(where: { !$0.tombstone }) { return up.object }
        if let id = try? await store.resolveAlias(for: MusicPersonWorkKey.canon(w), kind: kind) { return id }
        // by name and year
        let p = MusicPersonWorkKey.parse(w.title)
        guard !p.key.isEmpty else { return nil }
        let query = p.key.split(separator: " ").prefix(3).joined(separator: " ")
        let tol = w.kind == .film ? 1 : 2
        var best: (MusicEntityID, Int)?
        for hit in (try? await store.search(query, kinds: [kind], limit: 12)) ?? [] {
            guard MusicPersonWorkKey.parse(hit.name).key == p.key, MusicPersonWorkKey.yearsCompatible(hit.year, w.year, tolerance: tol),
                  let snap = try? await store.entity(hit.id) else { continue }
            if !MusicPersonWorkKey.langsCompatible(snap.lang, w.lang ?? p.lang) { continue }
            if w.kind == .album || w.kind == .work || w.kind == .recording {
                let who = await credited(hit.id)
                if let person, !who.isEmpty && !who.contains(person) { continue }
            }
            let dist = (hit.year != nil && w.year != nil) ? abs(hit.year! - w.year!) : 1
            if best == nil || dist < best!.1 { best = (hit.id, dist) }
        }
        return best?.0
    }

    // MARK: write

    private static func provenance(_ s: MusicSourceID) -> (license: SourceLicense, retention: TimeInterval?, attribution: String?, confidence: Float) {
        switch s.rawValue {
        case "wikidata", "musicbrainz": (.cc0, nil, nil, 0.95)
        case "imdb": (.termsRestricted, 30 * 86_400, "IMDb", 0.85)
        default: (.providerCache, nil, nil, 0.7)
        }
    }

    /// The edge a relation gives between a work and the person, or nil when the pair makes no sense (a lyricist of a film).
    static func credit(_ rel: MusicPersonRelation, on w: MusicPersonWork, personIsComposer: Bool) -> (MusicPredicate, MusicRole, CreditLevel, Int?)? {
        let soundtrackish = w.isSoundtrack || MusicPersonWorkKey.parse(w.title).soundtrackWording
        switch (w.kind, rel) {
        case (.film, .cast): return (.hasCast, .actor, .film, nil)
        case (.film, .director): return (.directedBy, .director, .film, nil)
        case (.film, .composer): return (.musicDirectedBy, .musicDirector, .film, 0)
        case (.film, .producer): return (.producedBy, .producer, .film, nil)
        case (.album, .composer): return soundtrackish ? (.musicDirectedBy, .musicDirector, .album, 0) : (.composedBy, .composer, .album, 0)
        case (.album, .performer):
            // A catalogue lists a film's music director under the soundtrack: for a composer that is a music credit, not a singing one.
            if personIsComposer && soundtrackish && w.source.rank < 3 { return (.musicDirectedBy, .musicDirector, .album, 0) }
            return (.performedBy, .performer, .album, 0)
        case (.album, .lyricist): return (.writtenBy, .lyricist, .album, 0)
        case (.work, .composer): return (.composedBy, .composer, .song, nil)
        case (.work, .lyricist): return (.writtenBy, .lyricist, .song, nil)
        case (.work, .performer), (.recording, .performer): return (.performedBy, .performer, .song, nil)
        case (.recording, .composer): return (.composedBy, .composer, .song, nil)
        case (.recording, .lyricist): return (.writtenBy, .lyricist, .song, nil)
        default: return nil
        }
    }

    /// Writes `works` (all of one pass; several sources allowed). Returns where each landed.
    /// `person` nil writes the works without any credit to a person (a film's soundtrack albums); `bindings` forces an input onto a known entity.
    func write(_ works: [MusicPersonWork], person: MusicEntityID?, personIsComposer: Bool, bindings: [Int: MusicEntityID] = [:]) async throws -> Result {
        var result = Result()
        let personRef = person.map { MusicDraftRef.known($0) }
        let bySource = Dictionary(grouping: works.indices, by: { works[$0].source })
        for (source, indices) in bySource.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            try Task.checkCancellation()
            let meta = Self.provenance(source)
            var batch = MusicClaimBatch(source: source, license: meta.license, retrievedAt: now(), retention: meta.retention, attribution: meta.attribution)
            var bind: [MusicDraftRef: MusicEntityID] = [:]
            var refs: [Int: MusicDraftRef] = [:], editionRefs: [Int: MusicDraftRef] = [:]
            for i in indices {
                let w = works[i]
                let kind = Self.entityKind(w.kind)
                let canon = MusicPersonWorkKey.canon(w)
                let ref = MusicDraftRef.local(kind, canon.value)
                refs[i] = ref
                if let id = bindings[i] { bind[ref] = id } else if let id = await existing(w, person: person) { bind[ref] = id }
                let p = MusicPersonWorkKey.parse(w.title)
                var attrs: [String: String] = [:]
                if let d = w.filmTitle { attrs["filmHint"] = d }
                let strong = w.ids.filter { $0.isStrong && $0.scheme != .provider }
                // Display name: an album is shown under the title the source gave (editions stay in the edition list, not in the name).
                let draft = MusicEntityDraft(kind: kind, name: w.title, subkind: w.subkind, lang: w.lang ?? p.lang, year: w.year, imageRef: w.providerUID == nil ? nil : w.imageHint,
                                             attrs: attrs, externalIDs: [canon] + strong)
                if !batch.drafts.contains(where: { $0.ref == ref }) { batch.drafts.append(MusicSourceDraft(ref, draft)) }
                if let h = w.imageHint, w.providerUID == nil { batch.imageHints[ref] = h }
                for rel in w.relations.sorted(by: { $0.rawValue < $1.rawValue }) {
                    guard let personRef, let (pred, role, level, order) = Self.credit(rel, on: w, personIsComposer: personIsComposer) else { continue }
                    var c = MusicClaimDraft(subject: ref, predicate: pred, object: personRef, role: role, order: order, creditLevel: level, confidence: meta.confidence,
                                            evidence: ["completeness", source.rawValue], sourceRef: w.sourceRef)
                    if source.rank < 3 && role == .musicDirector && w.kind == .album { c.confidence = 0.6; c.evidence.append("catalogue-listing") }
                    batch.claims.append(c)
                }
                // A provider's own album is a separate edition entity: never merged, only joined.
                if w.kind == .album, let uid = w.providerUID {
                    let er = MusicDraftRef.external(.release, ExternalID(.provider, uid))
                    editionRefs[i] = er
                    var rd = MusicEntityDraft(kind: .release, name: w.title, subkind: w.subkind, lang: w.lang ?? p.lang, year: w.year, imageRef: w.imageHint, externalIDs: [ExternalID(.provider, uid)], provisional: true)
                    if let d = w.filmTitle { rd.attrs["filmHint"] = d }
                    if !batch.drafts.contains(where: { $0.ref == er }) { batch.drafts.append(MusicSourceDraft(er, rd)) }
                    batch.claims.append(MusicClaimDraft(subject: er, predicate: .editionOf, object: ref, creditLevel: .album, confidence: 0.85, evidence: ["title+artist", "provider-listing"], sourceRef: w.sourceRef))
                    if let personRef, let (pred, role, level, order) = Self.credit(.performer, on: w, personIsComposer: false) {
                        batch.claims.append(MusicClaimDraft(subject: er, predicate: pred, object: personRef, role: role, order: order, creditLevel: level, confidence: 0.6, evidence: ["provider-listing"]))
                    }
                }
            }
            try Task.checkCancellation()
            let report = try await resolver.ingest(batch, bind: bind)
            result.edgesWritten += report.edgesWritten
            for (i, r) in refs { if let id = report.ids[r] { result.ids[i] = id; result.changed.insert(id) } }
            for (i, r) in editionRefs { if let id = report.ids[r] { result.editions[i] = id; result.changed.insert(id) } }
        }
        if !result.changed.isEmpty, let person { result.changed.insert(person) }
        return result
    }

    // MARK: soundtrack links

    struct Pair: Sendable, Equatable { var album: Int; var film: Int; var stated: Bool; var confidence: Float }

    /// Which album is the soundtrack of which film, from what the sources said. Stated by Wikidata (P406 names the album), or inferred from the same
    /// title with soundtrack wording, a compatible language and a year within one of the film's. Never from a title alone with nothing else to agree.
    static func soundtrackPairs(albums: [MusicPersonWork], films: [MusicPersonWork]) -> [Pair] {
        var out: [Pair] = []
        for (ai, a) in albums.enumerated() {
            let ap = MusicPersonWorkKey.parse(a.title)
            let aq = Set(a.ids.filter { $0.scheme == .wikidata }.map(\.value))
            for (fi, f) in films.enumerated() {
                if let q = f.soundtrackQID, aq.contains(q) { out.append(Pair(album: ai, film: fi, stated: true, confidence: 0.95)); continue }
                if a.statesFilm, a.filmTitle.map({ MusicPersonWorkKey.filmKey($0) == MusicPersonWorkKey.filmKey(f.title) }) ?? false { out.append(Pair(album: ai, film: fi, stated: true, confidence: 0.95)); continue }
                guard a.isSoundtrack || ap.soundtrackWording else { continue }
                let fk = MusicPersonWorkKey.filmKey(f.title)
                let named = ap.key == fk || (a.filmTitle.map { MusicPersonWorkKey.filmKey($0) == fk } ?? false)
                guard named, !fk.isEmpty, MusicPersonWorkKey.yearsCompatible(a.year, f.year, tolerance: 1) else { continue }
                let known = a.year != nil && f.year != nil
                out.append(Pair(album: ai, film: fi, stated: false, confidence: known ? 0.8 : 0.65))
            }
        }
        return out
    }

    func link(_ pairs: [Pair], albumIDs: [MusicEntityID], filmIDs: [MusicEntityID], albums: [MusicPersonWork]) async throws -> Int {
        var claims: [MusicEdgeClaim] = []
        for p in pairs {
            guard albumIDs.indices.contains(p.album), filmIDs.indices.contains(p.film) else { continue }
            var attrs = EdgeAttributes()
            attrs.dubLanguage = nil
            let e = MusicEdge(subject: albumIDs[p.album], predicate: .soundtrackOf, object: filmIDs[p.film], attributes: attrs, confidence: p.confidence, creditLevel: .album)
            let prov = p.stated
                ? MusicProvenance(source: .wikidata, sourceRef: albums.indices.contains(p.album) ? albums[p.album].sourceRef : nil, retrievedAt: now(), license: .cc0, score: p.confidence,
                                  matcherVersion: MusicResolutionScoring.matcherVersion, evidence: ["wikidata-statement", "P406", MusicProvenance.statedToken])
                : MusicProvenance(source: .matcher, retrievedAt: now(), license: .derived, score: p.confidence, matcherVersion: MusicResolutionScoring.matcherVersion,
                                  evidence: ["title+person", "soundtrack-wording"])
            claims.append(MusicEdgeClaim(e, prov))
        }
        guard !claims.isEmpty else { return 0 }
        return try await store.addEdges(claims).count
    }
}
