import SwiftUI

/// The Library's Artists tab shelf of the people the person marked with the heart on an artist page, newest first. A favorite is a private mark on a person of
/// the graph (apart from Follow), so this is the one place the mark is read back; the cards open the person's own page.
struct MusicFavoriteArtistsShelf: View {
    let hub: MusicHub
    private var favorites: MusicFavoriteArtists { MusicFavoriteArtists.shared }
    @State private var people: [MusicEntitySnapshot] = []
    @Environment(\.musicLayoutClass) private var layoutClass

    var body: some View {
        let ids = MusicFavoriteArtistShelfRules.ids(favorites.favorites)
        // A task on an empty view never runs, so a zero-height line always exists to hold it until there are people to show.
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if !people.isEmpty {
                MusicShelf(title: Localized.string("Favorite artists"), subtitle: Localized.string("The artists you marked with a heart. Kept on this Mac.")) {
                    ForEach(people, id: \.id) { s in
                        MusicGraphPersonCard(name: s.name, imageRef: s.imageRef, width: MusicGraphCardWidth.width(for: layoutClass), entity: s.id) { hub.open(s.id) }
                    }
                }
            }
        }
        .task(id: ids) { await load() }
    }

    private func load() async {
        await favorites.adoptMerges(in: MusicGraphRuntime.shared.store)
        var out: [MusicEntitySnapshot] = []
        for id in MusicFavoriteArtistShelfRules.ids(favorites.favorites) {
            if Task.isCancelled { return }
            if let s = (try? await MusicGraphRuntime.shared.store.entity(id)) ?? nil, s.state == .live { out.append(s) }
        }
        if !Task.isCancelled { people = out }
    }
}

enum MusicFavoriteArtistShelfRules {
    /// The favorite ids as entity ids, newest first; a stored value that is not an id any more is skipped.
    static func ids(_ set: MusicFavoriteArtistSet) -> [MusicEntityID] { set.ids.compactMap { MusicEntityID(rawValue: $0) } }
}
