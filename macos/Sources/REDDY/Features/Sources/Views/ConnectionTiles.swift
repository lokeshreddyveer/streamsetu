import SwiftUI

/// One way of connecting, as offered on the welcome screen and in the Add Source sheet. A tile covers one or more connection
/// kinds; a tile with several (media servers, tuners) shows a small chooser between them in the form.
struct ConnectionTile: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let kinds: [AddSourceKind]

    private static let all: [ConnectionTile] = [
        ConnectionTile(id: "link", title: "Playlist link", subtitle: "An M3U or M3U8 address", symbol: "link", kinds: [.m3uURL]),
        ConnectionTile(id: "xtream", title: "Xtream Codes", subtitle: "Server, user name and password", symbol: "person.badge.key", kinds: [.xtream]),
        ConnectionTile(id: "media", title: "Media server", subtitle: "Plex, Jellyfin or Emby", symbol: "server.rack", kinds: [.plex, .jellyfin, .emby]),
        ConnectionTile(id: "tuner", title: "TV tuner or receiver", subtitle: "HDHomeRun, TVHeadend or Enigma2", symbol: "antenna.radiowaves.left.and.right",
                       kinds: [.hdhomerun, .tvheadend, .enigma2]),
        ConnectionTile(id: "file", title: "Playlist file", subtitle: "An M3U file on this device", symbol: "doc.text", kinds: [.m3uFile]),
        ConnectionTile(id: "stalker", title: "Stalker portal", subtitle: "Portal address and MAC", symbol: "tv.and.mediabox", kinds: [.stalker]),
        ConnectionTile(id: "stream", title: "Single stream", subtitle: "One stream address", symbol: "play.rectangle", kinds: [.stream]),
    ]

    /// The tiles for the connection kinds this build offers, in reading order.
    static var offered: [ConnectionTile] {
        all.compactMap { tile in
            let kinds = tile.kinds.filter { AddSourceKind.offered.contains($0) }
            return kinds.isEmpty ? nil : ConnectionTile(id: tile.id, title: tile.title, subtitle: tile.subtitle, symbol: tile.symbol, kinds: kinds)
        }
    }

    /// How the tile's icon moves when the tile is hovered or focused.
    var iconMotion: StartIconMotion {
        switch id {
        case "media", "stalker": .pulse
        case "tuner": .ripple
        default: .bounce
        }
    }

    /// The tile that holds a kind, so a pasted address or a link opens the right one.
    static func tile(for kind: AddSourceKind) -> ConnectionTile {
        all.first { $0.kinds.contains(kind) } ?? all[0]
    }
}

/// The grid of tiles: two columns, three when there is room. Each tile fades in a little after the one before it.
struct ConnectionTileGrid: View {
    var tiles = ConnectionTile.offered
    let onChoose: (ConnectionTile) -> Void
    @FocusState private var focused: String?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
            ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                ConnectionTileButton(tile: tile, focused: focused == tile.id, appearDelay: 0.08 + Double(index) * 0.04) { onChoose(tile) }
                    .focused($focused, equals: tile.id)
                    .startRiseIn(delay: 0.08 + Double(index) * 0.04)
            }
        }
    }
}

private struct ConnectionTileButton: View {
    let tile: ConnectionTile
    let focused: Bool
    let appearDelay: Double
    let action: () -> Void
    @State private var hovering = false
    /// Bumped once shortly after the tile appears, so each icon moves once as the grid fades in.
    @State private var greeted = 0
    @Environment(\.startBranded) private var branded

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                StartIconTile(symbol: tile.symbol, motionKind: tile.iconMotion, active: hovering || focused, trigger: greeted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tile.title.loc).font(.system(size: 14, weight: .semibold)).foregroundStyle(StartStyle.textPrimary)
                    Text(tile.subtitle.loc).font(.system(size: 12)).foregroundStyle(StartStyle.textSecondary(branded))
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StartStyle.textSecondary(branded).opacity(hovering || focused ? 1 : 0.5))
                    .offset(x: hovering || focused ? 2 : 0)
                    .animation(.easeOut(duration: 0.12), value: hovering || focused)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 74, maxHeight: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: StartStyle.radius, style: .continuous))
            .startSurface(hovered: hovering, focused: focused)
        }
        .buttonStyle(.brandPress)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .startPointingHand()
        .accessibilityLabel(Text(tile.title.loc))
        .accessibilityHint(Text(tile.subtitle.loc))
        .task {
            try? await Task.sleep(nanoseconds: UInt64((appearDelay + 0.35) * 1_000_000_000))
            greeted += 1
        }.atlas("control.addSource.type")
    }
}
