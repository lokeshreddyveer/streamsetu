import SwiftUI

/// What tapping a Listen Now item does. Songs and mixes play; albums, artists, playlists and films open. Everything goes through `hub.play`,
/// `hub.open` and `MusicEntityActions`, as on the other pages.
@MainActor
enum MusicHomeActions {
    static func entity(of item: HomeItem) -> MusicEntity? {
        switch item.kind {
        case .track: return item.track.map { .track($0) }
        case .album: return item.album.map { .album($0) }
        case .artist: return item.artist.map { .artist($0) }
        case .playlist:
            if let p = item.playlist { return .playlist(p) }
            if let id = item.localPlaylistID { return .playlist(MusicPlaylist(id: id.uuidString, providerID: MusicStatsRules.localProviderID, name: item.title, thumbnails: item.thumbnails)) }
            return nil
        case .mix, .entity: return nil
        }
    }

    /// The tap on a tile.
    static func tap(_ item: HomeItem, queue: [MusicTrack], hub: MusicHub) {
        MusicDebugLog.log("home", "tile tapped: \(item.kind.rawValue) '\(item.title)'")
        switch item.kind {
        case .track:
            guard let t = item.track else { return }
            if let i = queue.firstIndex(where: { $0.uid == t.uid }) { hub.play(queue, at: i) } else { hub.play([t], at: 0) }
        case .mix: playMix(item, hub: hub)
        default: open(item, hub: hub)
        }
    }

    static func open(_ item: HomeItem, hub: MusicHub) {
        if item.kind == .entity, let raw = item.entityRaw, let id = MusicEntityID(rawValue: raw) { hub.open(id); return }
        guard let e = entity(of: item) else { return }
        MusicEntityActions.open(e, hub: hub)
    }

    static func play(_ item: HomeItem, hub: MusicHub) {
        MusicDebugLog.log("home", "play tapped: \(item.kind.rawValue) '\(item.title)'")
        switch item.kind {
        case .mix: playMix(item, hub: hub)
        case .entity: open(item, hub: hub)
        case .playlist where item.localPlaylistID != nil:
            if let id = item.localPlaylistID, let p = hub.library.playlist(id: id), !p.tracks.isEmpty { hub.play(p.tracks, at: 0, sourceName: p.name, sourceID: p.sourceID) }
        default:
            guard let e = entity(of: item) else { return }
            Task { await MusicEntityActions.play(e, hub: hub) }
        }
    }

    static func playMix(_ item: HomeItem, hub: MusicHub, shuffled: Bool = false) {
        guard !item.mixTracks.isEmpty else { return }
        if shuffled { hub.playShuffled(item.mixTracks, sourceName: item.title) } else { hub.play(item.mixTracks, at: 0, sourceName: item.title) }
    }

    static func startRadio(_ item: HomeItem, hub: MusicHub) {
        MusicDebugLog.log("home", "radio from \(item.kind.rawValue) '\(item.title)'")
        guard let e = entity(of: item) else { return }
        Task { await MusicEntityActions.startRadio(e, hub: hub) }
    }
}

/// A square artwork tile (round for an artist) with a title and a line under it. It wraps the shared card, so the hover stroke, the play disc, the
/// context menu and the drag are the same as everywhere; a mix, which has no page of its own, gets the same look and a play disc of its own.
struct MusicHomeTile: View {
    let item: HomeItem
    let hub: MusicHub
    var width: CGFloat? = MusicCardGeometry.defaultWidth
    /// The songs a song tile plays from (the shelf it sits on).
    var queue: [MusicTrack] = []

    var body: some View {
        switch item.kind {
        case .mix: MusicHomeMixTile(item: item, hub: hub, width: width)
        default:
            MusicCard(title: item.title, subtitle: item.subtitle.isEmpty ? nil : item.subtitle, thumbs: item.kind == .artist ? MusicArtistPortrait.portraits(item.thumbnails) : item.thumbnails,
                      round: item.kind == .artist, width: width, entity: MusicHomeActions.entity(of: item), hub: hub,
                      // a song's Play disc plays from the shelf, like the tile itself
                      playAction: item.kind == .track ? { MusicHomeActions.tap(item, queue: queue, hub: hub) } : nil) {
                MusicHomeActions.tap(item, queue: queue, hub: hub)
            }
            .atlas("control.music.homeTile")
        }
    }
}

/// A mix: the cover of its first song, its name, its artists. Tap or the disc plays it; the menu plays it shuffled, next or in the queue.
private struct MusicHomeMixTile: View {
    let item: HomeItem
    let hub: MusicHub
    var width: CGFloat?
    @State private var hovering = false
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MusicCard(title: item.title, subtitle: item.subtitle.isEmpty ? nil : item.subtitle, thumbs: item.thumbnails, width: width, entity: nil, hub: hub) {
            MusicHomeActions.tap(item, queue: [], hub: hub)
        }
        .overlay(alignment: .top) {
            // sized by the card's own width: a square that fits, never fills
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    Button { MusicHomeActions.playMix(item, hub: hub) } label: {
                        Image(systemName: "play.fill").font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.onAccent(accent))
                            .frame(width: MusicTokens.hitTarget + MusicSpace.xs, height: MusicTokens.hitTarget + MusicSpace.xs)
                            .background(accent, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(MusicSpace.sm)
                    .opacity(hovering ? 1 : 0).allowsHitTesting(hovering)
                    .accessibilityLabel(Localized.string("Play %@", item.title)).atlas("control.music.homeTilePlay")
                }
        }
        .onHover { hovering = $0 }
        .musicAnimation(.hover, reduce: reduceMotion, value: hovering)
        .contextMenu {
            Button(Localized.string("Play"), systemImage: "play.fill") { MusicHomeActions.playMix(item, hub: hub) }.atlas("control.music.homeMixPlay")
            Button(Localized.string("Shuffle"), systemImage: "shuffle") { MusicHomeActions.playMix(item, hub: hub, shuffled: true) }.atlas("control.music.homeMixShuffle")
            Button(Localized.string("Play next"), systemImage: "text.insert") { if hub.player.playNext(item.mixTracks, from: item.title) { MusicToasts.shared.success(Localized.string("Playing next.")) } }.atlas("control.music.homeMixPlayNext")
            Button(Localized.string("Add to queue"), systemImage: "text.append") { if hub.player.enqueue(item.mixTracks, from: item.title) { MusicToasts.shared.success(Localized.string("Added to the queue.")) } }.atlas("control.music.homeMixQueue")
        }
        .atlas("control.music.homeTile")
    }
}
