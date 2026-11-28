import SwiftUI

/// Region C: the context panel. Five tabs: Now Playing, Queue, Lyrics, Related and Credits (the `.info` case is kept only so a saved choice still decodes). Inline beside the page from 1400 pt; below that the shell
/// shows the same panel as an overlay. Nothing here starts playback except choosing a related song.
struct MusicContextPanel: View {
    let hub: MusicHub
    var state: MusicContextPanelState
    /// Shown over the page rather than beside it: it then closes with Escape.
    var isOverlay = false
    /// True while the full-window player covers the page: the tab behind it draws nothing (and runs no lyrics clock) until the player closes.
    var suspended = false
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Rectangle().fill(ColorTokens.line).frame(height: 1)
            // The tab strip is icons only; this names the one that is open.
            // The Queue and Related tabs name themselves; the others get the tab's name here.
            if ![.queue, .related].contains(state.selectedTab) {
                Text(verbatim: Localized.string(state.selectedTab.title)).font(Typography.heading).foregroundStyle(ColorTokens.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, MusicSpace.md).padding(.top, MusicSpace.md).padding(.bottom, MusicSpace.xs)
                    .accessibilityAddTraits(.isHeader)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .musicBackdrop(solid: ColorTokens.surface, cornerRadius: 0) { PodcastSidebarBackground() }
        .overlay(alignment: .leading) { Rectangle().fill(ColorTokens.line).frame(width: 1) }
        .musicFocusRegion(Localized.string("Details panel"))
    }

    @Namespace private var tabThumb

    /// The tabs as one soft pill with a thumb that slides to the chosen one (the way a segmented control moves), and the close button on its own beside it.
    private var tabBar: some View {
        HStack(spacing: MusicSpace.xs) {
            HStack(spacing: 2) {
                ForEach(MusicContextPanelTab.stripTabs) { tab in
                    let on = state.selectedTab == tab
                    Button { state.select(tab) } label: {
                        MusicNavIcon(glyph: tab.navGlyph, selected: on).frame(maxWidth: .infinity)
                            .frame(height: MusicTokens.hitTarget - 4)
                            .foregroundStyle(on ? accent : ColorTokens.textSecondary)
                            .background {
                                if on {
                                    RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous).fill(accent.opacity(0.18))
                                        .overlay(RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous).strokeBorder(accent.opacity(0.22), lineWidth: 1))
                                        .matchedGeometryEffect(id: "thumb", in: tabThumb)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).hoverHighlight(radius: MusicCorner.control)
                    .accessibilityLabel(LocalizedStringKey(tab.title)).accessibilityAddTraits(on ? .isSelected : [])
                    .musicTooltip(LocalizedStringKey(tab.title))
                    .atlas("control.music.contextTab")
                }
            }
            .padding(3)
            .background(ColorTokens.elevated.opacity(0.55), in: RoundedRectangle(cornerRadius: MusicCorner.control + 3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: MusicCorner.control + 3, style: .continuous).strokeBorder(ColorTokens.line, lineWidth: 1))
            .animation(MusicMotion.animation(.toggle, reduce: reduceMotion), value: state.selectedTab)
            Button { state.closePanel() } label: {
                MusicNavIcon(glyph: .close, tint: .secondary).frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
            }
            .buttonStyle(.plain).hoverHighlight(radius: MusicCorner.control).foregroundStyle(ColorTokens.textSecondary)
            .accessibilityLabel("Close details panel").musicTooltip("Close details panel")
            .modifier(MusicEscapeToClose(active: isOverlay))
            .atlas("control.music.contextClose")
        }
        .padding(.horizontal, MusicSpace.sm).padding(.vertical, MusicSpace.sm)
    }

    @ViewBuilder private var content: some View {
        if suspended {
            Color.clear
        } else if hub.player.current == nil {
            MusicEmptyState(glyph: .note, title: Localized.string("Nothing is playing"),
                            message: Localized.string("Play a song to see its details, the queue and the lyrics here."), compact: true)
        } else {
            // Info was only the title, artists, album and length that Now Playing and the song page already show: it has no button any more, and a panel
            // that was last left on it opens on Related.
            switch state.selectedTab {
            case .nowPlaying: MusicNowPlayingPanel(hub: hub, panelState: state)
            case .queue: MusicQueuePanel(hub: hub).padding(.horizontal, MusicSpace.md).padding(.vertical, MusicSpace.xs)
            case .lyrics: MusicLyricsPanel(hub: hub, inset: MusicSpace.md).padding(.vertical, MusicSpace.xs)
            case .related: MusicRelatedTab(hub: hub)
            case .credits: MusicCreditsTab(hub: hub)
            case .info: MusicRelatedTab(hub: hub)   // never reached: the state maps the old Info tab to Related
            }
        }
    }
}

/// Escape closes an overlay panel; an inline panel leaves Escape to the page.
private struct MusicEscapeToClose: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.keyboardShortcut(.cancelAction).atlasCovers("control.music.contextClose") } else { content }
    }
}

// MARK: - Related

/// The Related tab: the song's artist and album, more from the artist, similar artists and related songs. See `MusicRelatedPanel`.
struct MusicRelatedTab: View {
    let hub: MusicHub
    var body: some View { MusicRelatedPanel(hub: hub) }
}

// MARK: - Song length

/// The song's length as a clock ("2:05"); empty when unknown.
enum MusicInfoRows {
    static func duration(ms: Int64) -> String {
        guard ms > 0 else { return "" }
        let s = Int(ms / 1000)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
