import SwiftUI

enum MusicNowPlayingCard {
    /// Artwork edge of the sidebar's Now playing card.
    static let artwork: CGFloat = MusicSpace.xxl + MusicSpace.xs
}

/// The sidebar's playlist and account dialogs. They belong to the shell, not to a sidebar view: in auto-hide mode the open sidebar is a second view that goes away as soon as
/// the pointer leaves it (to reach a dialog), and a dialog it owned would go with it, so the action never ran.
@MainActor @Observable
final class MusicSidebarDialogs {
    static let shared = MusicSidebarDialogs()
    var creating = false
    var newName = ""
    var renaming: LocalPlaylist?
    var renameText = ""
    var deleting: LocalPlaylist?
    /// The saved account the account menu asked to remove.
    var removingAccount: YTMAccountSummary?

    func startCreate() { newName = ""; creating = true }
    func startRename(_ p: LocalPlaylist) { renameText = p.name; renaming = p }
    func startDelete(_ p: LocalPlaylist) { deleting = p }

    func confirmCreate(hub: MusicHub) {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        creating = false
        guard !n.isEmpty else { return }
        let made = hub.library.createPlaylist(name: n, tracks: [])
        hub.nav.select(.library); hub.open(.localPlaylist(made.id))
    }

    func confirmRename(hub: MusicHub) {
        let n = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = renaming, !n.isEmpty { hub.library.rename(p, to: n) }
        renaming = nil
    }

    func confirmDelete(hub: MusicHub) {
        if let p = deleting { hub.deletePlaylist(p) }
        deleting = nil
    }

    func dismissAll() { creating = false; renaming = nil; deleting = nil; removingAccount = nil }
}

/// Presents the sidebar's dialogs. Apply it ONCE, on the Music shell, which stays while a sidebar view comes and goes.
struct MusicSidebarDialogsHost: ViewModifier {
    let hub: MusicHub
    @Bindable var dialogs: MusicSidebarDialogs

    func body(content: Content) -> some View {
        content
            .alert("New playlist", isPresented: $dialogs.creating) {
                TextField("Name", text: $dialogs.newName)
                Button("Cancel", role: .cancel) {}.atlas("control.music.yourLibraryCancel")
                Button("Create") { dialogs.confirmCreate(hub: hub) }.atlas("control.music.yourLibraryCreate")
            }
            .alert("Rename playlist", isPresented: Binding(get: { dialogs.renaming != nil }, set: { if !$0 { dialogs.renaming = nil } })) {
                TextField("Name", text: $dialogs.renameText)
                Button("Cancel", role: .cancel) { dialogs.renaming = nil }.atlas("control.music.yourLibraryCancel")
                Button("Rename") { dialogs.confirmRename(hub: hub) }.atlas("control.music.albumArtistAndPlaylistPagesEditPlaylist")
            }
            .confirmationDialog(dialogs.deleting.map { Localized.string("Delete “%@”?", $0.name) } ?? "", isPresented: Binding(get: { dialogs.deleting != nil }, set: { if !$0 { dialogs.deleting = nil } }), titleVisibility: .visible) {
                Button("Delete Playlist", role: .destructive) { dialogs.confirmDelete(hub: hub) }.atlas("control.music.albumArtistAndPlaylistPagesDeletePlaylist")
                Button("Cancel", role: .cancel) { dialogs.deleting = nil }.atlas("control.music.yourLibraryCancel")
            } message: { Text("The playlist is removed. The songs stay in your library.") }
            .modifier(MusicAccountDialogs(dialogs: dialogs))
    }
}

/// The account menu's two dialogs (remove a saved account, and what went wrong).
private struct MusicAccountDialogs: ViewModifier {
    @Bindable var dialogs: MusicSidebarDialogs

    func body(content: Content) -> some View {
        let manager = YouTubeMusicAccountBuiltIns.manager
        let failure = manager?.errorMessage
        content
            .confirmationDialog("Remove from this app?", isPresented: Binding(get: { dialogs.removingAccount != nil }, set: { if !$0 { dialogs.removingAccount = nil } }),
                                titleVisibility: .visible, presenting: dialogs.removingAccount) { acct in
                Button("Remove", role: .destructive) { manager?.remove(acct.id) }.atlas("control.music.accountsRemove")
                Button("Cancel", role: .cancel) {}.atlas("control.music.accountsCancel")
            } message: { acct in
                Text("\(acct.name) is removed from this list only. Your Google account is not affected.")
            }
            .alert("YouTube Music", isPresented: Binding(get: { failure != nil }, set: { if !$0 { manager?.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}.atlas("control.music.accountsOk")
            } message: { Text(verbatim: failure ?? "") }.atlas("control.music.accountsChooseAChannel")
    }
}

/// When the open sidebar of auto-hide may close.
enum MusicSidebarPeek {
    /// A menu opened from the sidebar takes the pointer off it; the sidebar stays until the menu is closed, so the menu's own view is not removed under it.
    static func mayClose(menuTracking: Bool) -> Bool { !menuTracking }
    /// A change of section closes the open sidebar over the new page. Coming back from Settings is not one: Settings opens as a sheet and the person never left their page.
    static func closesOnNavigation(from old: MusicSection, to new: MusicSection) -> Bool { old != new && old != .settings }
}

/// The saved fold of each sidebar group. Both sidebar views (the rail and the open one) read the same stored value, so they never disagree.
enum MusicSidebarFoldKeys {
    static let library = "music.sidebar.fold.library"
    static let playlists = "music.sidebar.fold.playlists"
}

/// The current place: a tint, a hairline and a bar, so it does not rely on colour alone.
private struct MusicSidebarLit: ViewModifier {
    let on: Bool
    @Environment(\.reddyAccent) private var accent
    @Environment(\.musicA11y) private var a11y
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(on ? accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous))
            .overlay { if on { RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous).strokeBorder(accent.opacity(0.2), lineWidth: 1).allowsHitTesting(false) } }
            .musicAnimation(.toggle, reduce: reduceMotion, value: on)
            .overlay(alignment: .leading) {
                if on { Capsule().fill(accent).frame(width: a11y.differentiateWithoutColor ? 4 : 3, height: MusicIconSize.row).padding(.leading, MusicSpace.xxs) }
            }
    }
}

/// Region A: the Music sidebar. The six main places on top, then a quiet "More" group (Downloads, Devices, Listen Together, Settings), the person's
/// playlists and what they played lately in the part that scrolls, and the account at the bottom. Icons only when compact.
struct MusicSidebar: View {
    @Bindable var hub: MusicHub
    var collapsed = false
    /// Whether the person may widen it (the window is at least 1000 pt); the toggle is disabled when it cannot grow.
    var canExpand = true
    var width: CGFloat = MusicLayoutGrid.navExpandedWidth
    var toggle: () -> Void = {}
    /// Auto-hide mode: the rail opens on hover. The header button then pins the open sidebar (and on the rail it pins it open too).
    var autoHide = false
    @Environment(\.reddyAccent) private var accent
    @Environment(\.reddyDensity) private var density
    @State private var barVisibility = MusicBarVisibilityModel.shared
    /// The row the keyboard is on (Up and Down move it, Home and End jump), so the sidebar is one place to arrow through and not a string of Tab stops.
    @FocusState private var focusedRow: String?
    /// The groups the person folded, remembered between launches.
    @AppStorage(MusicSidebarFoldKeys.library) private var libraryFolded = false
    @AppStorage(MusicSidebarFoldKeys.playlists) private var playlistsFolded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            // The compact rail has no room beside the toggle, so the listening mode sits under it instead of vanishing.
            if collapsed { modesButton.padding(.bottom, MusicSpace.xs) }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(MusicSection.primarySections) { row($0) }
                    libraryGroup
                    moreGroup
                    playlistsGroup
                }
                .padding(.horizontal, 10).padding(.bottom, MusicSpace.sm)
            }
            .scrollIndicators(.hidden)
            .onKeyPress(.downArrow) { moveFocus(1) }
            .onKeyPress(.upArrow) { moveFocus(-1) }
            .onKeyPress(.home) { jumpFocus(toEnd: false) }
            .onKeyPress(.end) { jumpFocus(toEnd: true) }
            if MusicBarVisibility.showsRestoreAffordances(hasTrack: hub.player.current != nil, hidden: barVisibility.hidden), let t = hub.player.current {
                nowPlayingCard(t)
            }
            MusicAccountMenu(hub: hub, compact: collapsed).atlas("control.music.account").padding(.horizontal, 10).padding(.vertical, MusicSpace.sm)
        }
        .frame(width: width).frame(maxHeight: .infinity)
        .musicBackdrop(solid: ColorTokens.surface, cornerRadius: 0) { PodcastSidebarBackground() }
        .overlay(alignment: .trailing) { Rectangle().fill(ColorTokens.line).frame(width: 1) }
        .clipped()
        .musicFocusRegion(Localized.string("Music sidebar"))
    }

    // MARK: keyboard

    /// The rows the arrow keys walk, top to bottom.
    private var rowIDs: [String] {
        Self.rowIDs(primary: MusicSection.primarySections.map(\.rawValue), more: MusicSection.moreSections.map(\.rawValue), playlists: hub.library.playlists.map { $0.id.uuidString },
                    libraryFolded: libraryFolded, playlistsFolded: playlistsFolded, collapsed: collapsed)
    }

    /// The ids the arrow keys walk, in the order the rows are drawn, leaving out the rows a folded group does not draw (a hidden row must never take the focus).
    static func rowIDs(primary: [String], more: [String], playlists: [String], libraryFolded: Bool, playlistsFolded: Bool, collapsed: Bool) -> [String] {
        var ids = primary.map { "section:" + $0 }
        if !libraryFolded || collapsed { ids += ["shortcut:recent", "shortcut:artists", "shortcut:albums", "shortcut:songs"] }
        ids += more.map { "section:" + $0 }
        ids.append("shortcut:link")
        if !collapsed { ids.append("newplaylist") }          // the rail has no New Playlist button
        if !playlistsFolded || collapsed { ids.append("shortcut:allplaylists"); ids += playlists.map { "playlist:" + $0 } }
        return ids
    }

    static func isPlaylistPage(_ top: MusicRoute?) -> Bool { if case .localPlaylist = top { return true }; return false }

    /// The shortcut row (its id) that stands for the page being shown, or nil when none does.
    static func litShortcut(section: MusicSection, top: MusicRoute?, standaloneTab: MusicLibraryTab?) -> String? {
        guard section == .library else { return nil }
        if let top { return top == .collection(.recentlyPlayed) ? "recent" : nil }
        switch standaloneTab {
        case .artists: return "artists"
        case .albums: return "albums"
        case .songs: return "songs"
        case .playlists: return "allplaylists"
        default: return nil
        }
    }

    /// Whether a main row carries the highlight. Library does not while a row below it (a shortcut or a playlist) is drawn and carries it.
    static func isSectionLit(_ s: MusicSection, section: MusicSection, top: MusicRoute?, standaloneTab: MusicLibraryTab?, libraryRowsShown: Bool, playlistRowsShown: Bool) -> Bool {
        guard section == s else { return false }
        guard s == .library else { return true }
        if isPlaylistPage(top) { return !playlistRowsShown }
        guard let lit = litShortcut(section: section, top: top, standaloneTab: standaloneTab) else { return true }
        return lit == "allplaylists" ? !playlistRowsShown : !libraryRowsShown
    }

    private func moveFocus(_ delta: Int) -> KeyPress.Result {
        let ids = rowIDs
        guard !ids.isEmpty else { return .ignored }
        guard let cur = focusedRow, let i = ids.firstIndex(of: cur) else { focusedRow = delta > 0 ? ids.first : ids.last; return .handled }
        focusedRow = ids[min(max(i + delta, 0), ids.count - 1)]
        return .handled
    }

    private func jumpFocus(toEnd: Bool) -> KeyPress.Result {
        guard let id = toEnd ? rowIDs.last : rowIDs.first else { return .ignored }
        focusedRow = id
        return .handled
    }

    // MARK: header

    /// The header button: pins the sidebar open while it is auto-hiding; from a pinned sidebar it goes back to auto-hide.
    static func toggleLabel(collapsed: Bool, autoHide: Bool) -> String {
        if autoHide { return "Keep sidebar open" }
        return collapsed ? "Expand sidebar" : "Auto-hide sidebar"
    }

    private var modesButton: some View {
        Button { MusicChromeState.shared.modesOpen = true } label: {
            Image(systemName: MusicListeningModes.shared.mode.symbol).font(MusicTokens.iconMedium).frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight().foregroundStyle(MusicListeningModes.shared.mode == .standard ? ColorTokens.textSecondary : ColorTokens.textPrimary)
        .accessibilityLabel(Localized.string("Listening mode")).musicTooltip(verbatim: Localized.string("Listening mode: %@", MusicListeningModes.shared.mode.title))
        .atlas("control.music.modesOpen")
    }

    private var header: some View {
        HStack(spacing: MusicSpace.xs) {
            if !collapsed {
                Text(Localized.string("Music")).font(Typography.heading).foregroundStyle(ColorTokens.textPrimary)
                    .padding(.leading, MusicSpace.sm).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            if !collapsed { modesButton }
            if canExpand || collapsed {
                Button(action: toggle) {
                    Image(systemName: "sidebar.left").font(MusicTokens.iconMedium).frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hoverHighlight().foregroundStyle(ColorTokens.textSecondary)
                .disabled(!canExpand)
                .accessibilityLabel(LocalizedStringKey(Self.toggleLabel(collapsed: collapsed, autoHide: autoHide)))
                .musicTooltip(LocalizedStringKey(Self.toggleLabel(collapsed: collapsed, autoHide: autoHide)))
                .atlas("control.music.sidebarToggle")
            }
        }
        .padding(.horizontal, 10).padding(.top, MusicSpace.md).padding(.bottom, MusicSpace.sm)
        .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
    }

    // MARK: groups

    @ViewBuilder private var moreGroup: some View {
        groupHeader(Localized.string("More"))
        ForEach(MusicSection.moreSections) { row($0) }
        shortcutRow("link", Localized.string("Open a Link"), id: "link") { MusicChromeState.shared.showOpenLink = true }
    }

    /// Straight to the parts of Your Library, the way Apple Music lists them: Recently Added, Artists, Albums, Songs.
    @ViewBuilder private var libraryGroup: some View {
        groupHeader(Localized.string("Library"), folded: $libraryFolded)
        if !libraryFolded || collapsed {
            shortcutRow("clock", Localized.string("Recently Played"), id: "recent") { hub.nav.select(.library); hub.open(collection: .recentlyPlayed) }
            shortcutRow("music.mic", Localized.string("Artists"), id: "artists") { openLibrary(.artists) }
            shortcutRow("square.stack", Localized.string("Albums"), id: "albums") { openLibrary(.albums) }
            shortcutRow("music.note", Localized.string("Songs"), id: "songs") { openLibrary(.songs) }
        }
    }

    @ViewBuilder private var playlistsGroup: some View {
        let lists = hub.library.playlists
        groupHeader(Localized.string("Playlists"), folded: $playlistsFolded)
        if !collapsed {
            Button { MusicSidebarDialogs.shared.startCreate() } label: {
                Label(Localized.string("New Playlist"), systemImage: "plus").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, MusicSpace.sm).frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
            }
            .buttonStyle(.plain).hoverHighlight(radius: MusicCorner.control)
            .focused($focusedRow, equals: "newplaylist")
            .accessibilityLabel(Localized.string("New Playlist")).musicTooltip(verbatim: Localized.string("New Playlist")).atlas("control.music.sidebarNewPlaylist")
        }
        if !playlistsFolded || collapsed {
            shortcutRow("square.grid.3x3", Localized.string("All Playlists"), id: "allplaylists") { openLibrary(.playlists) }
            LazyVStack(spacing: MusicSpace.xxs) { ForEach(lists) { playlistRow($0) } }
        }
    }

    private func openLibrary(_ tab: MusicLibraryTab) {
        hub.openLibrary(tab: tab)
    }

    /// One shortcut row, in the same geometry as the section rows and the playlist rows.
    private func shortcutRow(_ symbol: String, _ title: String, id: String, action: @escaping () -> Void) -> some View {
        let on = Self.litShortcut(section: hub.nav.section, top: hub.nav.top, standaloneTab: hub.standaloneLibraryTab) == id
        return Button(action: action) {
            HStack(spacing: MusicSpace.sm) {
                Image(systemName: symbol).font(MusicTokens.iconMedium).frame(width: MusicIconSize.row, height: MusicIconSize.row).foregroundStyle(on ? accent : ColorTokens.textSecondary)
                if !collapsed { Text(verbatim: title).font(Typography.body).lineLimit(1); Spacer(minLength: 0) }
            }
            .padding(.horizontal, collapsed ? 0 : MusicSpace.sm).frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .frame(height: max(MusicTokens.hitTarget, density.sidebarRowHeight))
            .foregroundStyle(on ? accent : ColorTokens.textSecondary)
            .modifier(MusicSidebarLit(on: on))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight(radius: MusicCorner.control)
        .focused($focusedRow, equals: "shortcut:" + id)
        .accessibilityLabel(title).accessibilityAddTraits(on ? .isSelected : []).musicTooltip(verbatim: title).atlas("control.music.sidebar")
    }

    @ViewBuilder private func groupHeader(_ title: String, folded: Binding<Bool>? = nil) -> some View {
        if collapsed {
            Rectangle().fill(ColorTokens.line).frame(height: 1).padding(.horizontal, MusicSpace.xs).padding(.vertical, MusicSpace.xs)
        } else if let folded {
            // A group that folds: the whole header is the button, with a chevron that turns.
            Button { withAnimation(.easeOut(duration: 0.18)) { folded.wrappedValue.toggle() } } label: {
                HStack(spacing: MusicSpace.xxs) {
                    Text(verbatim: title.uppercased()).font(Typography.eyebrow).tracking(1.2)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(folded.wrappedValue ? 0 : 90))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(ColorTokens.textTertiary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, MusicSpace.sm).padding(.top, MusicSpace.lg).padding(.bottom, MusicSpace.xs).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(title).accessibilityValue(Localized.string(folded.wrappedValue ? "Folded" : "Open")).accessibilityAddTraits(.isHeader)
            .atlasCovers("control.music.sidebar")
        } else {
            Text(verbatim: title.uppercased()).font(Typography.eyebrow).tracking(1.2).foregroundStyle(ColorTokens.textTertiary)
                .padding(.horizontal, MusicSpace.sm).padding(.top, MusicSpace.lg).padding(.bottom, MusicSpace.xs).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: now playing card

    /// Shown only while a track is loaded and the player bar is hidden: artwork, title, artist and play or pause. It opens the Now Playing tab.
    private func nowPlayingCard(_ t: MusicTrack) -> some View {
        HStack(spacing: MusicSpace.xs) {
            Button { MusicContextPanelState.shared.show(.nowPlaying) } label: {
                HStack(spacing: MusicSpace.sm) {
                    MusicCoverImage(thumbs: t.thumbnails, size: MusicNowPlayingCard.artwork, corner: MusicCorner.control).artwork(of: .derive(t))
                    if !collapsed {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: t.title).font(Typography.bodyMedium).foregroundStyle(ColorTokens.textPrimary).lineLimit(1)
                            Text(verbatim: t.displayArtistLine).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).hoverHighlight()
            .accessibilityLabel(MusicA11yLabels.nowPlaying(title: t.title, artist: t.artistLine)).accessibilityHint(MusicA11yLabels.openPlayerHint)
            .musicTooltip("Open Now Playing").atlas("control.music.sidebarNowPlaying")
            if !collapsed {
                Button { hub.player.toggle() } label: {
                    MusicPlayPauseIcon(isPlaying: hub.player.isPlaying, size: MusicIconSize.row, tint: .primary)
                        .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hoverHighlight()
                .disabled(hub.room.controlsLocked)   // a Listen Together guest follows the host: pausing here would put this device out of step
                .accessibilityLabel(hub.player.isPlaying ? MusicA11yLabels.pause : MusicA11yLabels.play)
                .musicTooltip(verbatim: hub.player.isPlaying ? MusicA11yLabels.pause : MusicA11yLabels.play)
                .atlas("control.music.playerAndQueueMusicplayerbartransportKeyboardShortcut")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, MusicSpace.xs)
        .overlay(alignment: .top) { Rectangle().fill(ColorTokens.line).frame(height: 1) }
    }

    // MARK: rows

    private func row(_ s: MusicSection) -> some View {
        // Library is not lit while a playlist or a shortcut below it is the page: that row carries the highlight.
        let on = Self.isSectionLit(s, section: hub.nav.section, top: hub.nav.top, standaloneTab: hub.standaloneLibraryTab,
                                   libraryRowsShown: !libraryFolded || collapsed, playlistRowsShown: !playlistsFolded || collapsed)
        return Button { if s == .library { hub.openLibrary() } else { hub.nav.select(s) } } label: {
            HStack(spacing: MusicSpace.sm) {
                MusicNavIcon(glyph: s.navGlyph, selected: on).frame(width: MusicIconSize.row)
                if !collapsed { Text(verbatim: s.title).font(Typography.bodyMedium).lineLimit(1); Spacer(minLength: 0) }
            }
            .padding(.horizontal, collapsed ? 0 : MusicSpace.sm).frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .frame(height: max(MusicTokens.hitTarget, density.sidebarRowHeight + 4))
            .foregroundStyle(on ? accent : ColorTokens.textPrimary)
            .modifier(MusicSidebarLit(on: on))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight(radius: MusicCorner.control).atlas("control.music.sidebar")
        .focused($focusedRow, equals: "section:" + s.rawValue)
        .accessibilityLabel(s.title).accessibilityAddTraits(on ? .isSelected : [])
        .musicTooltip(verbatim: s.title)
    }

    private func playlistRow(_ p: LocalPlaylist) -> some View {
        let on = hub.nav.top == .localPlaylist(p.id)
        return Button { hub.nav.select(.library); hub.open(.localPlaylist(p.id)) } label: {
            HStack(spacing: MusicSpace.sm) {
                MusicCoverImage(thumbs: p.tracks.first?.thumbnails ?? [], artworkClass: .trackThumb, size: MusicIconSize.row, corner: MusicCorner.control, seed: p.id.uuidString)
                    .frame(width: MusicIconSize.row, height: MusicIconSize.row).accessibilityHidden(true)
                if !collapsed { Text(verbatim: p.name).font(Typography.body).lineLimit(1); Spacer(minLength: 0) }
            }
            .padding(.horizontal, collapsed ? 0 : MusicSpace.sm).frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .frame(height: max(MusicTokens.hitTarget, density.sidebarRowHeight))
            .foregroundStyle(on ? accent : ColorTokens.textSecondary)
            .background(on ? accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight(radius: MusicCorner.control)
        .focused($focusedRow, equals: "playlist:" + p.id.uuidString)
        .contextMenu {
            Button("Play", systemImage: "play.fill") { hub.play(p.tracks, at: 0, sourceName: p.name, sourceID: p.sourceID) }.disabled(p.tracks.isEmpty).atlas("control.music.sharedPartsPlay")
            Button("Shuffle", systemImage: "shuffle") { hub.playShuffled(p.tracks, sourceName: p.name, sourceID: p.sourceID) }.disabled(p.tracks.isEmpty).atlas("control.music.albumArtistAndPlaylistPagesShuffleAll")
            Divider()
            Button("Rename…", systemImage: "pencil") { MusicSidebarDialogs.shared.startRename(p) }.atlas("control.music.albumArtistAndPlaylistPagesEditPlaylist")
            Button("Delete Playlist", systemImage: "trash", role: .destructive) { MusicSidebarDialogs.shared.startDelete(p) }.atlas("control.music.albumArtistAndPlaylistPagesDeletePlaylist")
        }
        .accessibilityLabel(Localized.string("Playlist %@", p.name)).accessibilityAddTraits(on ? .isSelected : [])
        .musicTooltip(verbatim: p.name)
        .musicDropTracks(hub: hub) { tracks in
            let added = hub.library.add(tracks, to: p.id)
            MusicToasts.shared.show(MusicMenuLogic.addToast(added: added, duplicates: tracks.count - added, playlists: [p.name], songCount: tracks.count), kind: added == 0 ? .info : .success)
        }.atlas("control.music.musicPlaylist")
    }
}
