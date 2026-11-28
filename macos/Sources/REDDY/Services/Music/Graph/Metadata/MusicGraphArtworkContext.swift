import Foundation

/// What the artwork resolver reads from the music graph: external ids, jobs, works and covers it already holds, and the related things whose picture can
/// stand in. Read only. Every call is bounded (a handful of edge reads) and a failed read just means "nothing known".
struct MusicGraphArtworkContext: MusicArtworkGraphContext {
    let store: any MusicGraphStoring

    private static let creditPredicates: [MusicPredicate] = [.performedBy, .composedBy, .musicDirectedBy, .writtenBy, .directedBy, .hasCast]

    func enrich(_ s: MusicArtworkSubject) async -> MusicArtworkSubject {
        guard let wanted = s.id else { return s }
        let id = (try? await store.resolve(wanted)) ?? wanted
        guard let snap = try? await store.entity(id) else { return s }
        var out = s
        out.id = snap.id
        if out.year == nil { out.year = snap.year }
        let known = Set(out.externalIDs)
        out.externalIDs += ((try? await store.externalIDs(of: snap.id)) ?? []).filter { !known.contains($0) }
        if snap.kind.isAgent {
            let (roles, works) = await creditSummary(of: snap.id)
            if out.roles.isEmpty { out.roles = roles }
            if out.works.isEmpty { out.works = works }
        } else if out.creator == nil {
            out.creator = await creatorLine(of: snap.id)
        }
        return out
    }

    func storedAddress(for s: MusicArtworkSubject) async -> String? {
        guard let id = s.id, let snap = try? await store.entity(id) else { return nil }
        return MusicArtworkMatch.address(fromImageRef: snap.imageRef)
    }

    func related(to s: MusicArtworkSubject) async -> [MusicArtworkRelation] {
        guard let id = s.id else { return [] }
        var ids: [MusicEntityID] = []
        func add(_ predicate: MusicPredicate, _ direction: MusicEdgeDirection, limit: Int, kinds: Set<MusicEntityKind>? = nil) async {
            let edges = (try? await store.edges(of: id, predicate: predicate, direction: direction, limit: limit)) ?? []
            for e in edges {
                let other = direction == .incoming ? e.subject : e.object
                if (kinds?.contains(other.kind) ?? true), !ids.contains(other) { ids.append(other) }
            }
        }
        switch s.kind {
        case .film, .series: await add(.soundtrackOf, .incoming, limit: 6)
        case .recording, .track, .work:
            await add(.trackOn, .outgoing, limit: 4)
            await add(.featuredIn, .outgoing, limit: 2)
        case .album, .release:
            await add(.soundtrackOf, .outgoing, limit: 2)
            await add(.trackOn, .incoming, limit: 4)
        case .playlist: await add(.playlistContains, .outgoing, limit: 6)
        case .genre: await add(.hasGenre, .incoming, limit: 12, kinds: [.album, .film])
        case .language: await add(.inLanguage, .incoming, limit: 12, kinds: [.album, .film])
        case .era: await add(.ofEra, .incoming, limit: 12, kinds: [.album, .film])
        case .region: await add(.fromRegion, .incoming, limit: 12, kinds: [.album, .film])
        case .person, .group, .station: return []
        }
        var out: [MusicArtworkRelation] = []
        for other in ids.prefix(MusicEntityArtworkResolver.maxRelations + 3) {
            guard let snap = try? await store.entity(other) else { continue }
            out.append(MusicArtworkRelation(subject: MusicArtworkSubject(kind: snap.kind, name: snap.name, id: snap.id, year: snap.year), label: snap.name))
        }
        return out
    }

    // MARK: pieces

    /// The jobs a person has and a few titles of what they made, from the edges that point at them.
    private func creditSummary(of id: MusicEntityID) async -> (roles: [MusicArtworkRole], works: [String]) {
        var roles: [MusicArtworkRole] = []
        var works: [String] = []
        var looked = 0
        for p in Self.creditPredicates {
            let edges = (try? await store.edges(of: id, predicate: p, direction: .incoming, limit: 8)) ?? []
            guard let first = edges.first else { continue }
            let fallback: MusicRole? = {
                switch p { case .performedBy: .singer; case .composedBy, .musicDirectedBy: .musicDirector; case .writtenBy: .lyricist; case .directedBy: .director; case .hasCast: .actor; default: nil }
            }()
            if let role = MusicRole(rawValue: first.qualifier) ?? fallback, let r = MusicArtworkRole(role: role), !roles.contains(r) { roles.append(r) }
            for e in edges where works.count < 4 && looked < 8 {
                guard e.subject.kind == .film || e.subject.kind == .album else { continue }
                looked += 1
                if let name = (try? await store.entity(e.subject))?.name, !works.contains(name) { works.append(name) }
            }
        }
        return (roles, works)
    }

    /// "Anirudh Ravichander" for an album, song or film: the first performer, music director or composer it points at.
    private func creatorLine(of id: MusicEntityID) async -> String? {
        var names: [String] = []
        for p in [MusicPredicate.performedBy, .musicDirectedBy, .composedBy] where names.isEmpty {
            for e in ((try? await store.edges(of: id, predicate: p, direction: .outgoing, limit: 3)) ?? []) {
                if let n = (try? await store.entity(e.object))?.name { names.append(n) }
            }
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }
}
