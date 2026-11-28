import Foundation

// Opening the film page from the film layer's own values (the album page's film panel): which entity is that film in the graph? The id comes from
// the film's strong ids first (TMDB, Wikidata, IMDb), then from the graph's alias table, and only then from a derived id.

enum MusicFilmPageRouting {
    /// The film's external ids in the order they are tried.
    static func externalIDs(for info: MusicFilmInfo) -> [ExternalID] {
        var ids: [ExternalID] = []
        if let t = info.tmdbID { ids.append(ExternalID(.tmdbMovie, String(t))) }
        if let w = info.wikidataID, !w.isEmpty { ids.append(ExternalID(.wikidata, w)) }
        if let i = info.imdbID, !i.isEmpty { ids.append(ExternalID(.imdbTitle, i)) }
        return ids
    }

    /// The title-and-year key a film with no external id is written under (the same text `MusicFilmGraphBridge.batch` builds), so every path mints one entity.
    static func canonKey(title: String, year: Int?) -> String { "film|" + MusicGraphText.latin(title) + "|" + (year.map(String.init) ?? "x") }

    /// The ids a film is written under: its strong ids, else the canon id of its title and year.
    static func writeIDs(for info: MusicFilmInfo) -> [ExternalID] {
        let ids = externalIDs(for: info)
        return ids.isEmpty ? [ExternalID(.canon, canonKey(title: info.title, year: info.year))] : ids
    }

    /// The graph entity of a film the film layer found. A film already in the graph under any of its ids is that entity (so a film first seen through
    /// Wikidata is found by its TMDB id too); otherwise the id the graph will give it when the film is written. Two films of one title and different
    /// years stay two (the name-only fallback carries the year).
    static func filmID(for info: MusicFilmInfo, store: any MusicGraphStoring) async -> MusicEntityID {
        let ids = externalIDs(for: info)
        for id in ids {
            if let found = try? await store.resolveAlias(for: id, kind: .film) { return found }
        }
        if let first = ids.first { return .provisional(kind: .film, externalID: first) }
        if ids.isEmpty, let found = try? await store.resolveAlias(for: ExternalID(.canon, canonKey(title: info.title, year: info.year)), kind: .film) { return found }
        return .provisional(kind: .film, name: info.title, year: info.year)
    }
}

extension MusicFilmPageRouting {
    /// The graph person of a film-layer person, found by a strong id (TMDB, Wikidata, IMDb) and never by name. Nil for a name-only person.
    static func personID(for p: MusicFilmPerson, store: any MusicGraphStoring) async -> MusicEntityID? {
        for id in personExternalIDs(p) {
            if let found = try? await store.resolveAlias(for: id, kind: .person) { return found }
        }
        return nil
    }

    static func personExternalIDs(_ p: MusicFilmPerson) -> [ExternalID] {
        var ids: [ExternalID] = []
        if let t = p.tmdbID { ids.append(ExternalID(.tmdbPerson, String(t))) }
        if let w = p.wikidataID, !w.isEmpty { ids.append(ExternalID(.wikidata, w)) }
        if let i = p.imdbID, !i.isEmpty { ids.append(ExternalID(.imdbName, i)) }
        return ids
    }
}
