import Foundation

/// Adopts the film layer (section 3 of the graph design): `MusicFilmInfo` values (from TMDB, Wikidata or the music source's own names) become claim batches,
/// and any `MusicFilmSource` can be wrapped so what it finds is also written into the graph. The film page and the actor page keep their APIs.
enum MusicFilmGraphBridge {
    static func sourceID(_ s: MusicFilmInfo.Source) -> MusicSourceID {
        switch s { case .tmdb: .tmdb; case .wikidata: .wikidata; case .provider: .jiosaavn }
    }

    /// A film with its cast, directors and composers as one batch. A person with no id is name-only: keyed by film and name, never merged by name alone.
    static func batch(from f: MusicFilmInfo, retrievedAt: Date? = nil) -> MusicClaimBatch {
        let at = retrievedAt ?? f.provenance?.retrievedAt ?? Date()
        let src = sourceID(f.source)
        var b = MusicClaimBatch(source: src, license: f.source == .tmdb ? .termsRestricted : (f.source == .wikidata ? .cc0 : .providerCache), retrievedAt: at,
                                retention: f.source == .tmdb ? 30 * 86_400 : nil, attribution: f.source == .tmdb ? "TMDB" : nil)
        var ids: [ExternalID] = []
        if let t = f.tmdbID { ids.append(ExternalID(.tmdbMovie, String(t))) }
        if let w = f.wikidataID { ids.append(ExternalID(.wikidata, w)) }
        if let i = f.imdbID { ids.append(ExternalID(.imdbTitle, i)) }
        let filmKey = "film|" + MusicGraphText.latin(f.title) + "|" + (f.year.map(String.init) ?? "x")
        let filmRef: MusicDraftRef = ids.first.map { .external(.film, $0) } ?? .local(.film, filmKey)
        var fd = MusicEntityDraft(kind: .film, name: f.title, lang: f.language, year: f.year, externalIDs: ids, provisional: ids.isEmpty)
        if ids.isEmpty { fd.externalIDs = [ExternalID(.canon, filmKey)] }
        b.drafts.append(MusicSourceDraft(filmRef, fd))
        let conf = Float(f.provenance?.confidence ?? 0.9)
        func add(_ people: [MusicFilmPerson], _ pred: MusicPredicate, _ role: MusicRole) {
            for (i, p) in people.enumerated() {
                var pid: [ExternalID] = []
                if let t = p.tmdbID { pid.append(ExternalID(.tmdbPerson, String(t))) }
                if let w = p.wikidataID { pid.append(ExternalID(.wikidata, w)) }
                if let n = p.imdbID { pid.append(ExternalID(.imdbName, n)) }
                var d = MusicEntityDraft(kind: .person, name: p.name, externalIDs: pid, provisional: pid.isEmpty)
                let ref: MusicDraftRef
                if let first = pid.first { ref = .external(.person, first) }
                else { let k = "film-person|" + filmKey + "|" + MusicGraphText.latin(p.name); ref = .local(.person, k); d.externalIDs = [ExternalID(.canon, k)]; d.attrs["nameOnly"] = "1" }
                if !b.drafts.contains(where: { $0.ref == ref }) { b.drafts.append(MusicSourceDraft(ref, d)) }
                if let photo = p.photoURL { b.imageHints[ref] = photo }
                var a = EdgeAttributes(); if pred == .hasCast { a.characterName = p.character; a.creditOrder = i }
                var c = MusicClaimDraft(subject: filmRef, predicate: pred, object: ref, role: role, attributes: a, order: pred == .hasCast ? i : nil, creditLevel: .film,
                                        confidence: src == .jiosaavn ? min(conf, 0.6) : conf, evidence: [src.rawValue + "-film-layer"])
                if f.source == .tmdb { c.attribution = "TMDB" }
                b.claims.append(c)
            }
        }
        add(f.cast, .hasCast, .actor); add(f.directors, .directedBy, .director); add(f.composers, .composedBy, .composer)
        return b
    }
}

/// A `MusicFilmSource` that passes everything through and also writes the film into the graph. Put around each source of `MusicFilmService`:
/// the film page gets the same answer as before, the graph gets the edges. A graph failure never changes the answer.
struct MusicGraphWritingFilmSource: MusicFilmSource {
    var base: any MusicFilmSource
    var resolver: MusicEntityResolver
    var source: MusicFilmInfo.Source { base.source }

    func film(for identity: MusicFilmIdentity) async throws -> MusicFilmInfo? {
        guard let info = try await base.film(for: identity) else { return nil }
        let batch = MusicFilmGraphBridge.batch(from: info)
        Task.detached(priority: .utility) { [resolver] in _ = try? await resolver.ingest(batch) }
        return info
    }

    /// The film layer's sources, each wrapped. Pass the result as `MusicFilmService(sources:)`.
    static func wrap(_ sources: [any MusicFilmSource], resolver: MusicEntityResolver) -> [any MusicFilmSource] {
        sources.map { MusicGraphWritingFilmSource(base: $0, resolver: resolver) }
    }
}
