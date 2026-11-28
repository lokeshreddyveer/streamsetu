import Foundation

/// The "Trending" chips of the empty Search page, worked out from the chart shelves of the person's chosen region. Nothing here is a list of names:
/// every chip is taken from what the sources answered for that region, mixed so songs, artists and albums alternate, repeats dropped, capped.
enum MusicTrendingSearches {
    static let limit = 12

    struct Chip: Codable, Hashable, Sendable, Identifiable {
        enum Kind: String, Codable, Sendable { case song, artist, album }
        var kind: Kind
        /// What the chip shows.
        var title: String
        /// The artist of a song or album; empty for an artist.
        var subtitle: String = ""
        /// The words a tap searches for.
        var query: String
        /// Set for an artist or album the source named with an id: a tap then opens it instead of searching.
        var entityID: String? = nil
        var providerID: String? = nil
        var thumbnails: [MusicThumbnail] = []
        var id: String { kind.rawValue + ":" + MusicSearchRanker.normalise(title + subtitle) }
    }

    /// One song, artist or album per chip, in the order of the shelves, alternating kinds (song, artist, song, album, ...) so the block is mixed even when a chart
    /// is all songs. A kind that runs out lets the others fill the room. The same words are never shown twice, whatever the kind.
    static func build(from sections: [MusicBrowseSection], limit: Int = MusicTrendingSearches.limit) -> [Chip] {
        guard limit > 0 else { return [] }
        var queues: [Chip.Kind: [Chip]] = [.song: [], .artist: [], .album: []]
        var seenTitles = Set<String>()
        func add(_ chip: Chip) {
            let key = MusicSearchRanker.normalise(chip.title)
            guard !key.isEmpty, seenTitles.insert(key).inserted else { return }
            queues[chip.kind, default: []].append(chip)
        }
        func artist(_ name: String, id: String, providerID: String, thumbs: [MusicThumbnail]) {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty else { return }
            add(Chip(kind: .artist, title: n, query: n, entityID: id.isEmpty ? nil : id, providerID: id.isEmpty ? nil : providerID, thumbnails: thumbs))
        }
        for section in sections {
            for item in section.items {
                switch item {
                case .track(let t):
                    let title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let by = t.artists.first?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !title.isEmpty {
                        add(Chip(kind: .song, title: title, subtitle: by, query: by.isEmpty ? title : title + " " + by, thumbnails: t.thumbnails))
                    }
                    if let a = t.artists.first { artist(a.name, id: a.id, providerID: t.providerID, thumbs: a.thumbnails) }
                case .artist(let a):
                    artist(a.name, id: a.id, providerID: a.providerID, thumbs: a.thumbnails)
                case .album(let a):
                    let title = a.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let by = a.artists.first?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !title.isEmpty {
                        add(Chip(kind: .album, title: title, subtitle: by, query: by.isEmpty ? title : title + " " + by,
                                 entityID: a.id.isEmpty ? nil : a.id, providerID: a.id.isEmpty ? nil : a.providerID, thumbnails: a.thumbnails))
                    }
                case .playlist: break
                }
            }
        }
        let pattern: [Chip.Kind] = [.song, .artist, .song, .album]
        var out: [Chip] = []
        var cursor: [Chip.Kind: Int] = [:]
        while out.count < limit {
            var added = false
            for kind in pattern where out.count < limit {
                let i = cursor[kind, default: 0]
                if let list = queues[kind], i < list.count { out.append(list[i]); cursor[kind] = i + 1; added = true }
            }
            if !added { break }
        }
        return out
    }

    /// How long the chips of a region are kept in memory and on disk before they are asked for again.
    static let freshFor: TimeInterval = 3 * 3_600
    static let usableFor: TimeInterval = 6 * 3_600

    /// The key the chips of a region are saved under.
    static func cacheKey(region: String) -> String { MusicFetch.key("trendingSearches", region.isEmpty ? "world" : region) }
}
