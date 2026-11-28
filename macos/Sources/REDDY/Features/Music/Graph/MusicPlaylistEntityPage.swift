import SwiftUI

/// A playlist found through the graph (a "playlist contains song" edge) opens the real playlist page: the entity's own source id says which playlist it is.
/// An entity with no such id has no page to show, and the page says so instead of drawing a header with nothing under it.
struct MusicPlaylistEntityPage: View {
    let hub: MusicHub
    let entity: MusicEntityID
    @State private var playlist: MusicPlaylist?
    @State private var lookedUp = false

    var body: some View {
        Group {
            if let playlist {
                MusicPlaylistPage(hub: hub, playlist: playlist).id(playlist.uid)
            } else if lookedUp {
                MusicEmptyState(symbol: "music.note.list", title: Localized.string("This playlist is not available right now."))
            } else {
                MusicLoadingIcon(size: MusicIconSize.small).frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .task(id: entity.rawValue) {
            playlist = await Self.resolve(entity)
            lookedUp = true
        }
    }

    /// The provider playlist behind a graph playlist: its `provider:id` source id and its name.
    static func resolve(_ id: MusicEntityID, store: any MusicGraphStoring = MusicGraphRuntime.shared.store) async -> MusicPlaylist? {
        guard let ids = try? await store.externalIDs(of: id) else { return nil }
        for x in ids where x.scheme == .provider {
            guard let (provider, pid) = MusicFilmSongRules.split(providerUID: x.value) else { continue }
            let name = (try? await store.entity(id))?.name ?? ""
            return MusicPlaylist(id: pid, providerID: provider, name: name)
        }
        return nil
    }
}
