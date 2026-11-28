import SwiftUI

// Now Playing details for the shell's context panel: the cover at 320 to 500 pt, the title on as many lines as it needs, the artists, the album
// and the version as links or labels, the like button, the audio quality and the output.

struct MusicNowPlayingPanel: View {
    let hub: MusicHub
    /// The shell's context panel state; the lyrics preview uses it to open the Lyrics tab.
    var panelState: MusicContextPanelState = .shared
    @State private var detailsHeight: CGFloat = MusicNowPlayingMemory.details   // the last measured height, so the first frame after a tab switch already has the right room for the lyrics preview
    @AppStorage(MusicShellKeys.nowPlayingMode) private var modeRaw = MusicNowPlayingMode.balanced.rawValue

    var body: some View {
        if let t = hub.player.current {
            GeometryReader { geo in
                    let widthSize = MusicNowPlayingMetrics.artworkSize(panelWidth: geo.size.width)
                    let art = MusicNowPlayingSizing.coverSize(widthSize: widthSize, panelHeight: geo.size.height, mode: MusicNowPlayingMode.decode(modeRaw))
                    let room = MusicLyricsPreviewLogic.previewHeight(panelHeight: geo.size.height, detailsHeight: detailsHeight,
                                                                     verticalPadding: MusicSpace.md, gap: MusicSpace.sm)
                    // This panel only draws on the Now Playing tab, so the Lyrics tab is never open beside it.
                    let showsPreview = MusicLyricsPreviewLogic.isVisible(availableHeight: room, lyricsTabShowing: false)
                    ScrollView {
                        VStack(spacing: MusicSpace.sm) {
                            MusicNowPlayingDetails(hub: hub, track: t, artworkSize: art)
                                .background(GeometryReader { g in Color.clear.preference(key: MusicNowPlayingDetailsHeightKey.self, value: g.size.height) })
                            MusicStationRow(hub: hub).frame(width: art)
                            MusicNowPlayingContext(hub: hub, panelState: panelState).frame(width: art)
                            if showsPreview, let room { MusicLyricsPreview(hub: hub, panelState: panelState).frame(width: art, height: room) }
                            SoundCloudChaptersSection(hub: hub)
                        }
                        .padding(.vertical, MusicSpace.md)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.hidden)
                    .onPreferenceChange(MusicNowPlayingDetailsHeightKey.self) { if abs($0 - detailsHeight) > 0.5 { detailsHeight = $0; MusicNowPlayingMemory.details = $0 } }
            }
            .musicFocusRegion(Localized.string("Now playing"))
        }
    }
}

private struct MusicNowPlayingDetailsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The details column. `artworkSize` is the edge of the cover and the width of the column.
struct MusicNowPlayingDetails: View {
    let hub: MusicHub
    let track: MusicTrack
    let artworkSize: CGFloat
    @Environment(\.reddyAccent) private var accent
    @State private var showCover = false
    @State private var audioSettings = false
    @AppStorage(MusicShellKeys.nowPlayingMode) private var modeRaw = MusicNowPlayingMode.balanced.rawValue

    var body: some View {
        let t = track
        VStack(spacing: MusicSpace.sm) {
            // The cover opens the full player; its menu has the large view, the album and the artwork choices.
            Button { hub.expandedPlayer = true } label: {
                MusicBarArtwork(thumbs: t.thumbnails, size: artworkSize, artworkClass: .nowPlaying, corner: MusicCorner.cardLarge, track: t)
                    .musicElevation(.floating, cornerRadius: MusicCorner.cardLarge)
            }
            .buttonStyle(.plain).accessibilityLabel(Localized.string("Open the full player")).musicTooltip("Open the full player")
            .contextMenu { artworkMenu(t) }
            .atlas("control.music.nowPlayingArtwork")
            .sheet(isPresented: $showCover) { MusicAlbumCoverViewer(thumbs: t.thumbnails, title: t.title) { showCover = false } }
            HStack(alignment: .top, spacing: MusicSpace.xs) {
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    // A song page exists only when the connected pages are on, and not for a file of the person's own or a podcast episode: then the title is plain text (a
                    // disabled button would draw it greyed out, as if something were wrong).
                    let titleText = Text(verbatim: MusicDisplayTitle.display(for: t)?.title ?? t.title).font(Typography.title).lineLimit(4).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    if MusicGraphKeys.pagesOn && t.providerID != MusicStatsRules.localProviderID && t.isPodcast != true {
                        Button { hub.open(MusicFillRuntime.songID(t)) } label: { titleText }
                            .help(MusicDisplayTitle.display(for: t)?.raw ?? "")
                            .buttonStyle(.plain).accessibilityAddTraits(.isHeader).accessibilityLabel(Localized.string("Go to song %@", t.title)).atlas("control.music.nowPlayingTitleLink")
                    } else {
                        titleText.accessibilityAddTraits(.isHeader).help(MusicDisplayTitle.display(for: t)?.raw ?? "")
                    }
                    artists(t)
                    if let a = t.album {
                        if !a.hasPage {
                            Text(verbatim: a.title).font(MusicTypeRole.caption.font).foregroundStyle(ColorTokens.textTertiary).lineLimit(2).multilineTextAlignment(.leading)
                        } else {
                            Button { hub.open(.album(MusicLinks.album(a, providerID: t.providerID))) } label: {
                                Text(verbatim: a.title).font(MusicTypeRole.caption.font).foregroundStyle(ColorTokens.textTertiary).lineLimit(2).multilineTextAlignment(.leading)
                            }
                            .buttonStyle(.plain).accessibilityLabel(Localized.string("Go to album %@", a.title)).atlas("control.music.playerAndQueueGoToAlbum")
                        }
                    }
                    versions(t)
                    MusicTrackLinkStrip(track: t, hub: hub)
                }
                .frame(maxWidth: MusicNowPlayingMetrics.headerTitleMaxWidth(headerWidth: artworkSize), alignment: .leading)
                likeButton(t)
                Spacer(minLength: 0)
                trackMenu(t).frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget)
            }
            .frame(width: artworkSize)
            MusicRadioThumbs(hub: hub, track: t, showsTired: true)
            MusicNowPlayingControls(hub: hub, duration: t.duration).frame(width: artworkSize)
            HStack(spacing: MusicSpace.xs) {
                MusicQualityButton(hub: hub)
                Spacer(minLength: 0)
                MusicOutputControl(hub: hub)
            }
            .frame(width: artworkSize)
        }
    }

    /// Each real artist is its own link; credits without an id and compilations stay plain text (the shared rule every other surface uses).
    private func artists(_ t: MusicTrack) -> some View {
        MusicTrackArtistLine(track: t, hub: hub, font: MusicTypeRole.body.font)
    }

    @ViewBuilder private func versions(_ t: MusicTrack) -> some View {
        let labels = MusicNowPlayingMetrics.versionLabels(t)
        if !labels.isEmpty {
            HStack(spacing: MusicSpace.xs - 2) {
                ForEach(labels, id: \.self) { l in
                    Text(verbatim: l).font(MusicTypeRole.micro.font).foregroundStyle(ColorTokens.textTertiary)
                        .padding(.horizontal, MusicSpace.xs - 2).padding(.vertical, MusicSpace.xxs / 2)
                        .overlay(Capsule().strokeBorder(ColorTokens.line))
                }
            }
        }
    }

    private func likeButton(_ t: MusicTrack) -> some View {
        let liked = hub.library.isLiked(t)
        return Button { hub.library.toggleLike(t) } label: {
            MusicHeartIcon(filled: liked, size: MusicIconSize.control)
                .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(liked ? MusicA11yLabels.unlike : MusicA11yLabels.like).accessibilityAddTraits(liked ? .isSelected : [])
        .musicTooltip(verbatim: liked ? MusicA11yLabels.unlike : MusicA11yLabels.like)
        .atlas("control.music.playerAndQueueMusicnowplayingpaneldetailsButton")
    }

    /// The cover's right-click menu.
    @ViewBuilder private func artworkMenu(_ t: MusicTrack) -> some View {
        Button("View artwork", systemImage: "photo") { showCover = true }.atlas("control.music.nowPlayingViewArtwork")
        if let a = t.album, a.hasPage {
            Button("Go to Album", systemImage: "square.stack") { hub.open(.album(MusicLinks.album(a, providerID: t.providerID))) }.atlas("control.music.playerAndQueueGoToAlbum")
        }
        Button("Open Full Window", systemImage: "arrow.up.left.and.arrow.down.right") { hub.expandedPlayer = true }.atlas("control.music.playerAndQueueOpenFullWindow")
        Divider()
        MusicManageArtworkMenu(subject: MusicArtworkSubject.derive(t))
    }

    /// The track's "..." menu: the universal song menu (the one every row has), then what only the player has.
    private func trackMenu(_ t: MusicTrack) -> some View {
        Menu {
            MusicTrackMenuContent(track: t, hub: hub)
            Divider()
            Button("View artwork", systemImage: "photo") { showCover = true }.atlas("control.music.nowPlayingViewArtwork")
            Button("Audio settings…", systemImage: "slider.horizontal.3") { audioSettings = true }.atlas("control.music.nowPlayingAudioSettings")
            Menu("Sleep Timer", systemImage: "moon.zzz") { MusicSleepItems(hub: hub) }.atlas("control.music.playerAndQueueSleepTimer")
            layoutMenu
            Divider()
            if hub.radio.isActive { Button("Not for a while", systemImage: "moon.zzz") { hub.radio.notForAWhile(t) }.disabled(hub.room.controlsLocked).atlas("control.music.radioNotForAWhile") }
            Button("Open Full Window", systemImage: "arrow.up.left.and.arrow.down.right") { hub.expandedPlayer = true }.atlas("control.music.playerAndQueueOpenFullWindow")
            #if os(macOS)
            Button("Mini player", systemImage: "pip") { MusicMiniPlayerController.shared.open(hub: hub) }.atlas("control.music.miniPlayerOpenTheMiniPlayer")
            #endif
            Divider()
            Button("Hide player", systemImage: "chevron.down.square") { MusicBarActions.hide() }.atlas("control.music.playerHide")
            Button("Stop playback", systemImage: "stop.fill") { MusicBarActions.stopPlayback(hub) }.disabled(hub.room.controlsLocked).atlas("control.music.playerStop")
        } label: {
            Image(systemName: "ellipsis").font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.textSecondary)
                .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(ColorTokens.textSecondary)
        .popover(isPresented: $audioSettings, arrowEdge: .bottom) { MusicAudioSettingsPopover(hub: hub) }
        .accessibilityLabel(Localized.string("More actions for %@", t.title)).musicTooltip(verbatim: MusicA11yLabels.more).atlas("control.music.playerAndQueueMoreActionsFor")
    }

    /// Compact, Balanced or Immersive: how much of the panel the cover takes.
    private var layoutMenu: some View {
        Menu {
            ForEach(MusicNowPlayingMode.allCases) { m in
                Button(Localized.string(m.title), systemImage: modeRaw == m.rawValue ? "checkmark" : m.symbol) { modeRaw = m.rawValue }.atlas("control.music.nowPlayingMode")
            }
        } label: { Label("Layout", systemImage: "rectangle.3.group") }
        .atlas("control.music.nowPlayingModeMenu")
    }
}

/// The panel's own controls under the cover and title: progress with times (its own scrub state, like the bar), previous, play and pause, next,
/// shuffle, repeat and volume. Position ticks redraw only `MusicBarProgress`.
struct MusicNowPlayingControls: View {
    let hub: MusicHub
    let duration: TimeInterval
    @Environment(\.reddyAccent) private var accent
    private var player: MusicPlayer { hub.player }

    var body: some View {
        VStack(spacing: MusicSpace.xs) {
            MusicBarProgress(hub: hub, fallbackDuration: duration)
            HStack(spacing: MusicSpace.md) {
                shuffle
                step(glyph: "backward.end.fill", label: MusicA11yLabels.previous, hint: MusicA11yLabels.previousHint, id: "control.music.playerAndQueuePrevious") { player.previous() }
                play
                step(glyph: "forward.end.fill", label: MusicA11yLabels.next, hint: MusicA11yLabels.nextHint, id: "control.music.playerAndQueueNext") { player.next() }
                repeatButton
            }
            .musicRoomLocked(hub.room.controlsLocked)
            MusicBarVolume(player: player)
        }
    }

    private func step(glyph: String, label: String, hint: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph).font(MusicTokens.iconLarge).foregroundStyle(ColorTokens.textPrimary)
                .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label).accessibilityHint(hint).musicTooltip(verbatim: label).atlas(id).atlasCovers("control.music.playerAndQueueNext")
    }

    private var play: some View {
        Button { player.toggle() } label: {
            ZStack {
                Circle().fill(ColorTokens.textPrimary)
                MusicPlayPauseIcon(isPlaying: player.isPlaying, size: MusicIconSize.large, tint: .custom(ColorTokens.background))
            }
            .frame(width: MusicTokens.hitTarget + MusicSpace.xs, height: MusicTokens.hitTarget + MusicSpace.xs)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.isPlaying ? MusicA11yLabels.pause : MusicA11yLabels.play)
        .musicTooltip(verbatim: player.isPlaying ? MusicA11yLabels.pause : MusicA11yLabels.play)
        .atlas("control.music.playerAndQueueMusicplayerbartransportKeyboardShortcut")
    }

    private var shuffle: some View {
        Button { player.shuffle.toggle() } label: {
            MusicIcon(glyph: .shuffle, size: MusicIconSize.large, tint: player.shuffle ? .accent : .secondary)
                .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(Localized.string(player.shuffle ? "Shuffle on" : "Shuffle off")).accessibilityAddTraits(player.shuffle ? .isSelected : [])
        .musicTooltip(verbatim: MusicA11yLabels.shuffle).atlas("control.music.playerAndQueueMusicplayerbartransportButton")
    }

    private var repeatButton: some View {
        let mode = player.repeatMode
        return Button { player.repeatMode = MusicQueueLogic.nextRepeat(mode) } label: {
            MusicIcon(glyph: mode == .one ? .repeatOne : .repeatAll, size: MusicIconSize.large, tint: mode == .off ? .secondary : .accent)
                .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(Localized.string(mode == .off ? "Repeat off" : mode == .all ? "Repeat all" : "Repeat one"))
        .accessibilityAddTraits(mode != .off ? .isSelected : [])
        .musicTooltip(verbatim: MusicA11yLabels.repeat).atlas("control.music.playerAndQueueMusicplayerbartransportButton")
    }
}

@MainActor
enum MusicNowPlayingMemory { static var details: CGFloat = 0 }
