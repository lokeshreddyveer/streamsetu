import Foundation

// Same name, different people (section 6.9 and the research note on people identity). The graph never merges two people by name. When two distinct
// person entities share a name AND the route came from a name search, the page offers a "Did you mean" row; otherwise it stays quiet.

struct MusicPersonCandidate: Hashable, Sendable, Identifiable {
    var id: MusicEntityID
    var name: String
    var line: String?
    var imageRef: String?
    var isGroup: Bool
}

enum MusicPersonDisambiguation {
    /// The short line that tells two people of one name apart, from what the entity itself holds: a source's disambiguation text, Wikidata's
    /// description, the life years, the country. Nil when it holds none of them (the row then shows the name alone).
    static func line(for s: MusicEntitySnapshot) -> String? {
        func clean(_ t: String?) -> String? { t.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } }
        if let d = clean(s.attrs["disambiguation"]) { return d }
        if let d = clean(s.attrs["description"]) {
            if let y = s.year { return "\(d) · \(y)" }
            return d
        }
        var parts: [String] = []
        switch (s.year, s.yearEnd) {
        case let (a?, b?): parts.append("\(a)–\(b)")
        case let (a?, nil): parts.append("b. \(a)")
        case let (nil, b?): parts.append("d. \(b)")
        default: break
        }
        if let c = clean(s.country) { parts.append(c) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The other people who carry the same name as `person`: live, distinct entities of kind person or group whose folded name (original or Latin
    /// skeleton) equals the person's. Never contains `person` itself or an entity that was merged away. Ordered stably (id) so the row does not shuffle.
    /// `query` is what the person typed; without one the row does not exist (the caller passes nil when the route did not come from a name search).
    static func candidates(for person: MusicEntitySnapshot, query: String?, store: any MusicGraphStoring, limit: Int = 4) async -> [MusicPersonCandidate] {
        guard let q = query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty, person.kind.isAgent else { return [] }
        guard let hits = try? await store.search(person.name, kinds: [.person, .group], limit: 20) else { return [] }
        let skeleton = MusicGraphText.latin(person.name), folded = MusicGraphText.fold(person.name)
        var out: [MusicPersonCandidate] = []
        var seen: Set<MusicEntityID> = [person.id]
        for h in hits.sorted(by: { $0.id < $1.id }) {
            guard !seen.contains(h.id) else { continue }
            guard MusicGraphText.fold(h.name) == folded || MusicGraphText.latin(h.name) == skeleton else { continue }
            guard let snap = (try? await store.entity(h.id)) ?? nil, snap.state == .live, snap.id != person.id, snap.mergedInto == nil else { continue }
            seen.insert(h.id)
            out.append(MusicPersonCandidate(id: snap.id, name: snap.name, line: line(for: snap), imageRef: snap.imageRef, isGroup: snap.kind == .group))
            if out.count >= limit { break }
        }
        return out
    }

    /// Whether the page should draw the row: only with at least one other person of that name.
    static func shouldShowRow(_ c: [MusicPersonCandidate]) -> Bool { !c.isEmpty }
}
