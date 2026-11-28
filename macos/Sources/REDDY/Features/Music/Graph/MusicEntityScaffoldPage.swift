import SwiftUI

/// The stand-in page for the graph routes (song, album, person, film, series, station, playlist, genre, language, region, era, collections). It holds a
/// lease on the entity's shared model and shows the entity's name and type, a loading line while the row is read and a not-found line with Back when
/// the graph and the sources have nothing. The screen packages replace the body for their kind; the lease, Back and page memory stay as they are.
struct MusicEntityScaffoldPage: View {
    let hub: MusicHub
    let route: MusicEntityRoute
    @State private var lease: MusicEntityLease?

    var body: some View {
        let model = lease?.model
        MusicPageScaffold(hub: hub) {
            MusicPageHeader(title: model?.name ?? Localized.string("Loading %1$@", Self.label(for: route.page)), kind: Self.label(for: route.page),
                            subtitle: subtitle(model), subject: model?.snapshot.map { MusicArtworkSubject.derive($0) }) { EmptyView() }
            if model?.phase == .failed {
                Text(Localized.string("This %1$@ is not available right now.", Self.label(for: route.page)))
                    .font(Typography.body).foregroundStyle(ColorTokens.textSecondary)
            }
        }
        .onAppear { if lease == nil { lease = MusicEntityRuntime.shared.center.acquire(route.id) } }
        .onDisappear { lease?.release(); lease = nil }
        .atlasScreen("screen.music.entity")
    }

    private func subtitle(_ model: MusicEntityModel?) -> String {
        guard let model, let s = model.snapshot else { return "" }
        return [s.subkind, s.year.map(String.init)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func label(for page: MusicEntityPage) -> String {
        switch page {
        case .song: Localized.string("Song")
        case .album: Localized.string("Album")
        case .person: Localized.string("Person")
        case .film: Localized.string("Film")
        case .series: Localized.string("Series")
        case .station: Localized.string("Station")
        case .playlist: Localized.string("Playlist")
        case .genre: Localized.string("Genre")
        case .language: Localized.string("Language")
        case .region: Localized.string("Region")
        case .era: Localized.string("Era")
        }
    }
}

/// The stand-in for a named discovery list (composers, singers, soundtracks, classics, moods).
struct MusicCollectionScaffoldPage: View {
    let hub: MusicHub
    let key: MusicCollectionKey

    var body: some View {
        MusicPageScaffold(hub: hub) {
            MusicPageHeader(title: Self.title(for: key), kind: Localized.string("Collection")) { EmptyView() }
        }
        .atlasScreen("screen.music.collection")
    }

    static func title(for key: MusicCollectionKey) -> String {
        switch key {
        case .composers: Localized.string("Composers")
        case .singers: Localized.string("Singers")
        case .soundtracks: Localized.string("Soundtracks")
        case .classics: Localized.string("Classics")
        case .moods: Localized.string("Moods")
        case .onRepeat: Localized.string("On Repeat")
        case .recentlyAdded: Localized.string("Recently added")
        case .neverPlayed: Localized.string("Never played")
        case .forgottenFavourites: Localized.string("Forgotten favourites")
        case .mostPlayed: Localized.string("Most played")
        case .recentlyPlayed: Localized.string("Recently played")
        }
    }
}
