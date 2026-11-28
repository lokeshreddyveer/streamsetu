import Foundation

// Credits as the song page shows them (items 5 to 8): singers, composer, lyricist and the rest, each name one tap from its person page.
// Pure and Foundation-only. A credit exists here only because an edge says so; a role a provider did not name is never filled in, and a person is
// never merged with another of the same name (two "Kumar Sanu"s stay two rows, told apart by what the graph knows about each).

enum MusicSongCreditGroupKind: String, CaseIterable, Sendable, Hashable {
    case singers, performers, instruments, composers, musicDirectors, lyricists, writers, arrangers, producers, others

    /// The English heading, also the localisation key.
    var titleKey: String {
        switch self {
        case .singers: "Singers"
        case .performers: "Performers"
        case .instruments: "Instruments"
        case .composers: "Composer"
        case .musicDirectors: "Music director"
        case .lyricists: "Lyricist"
        case .writers: "Writer"
        case .arrangers: "Arranger"
        case .producers: "Producer"
        case .others: "Other credits"
        }
    }

    /// Items 5, 6 and 7 first, then the rest (item 8) in a fixed order.
    static let displayOrder: [MusicSongCreditGroupKind] = [.singers, .performers, .composers, .musicDirectors, .lyricists, .writers, .arrangers, .producers, .instruments, .others]
}

struct MusicSongCreditPerson: Hashable, Sendable, Identifiable {
    var id: MusicEntityID
    var name: String
    var role: MusicRole?
    /// The instrument a provider named for an instrumentalist.
    var instrument: String?
    var status: EdgeStatus
    var confidence: Float
    var level: CreditLevel
    var order: Int?
    /// Set when another credited person on this page has the same name: what tells them apart (a birth year, a country), if the graph knows any.
    var disambiguator: String?
    /// 1-based position among the credited people who share this name, and how many there are (0 and 0 when the name is unique on the page).
    var homonymIndex: Int = 0
    var homonymCount: Int = 0
    /// Credited on the album or the film rather than on the song: shown with a quiet tag.
    var isBroaderCredit: Bool { level == .album || level == .film }

    /// The name with its disambiguator, "Kumar Sanu (b. 1957)" style text is built by the page; this is the plain concatenation.
    var displayName: String { disambiguator.map { name + " (" + $0 + ")" } ?? name }
}

struct MusicSongCreditGroup: Hashable, Sendable, Identifiable {
    var kind: MusicSongCreditGroupKind
    var people: [MusicSongCreditPerson]
    var id: String { kind.rawValue }
}

enum MusicSongCredits {
    /// One edge with what the page needs to know about the person at its far end.
    struct Row: Sendable {
        var edge: MusicEdge
        var name: String
        /// Birth year (a person) or first year (a group), when known.
        var year: Int?
        var country: String?
        var subkind: String?
        init(edge: MusicEdge, name: String, year: Int? = nil, country: String? = nil, subkind: String? = nil) {
            self.edge = edge; self.name = name; self.year = year; self.country = country; self.subkind = subkind
        }
    }

    /// Where an edge's credit lands, or nil for an edge that is not a credit this page shows.
    static func group(for e: MusicEdge) -> MusicSongCreditGroupKind? {
        let role = e.role
        switch e.predicate {
        case .performedBy:
            switch role {
            case .singer?, .featured?: return .singers
            case .instrumentalist?: return .instruments
            case .performer?, nil: return e.attributes.instrument == nil ? .performers : .instruments
            case .conductor?, .remixer?: return .others
            default: return .others
            }
        case .composedBy:
            return role == .arranger ? .arrangers : .composers
        case .musicDirectedBy: return .musicDirectors
        case .writtenBy: return role == .writer ? .writers : .lyricists
        case .producedBy: return .producers
        default: return nil
        }
    }

    /// Builds the groups from the rows. Retracted edges and edges that are not credits are dropped; one person appears once per group (the best claim);
    /// groups with nobody in them are left out; people sharing a name are told apart.
    static func build(rows: [Row]) -> [MusicSongCreditGroup] {
        var perGroup: [MusicSongCreditGroupKind: [MusicEntityID: (row: Row, person: MusicSongCreditPerson)]] = [:]
        for r in rows where !r.edge.tombstone {
            guard let g = group(for: r.edge) else { continue }
            let name = r.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let p = MusicSongCreditPerson(id: r.edge.object, name: name, role: r.edge.role, instrument: r.edge.attributes.instrument, status: r.edge.status,
                                          confidence: r.edge.confidence, level: r.edge.creditLevel, order: r.edge.order ?? r.edge.attributes.creditOrder)
            if let cur = perGroup[g]?[p.id] {
                if betterPerson(p, cur.person) { perGroup[g]?[p.id] = (r, p) }
            } else {
                perGroup[g, default: [:]][p.id] = (r, p)
            }
        }
        var groups: [MusicSongCreditGroup] = []
        for kind in MusicSongCreditGroupKind.displayOrder {
            guard let entries = perGroup[kind]?.values, !entries.isEmpty else { continue }
            let sorted = entries.map(\.person).sorted(by: personOrder)
            groups.append(MusicSongCreditGroup(kind: kind, people: sorted))
        }
        return disambiguate(groups, rows: rows)
    }

    private static func statusRank(_ s: EdgeStatus) -> Int { switch s { case .verified: 0; case .inferred: 1; case .conflicted: 2 } }

    private static func betterPerson(_ a: MusicSongCreditPerson, _ b: MusicSongCreditPerson) -> Bool {
        if statusRank(a.status) != statusRank(b.status) { return statusRank(a.status) < statusRank(b.status) }
        if a.confidence != b.confidence { return a.confidence > b.confidence }
        return a.id.rawValue < b.id.rawValue
    }

    private static func personOrder(_ a: MusicSongCreditPerson, _ b: MusicSongCreditPerson) -> Bool {
        switch (a.order, b.order) {
        case let (x?, y?) where x != y: return x < y
        case (nil, _?): return false
        case (_?, nil): return true
        default: break
        }
        if a.confidence != b.confidence { return a.confidence > b.confidence }
        if a.name != b.name { return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
        return a.id.rawValue < b.id.rawValue
    }

    /// People with the same folded name but different entity ids are marked with their index, count and whatever tells them apart.
    static func disambiguate(_ groups: [MusicSongCreditGroup], rows: [Row]) -> [MusicSongCreditGroup] {
        var facts: [MusicEntityID: Row] = [:]
        for r in rows where facts[r.edge.object] == nil { facts[r.edge.object] = r }
        var idsByName: [String: [MusicEntityID]] = [:]
        for g in groups { for p in g.people {
            let key = MusicGraphText.latin(p.name)
            if !(idsByName[key] ?? []).contains(p.id) { idsByName[key, default: []].append(p.id) }
        } }
        return groups.map { g in
            var out = g
            out.people = g.people.map { p in
                var q = p
                let same = idsByName[MusicGraphText.latin(p.name)] ?? []
                guard same.count > 1, let idx = same.sorted().firstIndex(of: p.id) else { return q }
                q.homonymIndex = idx + 1; q.homonymCount = same.count
                if let f = facts[p.id] {
                    let text = [f.year.map { String(format: "b. %d", $0) }, f.country, f.subkind].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    q.disambiguator = text.isEmpty ? nil : text
                }
                return q
            }
            return out
        }
    }

    /// The people of the groups that count as the song's singers, composers, music directors and lyricists, for the "more by" and "films" sections.
    static func people(in groups: [MusicSongCreditGroup], kinds: [MusicSongCreditGroupKind]) -> [MusicSongCreditPerson] {
        var seen = Set<MusicEntityID>(), out: [MusicSongCreditPerson] = []
        for k in kinds { for p in groups.first(where: { $0.kind == k })?.people ?? [] where seen.insert(p.id).inserted { out.append(p) } }
        return out
    }

    /// True when no group has anyone: the page then shows its one quiet line (or nothing).
    static func isEmpty(_ groups: [MusicSongCreditGroup]) -> Bool { groups.allSatisfy { $0.people.isEmpty } }
}
