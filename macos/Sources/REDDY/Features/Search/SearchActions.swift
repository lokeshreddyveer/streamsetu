import Foundation

/// What choosing a search result does. Choosing is an explicit navigation, so it may change the tab; merely searching never does.
@MainActor
enum SearchActions {
    static func perform(_ r: SearchResult, container c: AppContainer, router: AppRouter, state: AppState) {
        switch r.destination {
        case .playChannel(let id), .programme(let id):
            guard let ch = try? c.catalog.channel(id: id) else { return }
            useFor(ch.sourceID, state)                              // switching playlists stops the old one, then this starts
            router.navigate(.liveTV, .shortcut(.allChannels))
            c.playback.play(channel: ch, queue: [ch])
        case .movie(let id):
            if let m = try? c.catalog.movie(id: id) { router.open(movie: m) }
        case .series(let id), .episode(_, let id):
            if let s = try? c.catalog.seriesItem(id: id) { router.open(series: s) }
        case .folder(let categoryID, let kind):
            useFor(r.sourceID, state)
            router.openFolder(kind == .channel ? .liveTV : kind == .movie ? .movies : .series, categoryID: categoryID)
        case .collection:
            router.go(.collections)
        }
    }

    private static func useFor(_ source: UUID?, _ state: AppState) {
        if let source, source != state.activeSourceID { state.switchPlaylist(source) }
    }
}
