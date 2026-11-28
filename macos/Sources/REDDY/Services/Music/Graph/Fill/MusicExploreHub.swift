import Foundation

// What the Explore screens share about a chart: `chartScopeLabel` is the one rule for labelling a country's own list apart from a worldwide one. There is no
// built-in list of people, films, languages or moods here: everything a shelf shows comes from the person's plays, the graph and the sources' own charts.

enum MusicExploreHub {
    /// "Top in India" for a list that is the country's own, "Worldwide" for one that is not: a worldwide list is never shown under a country's name.
    static func chartScopeLabel(regionName: String, isRegional: Bool, wording: MusicFillWording = .english) -> String {
        isRegional ? wording.f("Top in %@", regionName) : wording.s("Worldwide")
    }
}

/// Shelves of a facet page (language, era, region, genre): the roster's names for it first-class, then whatever the graph tags with it.
enum MusicFacetShelves {
    static func build(id: MusicEntityID, name: String, page: String, store: any MusicGraphStoring, wording: MusicFillWording = .english) async -> MusicFillResult {
        let r = MusicFillResolver(store: store, wording: wording)
        var shelves: [MusicFillShelf] = [], needs: [MusicEntityID] = []
        // what the graph itself tags with this facet (incoming edges), by kind
        let tagged = (try? await store.edges(of: id, predicate: nil, direction: .incoming, limit: 200)) ?? []
        var albums: [MusicFillTile] = [], films: [MusicFillTile] = [], songs: [MusicFillTile] = []
        for e in tagged where e.predicate == .inLanguage || e.predicate == .ofEra || e.predicate == .hasGenre || e.predicate == .fromRegion {
            switch e.subject.kind {
            case .album, .release: if let (t, n) = await r.tile(e.subject, kind: .album) { albums.append(t); if n { needs.append(t.entity) } }
            case .film, .series: if let (t, n) = await r.tile(e.subject, kind: .film) { films.append(t); if n { needs.append(t.entity) } }
            case .recording, .track, .work: if let (t, _) = await r.tile(e.subject, kind: .song) { songs.append(t) }
            default: break
            }
        }
        func graphShelf(_ sid: String, _ title: String, _ tiles: [MusicFillTile]) {
            var seen = Set<String>()
            let u = tiles.filter { seen.insert($0.id).inserted }
            if !u.isEmpty { shelves.insert(MusicFillShelf(id: "facet." + sid, title: title, reason: wording.f("Tagged %@ in your graph", name), scope: .related, tiles: u), at: 0) }
        }
        graphShelf("songs", wording.s("Songs"), songs); graphShelf("films", wording.s("Films"), films); graphShelf("albums", wording.s("Albums"), albums)
        return MusicFillResult(shelves: shelves, needsCompleteness: Array(Set(needs)).sorted())
    }
}
