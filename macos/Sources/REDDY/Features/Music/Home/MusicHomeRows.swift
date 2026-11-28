import SwiftUI

/// "Your top tracks" as a real list: eight rows, each the same height, with the cover first, one title line, one line of artist names that each open
/// the artist, the album as a link on wide windows, then the like button and the song menu at the end. The row plays the list from this song.
struct MusicHomeTopTracks: View {
    let tracks: [MusicTrack]
    let hub: MusicHub
    @Environment(\.musicLayoutClass) private var layoutClass

    var body: some View {
        let spec = MusicHomeLayout.spec(for: layoutClass)
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicSectionTitle(title: Localized.string("Your top tracks"))
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.uid) { _, t in
                    MusicHomeTrackRow(track: t, queue: tracks, hub: hub, artwork: spec.rowArtwork, showsAlbum: spec.rowShowsAlbum)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// One song row with artwork. Its height is fixed (`MusicHomeLayout.rowHeight`), so a list of them is even whatever the titles are.
struct MusicHomeTrackRow: View {
    let track: MusicTrack
    let queue: [MusicTrack]
    let hub: MusicHub
    var artwork: CGFloat = 44
    var showsAlbum = false
    @Environment(\.reddyAccent) private var accent
    @State private var hovering = false

    private var isCurrent: Bool { hub.player.current?.uid == track.uid }
    private var liked: Bool { hub.library.isLiked(track) }

    var body: some View {
        HStack(spacing: MusicSpace.sm) {
            Button(action: play) {
                MusicArtwork(track: track, size: artwork, corner: MusicCorner.control)
                    .overlay {
                        if hovering || isCurrent {
                            RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous).fill(MusicTokens.scrim).allowsHitTesting(false)
                            Image(systemName: isCurrent && hub.player.isPlaying && !hovering ? "waveform" : "play.fill").font(MusicTokens.iconSmall).foregroundStyle(MusicInk.onArtwork).allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(track.title), \(track.artistLine)").accessibilityHint(Localized.string("Plays this song"))
            .atlas("control.music.homeTopTrackRow")
            // one title line, one line of artist names; each name is its own click target, the rest of the block plays the song
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                Text(verbatim: MusicDisplayTitle.display(for: track)?.title ?? track.title)
                    .musicText(.card).foregroundStyle(isCurrent ? accent : ColorTokens.textPrimary).lineLimit(1)
                MusicTrackArtistLine(track: track, hub: hub)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { play() }.atlas("control.music.homeTopTrackText")
            if showsAlbum, let album = track.album, !album.title.isEmpty {
                MusicInlineLink(title: album.title, font: Typography.row, label: Localized.string("Open album %@", album.title), isLink: !album.id.isEmpty) { hub.open(.album(hub.album(from: album, providerID: track.providerID))) }
                    .frame(maxWidth: 220, alignment: .leading)
            }
            Button { MusicEntityActions.toggleLike(track, hub: hub) } label: {
                Image(systemName: liked ? "heart.fill" : "heart").font(MusicTokens.iconMedium).foregroundStyle(liked ? accent : ColorTokens.textSecondary)
                    .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(liked ? Localized.string("Unlike") : Localized.string("Like")).atlas("control.music.homeTopTrackLike")
            Menu { MusicTrackMenuContent(track: track, hub: hub) } label: {
                Image(systemName: "ellipsis").font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.textSecondary)
                    .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(Localized.string("More actions for %@", track.title)).atlas("control.music.homeTopTrackMore")
        }
        .padding(.horizontal, MusicSpace.xs)
        .frame(height: MusicHomeLayout.rowHeight)
        .hoverHighlight()
        .onHover { hovering = $0 }
        .contextMenu { MusicTrackMenuContent(track: track, hub: hub) }.atlas("control.music.homeTopTrackMenu")
    }

    private func play() {
        MusicDebugLog.log("home", "top track tapped: \(track.title)")
        if let i = queue.firstIndex(where: { $0.uid == track.uid }) { hub.play(queue, at: i) } else { hub.play([track], at: 0) }
    }
}
