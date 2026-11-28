import Foundation

struct MusicIngestReport: Sendable {
    var ids: [MusicDraftRef: MusicEntityID] = [:]
    var edgesWritten = 0
    /// Strong ids that two entities both claim and could not be merged (a blocker, or evidence short of the rule).
    var conflicts: [ExternalID] = []
    var merged: [(winner: MusicEntityID, loser: MusicEntityID)] = []
    var imageHints: [MusicEntityID: String] = [:]
}

struct MusicMetadataOutcome: Sendable {
    var entity: MusicEntityID?
    /// The store was fresh for every facet asked: no network call was made.
    var fromCache = false
    /// A network call failed and what the store holds past its expiry was served.
    var stale = false
    var cancelled = false
    var fetched: [MusicSourceID] = []
    var skipped: [MusicSourceID: MusicEnrichmentSkip] = [:]
    var failed: [MusicSourceID] = []
    var edgesWritten = 0
    var linkedFilm: MusicEntityID?
    var imageHints: [MusicEntityID: String] = [:]
}

/// The identity pipeline of section 3.4 and the lazy enrichment entry points. It owns the mapping from a source's drafts to entity ids: strong ids first,
/// then name, year, duration and transliteration heuristics, the two-signal merge rule, thresholds, identical-name handling, tombstones through the store,
/// and source precedence through the edge aggregator. Every entry point reads the store first, asks a source only when a facet is not fresh, never throws
/// for a network or source failure, and is never awaited by playback.
actor MusicEntityResolver {
    let store: any MusicGraphStoring
    let index: MusicEntityIndex
    private var sources: [MusicSourceID: any MusicMetadataSource]
    private let gate: any MusicEnrichmentGating
    let now: @Sendable () -> Date
    /// Films tied for the same soundtrack in one resolution (set and consumed inside `resolveFilm` and `writeSoundtrackEdge`).
    var ambiguous: [(MusicEntityID, MusicResolutionScoring.Scored)]?

    init(store: any MusicGraphStoring, sources: [any MusicMetadataSource], gate: any MusicEnrichmentGating = MusicEnrichmentPolicy.open,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.index = MusicEntityIndex(store: store); self.gate = gate; self.now = now
        self.sources = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    }

    func register(_ s: any MusicMetadataSource) { sources[s.id] = s }
    func hasSource(_ id: MusicSourceID) -> Bool { sources[id] != nil }

    // MARK: ingest

    private static let creditPredicates: Set<MusicPredicate> = [.hasCast, .directedBy, .composedBy, .producedBy, .musicDirectedBy]

    private func strongID(of id: MusicEntityID) async -> ExternalID? { (try? await store.externalIDs(of: id))?.first(where: \.isStrong) }

    /// Writes a batch: drafts to entities (strong ids first, bound ids honoured), claims to edges with provenance. Search batches write nothing.
    @discardableResult
    func ingest(_ batch: MusicClaimBatch, bind: [MusicDraftRef: MusicEntityID] = [:]) async throws -> MusicIngestReport {
        var report = MusicIngestReport()
        guard !batch.isSearch else { return report }
        var creditNames: [MusicEntityID: [String]]?   // film credits, loaded once for name-only matching
        func filmID(of claims: [MusicClaimDraft]) -> MusicDraftRef? { claims.first(where: { $0.subject.kind == .film })?.subject }

        // 1. entities
        for d in batch.drafts {
            try Task.checkCancellation()
            var draft = d.entity
            if let a = batch.attribution { draft.attrs["attribution"] = a }
            if let target = bind[d.ref] {
                // Attach the new ids to the bound entity by carrying one id it already has.
                if let own = await strongID(of: target) { draft.externalIDs = [own] + d.entity.externalIDs.filter { $0 != own } }
                let r = try await store.upsert(draft)
                var id = r.id
                if id != target {   // the new ids already belong to another entity: unify
                    id = try await unify(target, id, kind: draft.kind, report: &report)
                } else { await resolveConflicts(r.conflicts, into: id, kind: draft.kind, report: &report) }
                report.ids[d.ref] = id
                continue
            }
            if draft.attrs["nameOnly"] == "1", let fref = filmID(of: batch.claims), d.ref.kind == .person {
                let filmEntity = try await resolveRef(fref, report: report)
                if let film = filmEntity {
                    if creditNames == nil { creditNames = try await loadCreditNames(film) }
                    if let match = bestNameMatch(draft.name, in: creditNames ?? [:]) { report.ids[d.ref] = match; continue }
                }
            }
            let r = try await store.upsert(draft)
            report.ids[d.ref] = r.id
            await resolveConflicts(r.conflicts, into: r.id, kind: draft.kind, report: &report)
            if let hint = batch.imageHints[d.ref] { report.imageHints[r.id] = hint }
        }
        for (ref, hint) in batch.imageHints { if let id = report.ids[ref] { report.imageHints[id] = hint } }

        // 2. claims
        var edges: [MusicEdgeClaim] = []
        for c in batch.claims {
            guard let s = try await resolveRef(c.subject, report: report), let o = try await resolveRef(c.object, report: report), s != o,
                  c.predicate.accepts(subject: s.kind, object: o.kind) else { continue }
            var attrs = c.attributes
            if let a = c.attribution ?? batch.attribution { attrs["attribution"] = a }
            let edge = MusicEdge(subject: s, predicate: c.predicate, object: o, qualifier: c.role?.rawValue ?? "", attributes: attrs, confidence: c.confidence, creditLevel: c.creditLevel, order: c.order)
            let expires = batch.retention.map { batch.retrievedAt.addingTimeInterval($0) }
            let prov = MusicProvenance(source: batch.source, sourceRef: c.sourceRef, retrievedAt: batch.retrievedAt, expiresAt: expires, license: c.license ?? batch.license, score: c.confidence,
                                       matcherVersion: MusicResolutionScoring.matcherVersion, evidence: c.evidence + (c.stated ? [MusicProvenance.statedToken] : []), stance: c.stance)
            edges.append(MusicEdgeClaim(edge, prov))
        }
        if !edges.isEmpty { report.edgesWritten = try await store.addEdges(edges).count }
        return report
    }

    func resolveRef(_ ref: MusicDraftRef, report: MusicIngestReport) async throws -> MusicEntityID? {
        if let id = report.ids[ref] { return id }
        switch ref {
        case .known(let id): return try await store.resolve(id)
        case .external(let k, let x): return try await store.resolveAlias(for: x, kind: k)
        case .local: return nil
        }
    }

    private func loadCreditNames(_ film: MusicEntityID) async throws -> [MusicEntityID: [String]] {
        var out: [MusicEntityID: [String]] = [:]
        for e in try await store.edges(of: film, predicate: nil, direction: .outgoing, limit: 200) where Self.creditPredicates.contains(e.predicate) && !e.tombstone {
            guard out[e.object] == nil, let snap = try await store.entity(e.object) else { continue }
            out[e.object] = [snap.name] + ((try? await store.aliases(of: e.object)) ?? []).map(\.text)
        }
        return out
    }

    /// A name-only credit joins an existing credited person only at a near-exact name; two different people are never joined by a looser match.
    private func bestNameMatch(_ name: String, in credits: [MusicEntityID: [String]]) -> MusicEntityID? {
        var best: (MusicEntityID, Float)?
        for (id, names) in credits {
            let s = names.map { MusicTransliterationKey.similarity(name, $0) }.max() ?? 0
            if s >= 0.9, s > (best?.1 ?? 0) { best = (id, s) }
        }
        return best?.0
    }

    /// A draft's strong id belongs to another entity: merge only on the rule (a shared strong id inside one draft counts; blockers refuse).
    private func resolveConflicts(_ ids: [ExternalID], into id: MusicEntityID, kind: MusicEntityKind, report: inout MusicIngestReport) async {
        for x in ids {
            guard let other = try? await store.resolveAlias(for: x, kind: kind), other != id else { continue }
            if (try? await unify(id, other, kind: kind, report: &report)) == nil { report.conflicts.append(x) }
        }
    }

    /// Merges two entities that one source tied together with a strong id, unless a blocker says they are different (two strong ids of one scheme, or
    /// years too far apart). The older entity wins so saved references stay valid.
    @discardableResult
    private func unify(_ a: MusicEntityID, _ b: MusicEntityID, kind: MusicEntityKind, report: inout MusicIngestReport) async throws -> MusicEntityID {
        guard a != b, let sa = try await store.entity(a), let sb = try await store.entity(b) else { return a }
        let ia = try await store.externalIDs(of: a).filter(\.isStrong), ib = try await store.externalIDs(of: b).filter(\.isStrong)
        let blockers = MusicMergeRule.blockers(kind: kind, strongIDsA: ia, strongIDsB: ib, yearA: sa.year, yearB: sb.year, durationMsA: sa.durationMs, durationMsB: sb.durationMs)
        guard MusicMergeRule.decide(.init(kind: kind, sharedStrongID: true, signals: [], blockers: blockers)) == .merge else { throw MusicGraphError.invalidMerge("blocked") }
        let (winner, loser) = (sa.pinned != sb.pinned ? sa.pinned : sa.createdAt <= sb.createdAt) ? (a, b) : (b, a)
        let kept = try await store.mergeEntities(winner: winner, loser: loser, byUser: false)
        report.merged.append((kept, loser))
        return kept
    }

    // MARK: fetching

    enum Fetched { case batch(MusicClaimBatch), cached, skipped(MusicEnrichmentSkip), failed, unavailable }

    /// One governed, gated, cache-aware fetch. A fresh cache state answers without the network; a failure records the error (back-off) and returns `.failed`.
    func fetch(_ id: MusicSourceID, _ request: MusicSourceRequest, cacheEntity: MusicEntityID?, cacheFacet: String? = nil, background: Bool = false,
                       result: inout MusicMetadataOutcome) async -> Fetched {
        guard let source = sources[id] else { return .unavailable }
        let facet = cacheFacet ?? request.facet
        let t = now()
        if let e = cacheEntity, let st = try? await store.cacheState(entity: e, facet: facet, source: id) {
            if st.isFresh(at: t) { return .cached }
            if !st.needsFetch(at: t) { result.stale = true; return .failed }   // backing off after an error
        }
        let decision = gate.decision(for: id)
        if case .skipped(let why) = decision { result.skipped[id] = why; return .skipped(why) }
        if Task.isCancelled { result.cancelled = true; return .failed }
        do {
            let b = try await source.fetch(request, context: MusicFetchContext(now: now, background: background))
            if let e = cacheEntity {
                try? await store.setCacheState(entity: e, facet: facet, source: id, outcome: b.isEmpty ? .empty : .ok, ttl: b.isEmpty ? 7 * 86_400 : source.policy.ttl(for: request.facet),
                                               etag: nil, matcherVersion: MusicResolutionScoring.matcherVersion)
            }
            result.fetched.append(id)
            return .batch(b)
        } catch is CancellationError {
            result.cancelled = true; return .failed
        } catch let e as MusicSourceError where e == .disabled || e == .blocked {
            result.skipped[id] = .unconfigured; return .skipped(.unconfigured)
        } catch {
            if let e = cacheEntity { try? await store.setCacheState(entity: e, facet: facet, source: id, outcome: .error, ttl: 0, etag: nil, matcherVersion: nil) }
            result.failed.append(id); result.stale = true
            return .failed
        }
    }

    func take(_ f: Fetched, bind: [MusicDraftRef: MusicEntityID] = [:], result: inout MusicMetadataOutcome) async -> (MusicClaimBatch, MusicIngestReport?)? {
        guard case .batch(let b) = f else { return nil }
        if b.isSearch { return (b, nil) }
        guard let rep = try? await ingest(b, bind: bind) else { return (b, nil) }
        result.edgesWritten += rep.edgesWritten
        for (k, v) in rep.imageHints { result.imageHints[k] = v }
        return (b, rep)
    }

    // MARK: tracks

    /// What the matcher needs of a song, from a provider track or from a stored recording.
    struct TrackFacts: Sendable {
        var title: String
        var artists: [String]
        var durationMs: Int?
        var isrc: String?
        var albumTitle: String?
        var albumYear: Int?
        init(title: String, artists: [String], durationMs: Int? = nil, isrc: String? = nil, albumTitle: String? = nil, albumYear: Int? = nil) {
            self.title = title; self.artists = artists; self.durationMs = durationMs; self.isrc = isrc; self.albumTitle = albumTitle; self.albumYear = albumYear
        }
        init(_ t: MusicTrack) {
            self.init(title: t.title, artists: t.artists.map(\.name), durationMs: t.durationMs > 0 ? Int(t.durationMs) : nil, isrc: t.isrc.flatMap { $0.isEmpty ? nil : $0.uppercased() },
                      albumTitle: t.album?.title, albumYear: MusicGraphAdapters.year(t.album?.releaseDate))
        }
    }

    /// Credits for one provider track: recording, work, composer, lyricist and performers. Local mint first (instant), then at most a few paced
    /// requests; every one is skipped when the store is fresh.
    func enrichTrack(_ track: MusicTrack) async -> MusicMetadataOutcome {
        guard let rec = try? await index.mint(MusicGraphAdapters.plan(for: track)) else { return MusicMetadataOutcome() }
        return await enrichRecording(rec, TrackFacts(track))
    }

    /// The same for a recording already in the graph (what the navigation layer holds): the facts come from the store.
    func enrichRecording(_ id: MusicEntityID) async -> MusicMetadataOutcome {
        guard let rec = try? await store.resolve(id), let s = try? await store.entity(rec) else { return MusicMetadataOutcome() }
        let ids = (try? await store.externalIDs(of: rec)) ?? []
        let artists = await namesOf(rec, [.performedBy])
        return await enrichRecording(rec, TrackFacts(title: s.name, artists: artists, durationMs: s.durationMs, isrc: ids.first { $0.scheme == .isrc }?.value))
    }

    func namesOf(_ id: MusicEntityID, _ predicates: Set<MusicPredicate>) async -> [String] {
        var out: [String] = []
        for e in (try? await store.edges(of: id, predicate: nil, direction: .outgoing, limit: 100)) ?? [] where predicates.contains(e.predicate) && !e.tombstone {
            if let s = try? await store.entity(e.object) { out.append(s.name) }
        }
        return out
    }

    func enrichRecording(_ rec: MusicEntityID, _ track: TrackFacts) async -> MusicMetadataOutcome {
        var result = MusicMetadataOutcome()
        result.entity = rec
        // The (From "Film") hint becomes a provisional film below the display threshold.
        if let hint = MusicGraphAdapters.filmHint(inTitle: track.title) { await noteFilmHint(hint, recording: rec) }
        let t = now()
        if let st = try? await store.cacheState(entity: rec, facet: MusicFacet.recordingCredits, source: .musicbrainz), st.isFresh(at: t) { result.fromCache = true; return result }

        var mbid = (try? await store.externalIDs(of: rec))?.first { $0.scheme == .mbid }?.value
        if mbid == nil {
            let isrc = track.isrc
            let req = isrc.map { MusicSourceRequest(.musicbrainz, MusicFacet.recordingByISRC, ["isrc": $0]) }
                ?? MusicSourceRequest(.musicbrainz, MusicFacet.recordingSearch, ["title": MusicResolutionScoring.cleanTitle(track.title), "artist": track.artists.first ?? "",
                                                                                 "durationMs": track.durationMs.map(String.init) ?? ""])
            let f = await fetch(.musicbrainz, req, cacheEntity: rec, cacheFacet: MusicFacet.recordingCredits, result: &result)
            guard case .batch(let sb) = f else { return result }
            let scored = sb.drafts.map { d in (d, MusicResolutionScoring.recording(title: track.title, artists: track.artists, durationMs: track.durationMs, year: track.albumYear,
                                                                                    hint: MusicGraphAdapters.filmHint(inTitle: track.title) ?? track.albumTitle, language: nil, candidate: d.entity)) }
            let ranked = scored.sorted { $0.1.score > $1.1.score }
            if let (d, s) = ranked.first, case .external(_, let x) = d.ref {
                // An ISRC match is a weak id: accepted at 0.9 when one recording matches and the title is at least 0.6 similar.
                let byISRC = isrc != nil && sb.drafts.count == 1 && MusicResolutionScoring.sim(track.title, d.entity.name) >= 0.6
                if byISRC || s.decision == .merge { mbid = x.value } else {
                    try? await store.setCacheState(entity: rec, facet: MusicFacet.recordingCredits, source: .musicbrainz, outcome: .empty, ttl: 7 * 86_400, etag: nil, matcherVersion: MusicResolutionScoring.matcherVersion)
                    return result
                }
            } else {
                try? await store.setCacheState(entity: rec, facet: MusicFacet.recordingCredits, source: .musicbrainz, outcome: .empty, ttl: 7 * 86_400, etag: nil, matcherVersion: MusicResolutionScoring.matcherVersion)
                return result
            }
        }
        guard let mb = mbid, !Task.isCancelled else { result.cancelled = Task.isCancelled; return result }
        let ref = MusicDraftRef.external(.recording, ExternalID(.mbid, mb))
        let f = await fetch(.musicbrainz, MusicSourceRequest(.musicbrainz, MusicFacet.recordingCredits, ["mbid": mb]), cacheEntity: rec, result: &result)
        if let (_, rep) = await take(f, bind: [ref: rec], result: &result), rep != nil { await unifyPeople(recording: rec) }
        return result
    }

    private func noteFilmHint(_ hint: String, recording: MusicEntityID) async {
        let key = "hint|" + MusicGraphText.latin(hint)
        guard let film = try? await store.upsert(MusicEntityDraft(kind: .film, name: hint, attrs: ["hintOnly": "1"], externalIDs: [ExternalID(.canon, key)], provisional: true)) else { return }
        let edge = MusicEdge(subject: recording, predicate: .featuredIn, object: film.id, confidence: 0.4, creditLevel: .song)
        _ = try? await store.addEdge(edge, provenance: MusicProvenance(source: .matcher, retrievedAt: now(), license: .derived, score: 0.4, matcherVersion: MusicResolutionScoring.matcherVersion, evidence: ["title-hint"]))
    }

    /// Joins a provider's credited artist to the MusicBrainz person credited on the same bound recording, only on the two-signal rule: the name gates,
    /// and the shared recording plus the shared album give the two independent signals. With one signal a low-confidence `sameAs` is stored instead.
    func unifyPeople(recording: MusicEntityID) async {
        guard let performed = try? await store.edges(of: recording, predicate: .performedBy, direction: .outgoing, limit: 50) else { return }
        var sharedRelease = false
        for e in (try? await store.edges(of: recording, predicate: .trackOn, direction: .outgoing, limit: 10)) ?? [] {
            if (try? await store.edges(of: e.object, predicate: .editionOf, direction: .outgoing, limit: 2))?.isEmpty == false { sharedRelease = true }
        }
        var locals: [MusicEntitySnapshot] = [], remotes: [MusicEntitySnapshot] = []
        for e in performed where e.object.kind.isAgent && !e.tombstone {
            guard let s = try? await store.entity(e.object) else { continue }
            let ids = (try? await store.externalIDs(of: s.id)) ?? []
            if ids.contains(where: { $0.scheme == .mbid }) { remotes.append(s) } else if ids.contains(where: { $0.scheme == .provider }) { locals.append(s) }
        }
        for l in locals {
            for m in remotes where m.id != l.id {
                let ev = MusicResolutionScoring.person(nameSimilarity: MusicTransliterationKey.similarity(l.name, m.name), sharedRecording: true, sharedRelease: sharedRelease, yearA: l.year, yearB: m.year)
                switch MusicMergeRule.decide(ev) {
                case .merge:
                    let (w, lo) = l.createdAt <= m.createdAt ? (l.id, m.id) : (m.id, l.id)
                    _ = try? await store.mergeEntities(winner: w, loser: lo, byUser: false)
                case .probable:
                    guard ev.signals.contains(where: { $0.family == .name }) else { continue }
                    let sa = MusicEdge(subject: l.id, predicate: .sameAs, object: m.id, confidence: 0.6, creditLevel: .song)
                    _ = try? await store.addEdge(sa, provenance: MusicProvenance(source: .matcher, retrievedAt: now(), license: .derived, score: 0.6, matcherVersion: MusicResolutionScoring.matcherVersion, evidence: ["name", "shared-recording"]))
                case .reject: break
                }
            }
        }
    }
}
