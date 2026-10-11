import Foundation

/// Real numbers for the Library page and for each playlist: items, folders, guide, and when things last happened.
struct CatalogOverview: Equatable, Sendable {
    var playlists = 0
    var channels = 0, movies = 0, series = 0
    var categories = 0
    var lastSync: Date?
    var guideChannels = 0, guidePrograms = 0, guideMatched = 0
    var guideUpdated: Date?

    /// Live channels that have no guide data attached.
    var guideUnmatched: Int { max(0, channels - guideMatched) }
}

enum CatalogOverviewService {
    /// All enabled playlists together (sourceID nil), or one playlist.
    static func load(catalog: CatalogRepository, epg: EPGRepository, sourceID: UUID?) -> CatalogOverview {
        var o = CatalogOverview()
        let all = (try? catalog.sources()) ?? []
        let scoped = sourceID.map { id in all.filter { $0.id == id } } ?? all.filter(\.enabled)
        o.playlists = scoped.count
        for s in scoped {
            let c = (try? catalog.counts(sourceID: s.id)) ?? CatalogCounts()
            o.channels += c.channels; o.movies += c.movies; o.series += c.series
            for k in [ContentKind.channel, .movie, .series] { o.categories += (try? catalog.storedCategoryCount(sourceID: s.id, kind: k)) ?? 0 }
            if let d = s.lastSync, d > (o.lastSync ?? .distantPast) { o.lastSync = d }
            if let g = try? epg.guideCoverage(sourceID: s.id) {
                o.guideChannels += g.channels; o.guidePrograms += g.programs; o.guideMatched += g.mapped
                if let u = g.lastUpdate, u > (o.guideUpdated ?? .distantPast) { o.guideUpdated = u }
            }
        }
        return o
    }

    /// Compares what the last sync stored with what is in the tables now. A mismatch means something changed the catalog
    /// outside a sync, or a commit did not complete.
    static func consistency(catalog: CatalogRepository, source: PlaylistSource) -> (consistent: Bool, details: [String]) {
        var problems: [String] = []
        let actual = (try? catalog.counts(sourceID: source.id)) ?? CatalogCounts()
        for st in (try? catalog.syncStates(sourceID: source.id)) ?? [] where st.error == nil && st.lastSuccess != nil {
            let now: Int?
            switch st.scope { case "live": now = actual.channels; case "movies": now = actual.movies; case "series": now = actual.series; default: now = nil }
            if let now, now != st.itemCount { problems.append("\(st.scope.capitalized): last sync stored \(st.itemCount.formatted()), the catalog holds \(now.formatted())") }
        }
        return (problems.isEmpty, problems)
    }
}
