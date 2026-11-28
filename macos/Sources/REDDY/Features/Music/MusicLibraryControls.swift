import SwiftUI

// The controls of the Library page: the tab bar (a row of segments, or a menu when the page is narrow), the view and sort menus, the quick filter,
// the source filter, the chips that show what is filtered, and the quiet "More" menu that holds import, export and the never-play list.

/// The tabs. Wide: a row of chips. Narrow (below `MusicLibraryTabStyle.collapseWidth`, or the compact layout class): one menu that names the current tab,
/// so nothing overflows at 640 to 760 pt.
struct MusicLibraryTabBar: View {
    let tabs: [MusicLibraryTab]
    @Binding var selection: MusicLibraryTab
    let style: MusicLibraryTabStyle
    let counts: [MusicLibraryTab: Int]
    var onDownloads: () -> Void

    var body: some View {
        HStack(spacing: MusicSpace.xs) {
            switch style {
            case .segmented:
                MusicUnderlineTabs(tabs: tabs, title: { $0.title }, selection: $selection)
                    .accessibilityElement(children: .contain).accessibilityLabel("Library sections")
            case .menu:
                Menu {
                    Picker("Library section", selection: $selection) {
                        ForEach(tabs) { t in Label(t.title, systemImage: t.symbol).tag(t) }
                    }
                    .pickerStyle(.inline).atlas("control.music.libraryTabMenu")
                } label: {
                    Label(selection.title, systemImage: selection.symbol).musicText(.body)
                        .padding(.horizontal, MusicSpace.sm).frame(height: MusicButtonMetrics.height(.regular))
                        .background(ColorTokens.elevated, in: Capsule())
                }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(Text(verbatim: Localized.string("Library section: %@", selection.title)))
                .atlasCovers("control.music.libraryTabMenu")
            }
            Spacer(minLength: MusicSpace.xs)
            Button(action: onDownloads) { Label("Downloads", systemImage: "arrow.down.circle") }
                .musicButton(.tertiary, size: .compact).accessibilityLabel("Open Downloads").atlas("control.music.libraryDownloads")
        }
    }
}

/// The library's sections as real tabs: short text labels, the chosen one bold and darker with an accent line under it (two cues, as the usability research asks for), the
/// others quiet, and a single hairline under the whole row. No borders, no icons, no fills.
struct MusicUnderlineTabs<Item: Hashable & Identifiable>: View {
    let tabs: [Item]
    let title: (Item) -> String
    @Binding var selection: Item
    var atlas = "control.music.libraryTab"
    @Namespace private var line
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: Item?

    var body: some View {
        HStack(alignment: .bottom, spacing: MusicSpace.lg) {
            ForEach(tabs) { t in
                let on = t == selection
                Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { selection = t } } label: {
                    Text(verbatim: title(t))
                        .font(.system(size: 15, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? ColorTokens.textPrimary : (hovered == t ? ColorTokens.textPrimary.opacity(0.8) : ColorTokens.textSecondary))
                        .padding(.vertical, 9)
                        .overlay(alignment: .bottom) {
                            if on { Capsule().fill(accent).frame(height: 2.5).matchedGeometryEffect(id: "line", in: line) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? t : (hovered == t ? nil : hovered) }
                .accessibilityAddTraits(on ? .isSelected : [])
                .atlas("control.music.libraryTab")
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(ColorTokens.line).frame(height: 0.75).offset(y: 0.5) }
    }
}

/// A short list of choices drawn as plain text, for a secondary choice (where to search): a quiet label, the options as links, the chosen one in the accent colour.
struct MusicQuietChoice<Item: Hashable & Identifiable>: View {
    let label: String
    let options: [Item]
    let title: (Item) -> String
    @Binding var selection: Item
    @Environment(\.reddyAccent) private var accent
    @State private var hovered: Item?

    var body: some View {
        HStack(spacing: MusicSpace.xs) {
            Text(verbatim: label).font(.system(size: 13)).foregroundStyle(ColorTokens.textTertiary)
            ForEach(options) { o in
                let on = o == selection
                Button { selection = o } label: {
                    Text(verbatim: title(o)).font(.system(size: 13.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? accent : (hovered == o ? ColorTokens.textPrimary : ColorTokens.textSecondary))
                        .padding(.vertical, 6).padding(.horizontal, 4).contentShape(Rectangle())
                }
                .buttonStyle(.plain).onHover { hovered = $0 ? o : (hovered == o ? nil : hovered) }
                .accessibilityAddTraits(on ? .isSelected : []).atlas("control.music.searchScopeChoice")
            }
        }
    }
}

/// View mode and sort: two small menus that sit beside the title. The button of each shows the current choice.
struct MusicLibraryViewControls: View {
    let tab: MusicLibraryTab
    let mode: MusicLibraryViewMode
    let sort: MusicLibrarySort
    let reversed: Bool
    var onMode: (MusicLibraryViewMode) -> Void
    var onSort: (MusicLibrarySort, Bool) -> Void
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        HStack(spacing: MusicSpace.xxs) {
            Menu {
                Picker("View as", selection: Binding(get: { mode }, set: onMode)) {
                    ForEach(tab.modes) { m in Label(m.title, systemImage: m.symbol).tag(m) }
                }
                .pickerStyle(.inline).atlas("control.music.libraryViewMode")
            } label: { icon(mode.symbol, tint: ColorTokens.textSecondary) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().hoverHighlight()
                .help("View as").accessibilityLabel(Text(verbatim: Localized.string("View as: %@", mode.title))).atlasCovers("control.music.libraryViewMode")

            Menu {
                Picker("Sort by", selection: Binding(get: { sort }, set: { onSort($0, false) })) {
                    ForEach(tab.sorts) { s in Text(verbatim: s.title).tag(s) }
                }
                .pickerStyle(.inline).atlas("control.music.librarySort")
                Divider()
                Button(reversed ? sort.title : sort.reversedTitle, systemImage: "arrow.up.arrow.down") { onSort(sort, !reversed) }
                    .atlas("control.music.librarySortReverse")
            } label: {
                icon(isDefault ? "arrow.up.arrow.down" : "arrow.up.arrow.down.circle.fill", tint: isDefault ? ColorTokens.textSecondary : accent)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().hoverHighlight()
            .help("Sort").accessibilityLabel(Text(verbatim: Localized.string("Sort: %@", sort.title))).atlasCovers("control.music.librarySort")
        }
    }

    private var isDefault: Bool { sort == tab.defaultSort && !reversed }

    private func icon(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol).font(MusicTokens.iconMedium).foregroundStyle(tint)
            .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
    }
}

/// The quick filter field and the source filter menu.
struct MusicLibraryFilterBar: View {
    let tab: MusicLibraryTab
    @Binding var filter: MusicLibraryFilterState
    let providers: [(id: String, count: Int)]
    let hub: MusicHub
    @FocusState private var focused: Bool
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        HStack(spacing: MusicSpace.xs) {
            HStack(spacing: MusicSpace.xs) {
                Image(systemName: "line.3.horizontal.decrease").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
                TextField("Filter this tab", text: $filter.query).textFieldStyle(.plain).musicText(.body).focused($focused)
                    .accessibilityLabel("Filter this tab").atlas("control.music.libraryFilter")
                    #if os(macOS)
                    .onExitCommand { if !filter.query.isEmpty { filter.query = "" } else { focused = false } }
                    #endif
                if !filter.query.isEmpty {
                    Button { filter.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(MusicTokens.iconSmall).frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).accessibilityLabel("Clear filter").atlas("control.music.libraryFilterClear")
                }
            }
            .padding(.leading, MusicSpace.sm).padding(.trailing, filter.query.isEmpty ? MusicSpace.sm : 0)
            .frame(minWidth: 160, maxWidth: 320).frame(height: MusicTokens.hitTarget + MusicSpace.xxs)
            .podcastFieldStyle(focused: focused, accent: accent)

        }
    }

    private func name(_ id: String) -> String { MusicLibraryNames.provider(id, hub: hub) }
}

enum MusicLibraryNames {
    @MainActor static func provider(_ id: String, hub: MusicHub) -> String { hub.registry.provider(id: id)?.info.name ?? id }
}

/// What is filtered right now, as chips that each remove their part, plus "Clear all". Remembered with the tab, so it is still there on return.
struct MusicLibraryChips: View {
    let tab: MusicLibraryTab
    @Binding var filter: MusicLibraryFilterState
    let sort: MusicLibrarySort
    let reversed: Bool
    let hub: MusicHub
    var onResetSort: () -> Void

    private var sortActive: Bool { sort != tab.defaultSort || reversed }

    var body: some View {
        if filter.isActive || sortActive {
            HStack(spacing: MusicSpace.xs) {
                if !filter.trimmedQuery.isEmpty { chip(Localized.string("Matching “%@”", filter.trimmedQuery)) { filter.query = "" } }
                if let s = filter.source { chip(Localized.string("Source: %@", MusicLibraryNames.provider(s, hub: hub))) { filter.source = nil } }
                if sortActive { chip(Localized.string("Sorted: %@", reversed ? sort.reversedTitle : sort.title), remove: onResetSort) }
                if filter.isActive {
                    Button("Clear filters") { filter = MusicLibraryFilterState() }.musicButton(.tertiary, size: .compact, accentText: true)
                        .atlas("control.music.libraryClearFilters")
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Active filters")
        }
    }

    private func chip(_ text: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: MusicSpace.xxs) { Text(verbatim: text).lineLimit(1); Image(systemName: "xmark").font(MusicTokens.iconSmall) }
        }
        .musicButton(.chip, size: .compact, selected: true)
        .accessibilityLabel(Text(verbatim: Localized.string("Remove filter: %@", text))).atlas("control.music.libraryChip")
    }
}

/// Play, Shuffle and the actions on what is shown. Download is offered only for a list short enough to mean it.
struct MusicLibrarySongActions: View {
    let hub: MusicHub
    let tracks: [MusicTrack]
    @Binding var selecting: Bool
    var canSelect: Bool

    static let downloadLimit = 100

    var body: some View {
        HStack(spacing: MusicSpace.xs) {
            Button { hub.play(tracks, at: 0, sourceName: Localized.string("Songs")) } label: { Label("Play", systemImage: "play.fill") }
                .musicButton(.primary, size: .compact).disabled(tracks.isEmpty).accessibilityLabel("Play these songs").atlas("control.music.libraryPlay")
            Button { hub.playShuffled(tracks, sourceName: Localized.string("Songs")) } label: { Label("Shuffle", systemImage: "shuffle") }
                .musicButton(.secondary, size: .compact).disabled(tracks.isEmpty).accessibilityLabel("Shuffle these songs").atlas("control.music.libraryShuffle")
            Menu {
                Button("Add to queue", systemImage: "text.badge.plus") { hub.player.enqueue(tracks) }.atlas("control.music.libraryAddQueue")
                Button("Play next", systemImage: "text.insert") { hub.player.playNext(tracks) }.atlas("control.music.libraryPlayNext")
                Button(tracks.count > Self.downloadLimit ? Localized.string("Download (filter to %d songs or fewer)", Self.downloadLimit) : Localized.string("Download these songs"),
                       systemImage: "arrow.down.circle") { for t in tracks { hub.downloads.enqueue(t) } }
                    .disabled(tracks.isEmpty || tracks.count > Self.downloadLimit).atlasCovers("control.music.libraryDownload")
            } label: {
                Image(systemName: "ellipsis.circle").font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.textSecondary)
                    .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().hoverHighlight().disabled(tracks.isEmpty)
            .help("More actions for these songs").accessibilityLabel("More actions for these songs").atlas("control.music.librarySongActions")
            if canSelect {
                Button { selecting.toggle() } label: { Label(selecting ? "Done" : "Select", systemImage: selecting ? "checkmark.circle.fill" : "checkmark.circle") }
                    .musicButton(.tertiary, size: .compact).accessibilityLabel(selecting ? "Stop selecting" : "Select songs").atlas("control.music.librarySelect")
            }
        }
    }
}

/// The quiet "More" menu: import, export, the never-play list. Out of the heading so the title and the view controls have the room.
struct MusicLibraryMoreMenu: View {
    var onImportMusic: () -> Void
    var onNewPlaylist: () -> Void
    var onExport: () -> Void
    var onImportBackup: () -> Void
    var onNeverPlay: () -> Void

    var body: some View {
        Menu {
            Button("New playlist…", systemImage: "plus") { onNewPlaylist() }.atlas("control.music.libraryNewPlaylist")
            Divider()
            Button("Import playlists and likes…", systemImage: "arrow.down.doc") { onImportMusic() }.atlas("control.music.import")
            Button("Export backup…", systemImage: "square.and.arrow.up") { onExport() }.atlas("control.music.yourLibraryExportABackupOfYourMusic")
            Button("Import backup…", systemImage: "square.and.arrow.down") { onImportBackup() }.atlas("control.music.yourLibraryImportABackupOfYourMusic")
            Divider()
            Button("Never Play List", systemImage: "nosign") { onNeverPlay() }.atlas("control.music.yourLibraryOpenTheListOfSongsAnd")
        } label: {
            Image(systemName: "ellipsis").font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.textSecondary)
                .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
                .background(ColorTokens.elevated, in: Circle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().hoverHighlight()
        .help("More").accessibilityLabel("More library actions").atlas("control.music.libraryMore")
    }
}
