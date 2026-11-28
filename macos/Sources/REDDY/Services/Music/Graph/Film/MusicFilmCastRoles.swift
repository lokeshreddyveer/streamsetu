import Foundation

/// Lead and supporting cast, from the billing order a source states (TMDB's `order`). Nothing is guessed: with no stated order there is no split.
enum MusicFilmCastRoles {
    /// The top-billed this many are the lead cast.
    static let leadCount = 5

    struct Split: Equatable, Sendable { var lead: [MusicFilmPersonItem]; var supporting: [MusicFilmPersonItem] }

    /// Splits the cast (already in billing order). Nil when no one has a stated order, or when either side would be empty, so the page keeps one shelf.
    static func split(_ cast: [MusicFilmPersonItem]) -> Split? {
        guard cast.contains(where: { $0.order != nil }) else { return nil }
        let lead = cast.filter { ($0.order ?? Int.max) < leadCount }
        let rest = cast.filter { ($0.order ?? Int.max) >= leadCount }
        guard !lead.isEmpty, !rest.isEmpty else { return nil }
        return Split(lead: lead, supporting: rest)
    }

    /// A kind of appearance the source's own character text states, such as "Simba (voice)" or "Doctor (cameo)". Only stated words count; a character with none of them has no kind.
    enum Appearance: String, CaseIterable, Sendable { case voice, narrator, cameo, child }

    static func appearance(character: String?) -> Appearance? {
        let t = (character ?? "").lowercased()
        guard !t.isEmpty else { return nil }
        if t.contains("(voice") || t.hasSuffix(" voice") || t.contains("voice of") || t.contains("voice only") { return .voice }
        if t.contains("narrator") || t.contains("(narration") { return .narrator }
        if t.contains("cameo") || t.contains("special appearance") || t.contains("guest") { return .cameo }
        if t.contains("child") && (t.contains("(") || t.hasPrefix("child")) || t.contains("young ") && t.contains("(child") { return .child }
        return nil
    }

    struct Partition: Equatable, Sendable { var main: [MusicFilmPersonItem]; var byAppearance: [(Appearance, [MusicFilmPersonItem])]
        static func == (a: Partition, b: Partition) -> Bool { a.main == b.main && a.byAppearance.map { $0.0 } == b.byAppearance.map { $0.0 } && a.byAppearance.map { $0.1 } == b.byAppearance.map { $0.1 } }
    }

    /// Moves everyone whose character text states a voice, narrator, cameo or child role out of the main cast into their own group, in a fixed order.
    static func partition(_ cast: [MusicFilmPersonItem]) -> Partition {
        var main: [MusicFilmPersonItem] = []
        var by: [Appearance: [MusicFilmPersonItem]] = [:]
        for p in cast { if let a = appearance(character: p.character) { by[a, default: []].append(p) } else { main.append(p) } }
        return Partition(main: main, byAppearance: Appearance.allCases.compactMap { a in by[a].map { (a, $0) } })
    }
}
