import Foundation

extension HomeFeed {
    /// The feed as it is drawn: songs, artists and albums marked Never Play leave at once, a mix or list left too short goes, and a section that was
    /// emptied by that goes. The `.graph` section (films and people) is built by its own block and has no items on purpose, so it always stays.
    /// With `localPlaylist`, a card of the person's own playlist is read again from the library (its name and count may have changed), and goes when the
    /// playlist was deleted or emptied (the lookup answers nil).
    static func rendered(_ feed: HomeFeed, trackBlocked: @escaping (MusicTrack) -> Bool, artistBlocked: @escaping (MusicArtistRef) -> Bool,
                         localPlaylist: ((UUID) -> HomeItem?)? = nil) -> HomeFeed {
        var feed = feed
        let blocked: (HomeItem) -> Bool = { $0.isBlocked(track: trackBlocked, artist: artistBlocked) }
        if let localPlaylist {
            let current: (HomeItem) -> HomeItem? = { item in
                guard let id = item.localPlaylistID else { return item }
                return localPlaylist(id)
            }
            feed.sections = feed.sections.compactMap { section in
                guard section.kind != .graph else { return section }
                var s = section
                let before = s.items.count
                s.items = s.items.compactMap(current)
                // A shelf of playlists that lost one (deleted or emptied) and fell under the minimum is not shown with one or two tiles.
                if s.items.count < before, s.items.count < HomeEngine.minItems { return nil }
                return s.items.isEmpty ? nil : s
            }
            if let h = feed.hero {
                if let item = current(h.item) { feed.hero?.item = item } else { feed.hero = nil }
            }
        }
        feed.sections = feed.sections.compactMap { section in
            guard section.kind != .graph else { return section }
            var s = section
            let before = s.items.count
            s.items = s.items.filter { !blocked($0) }
            s.items = s.items.compactMap { item in
                guard item.kind == .mix, !item.mixTracks.isEmpty else { return item }
                var i = item
                i.mixTracks = item.mixTracks.filter { !trackBlocked($0) }
                return i.mixTracks.count >= HomeMixes.minTracks ? i : nil
            }
            // A shelf that lost songs and fell under the page's minimum is not shown with one or two tiles (the same rule Hide recommendation applies).
            if s.items.count < before, s.items.count < HomeEngine.minItems { return nil }
            return s.items.isEmpty ? nil : s
        }
        if let h = feed.hero, blocked(h.item) { feed.hero = nil }
        let topBefore = feed.topTracks.count
        feed.topTracks = feed.topTracks.filter { !trackBlocked($0) }
        if feed.topTracks.count < topBefore, feed.topTracks.count < HomeEngine.topTracksMin { feed.topTracks = [] }
        return feed
    }
}
