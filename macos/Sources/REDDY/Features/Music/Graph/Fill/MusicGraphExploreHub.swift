import SwiftUI

// Collections: the smart playlists (on repeat, recently added, never played, forgotten favourites) and the discovery collections. There is no built-in list of
// people or films: a discovery collection shows only what the graph and the person's plays hold.

/// The page behind a discovery collection (composers, singers, soundtracks, classics, moods): every entry of the hub's shelves for it, as a grid.
struct MusicCollectionPage: View {
    let hub: MusicHub
    let key: MusicCollectionKey

    private var smartKind: MusicSmartKind? {
        switch key {
        case .onRepeat: .onRepeat
        case .recentlyAdded: .recentlyAdded
        case .neverPlayed: .neverPlayed
        case .forgottenFavourites: .forgottenFavourites
        case .mostPlayed: .mostPlayed
        case .recentlyPlayed: .recentlyPlayed
        default: nil
        }
    }

    var body: some View {
        if let kind = smartKind { MusicSmartPlaylistPage(hub: hub, kind: kind) } else { discovery }
    }

    private var discovery: some View {
        MusicPageScaffold(hub: hub) {
            MusicPageHeader(title: MusicCollectionScaffoldPage.title(for: key), kind: Localized.string("Collection")) { EmptyView() }
            MusicEmptyState(glyph: .note, title: Localized.string("Nothing here yet"),
                            message: Localized.string("This fills in from the music you play and the people and films your sources know."), compact: true)
        }
        .atlasScreen("screen.music.collection")
    }
}
