import SwiftUI

/// A list of songs with the tools a long list needs: a filter field, a sort menu with direction (remembered per list), a column picker, picking
/// several rows (Cmd or Shift click, or the Select button), a pill that jumps to the playing song, a jump to the end, and paging that
/// loads the next page when the end comes into view.
struct MusicTrackList: View {
    let hub: MusicHub
    let tracks: [MusicTrack]
    /// Remembers the chosen sort under this name. Nil for a list whose order is its meaning (an album).
    var listKey: String?
    var fromPlaylist: UUID?
    var showsTools = true
    var numbered = true
    var canSort = true
    var showsAlbumByDefault = false
    /// When set, picked rows can be removed through it (the page decides what removing means).
    var onRemove: (([MusicTrack]) -> Void)?
    /// Dragging a row onto another row reorders. Offered only while the list is in its own order (no filter, no sort, not picking).
    var onMove: ((IndexSet, Int) -> Void)?
    /// Songs dropped from a card or another list land here.
    var onDropTracks: (([MusicTrack]) -> Void)?
    var hasMore = false
    var loadingMore = false
    var loadFailed = false
    var loadMore: (() -> Void)?
    var retry: (() -> Void)?
    var emptyMessage = Localized.string("There are no songs here.")
    /// The caller already filtered and ordered `tracks` (the Library does it off the main actor): the list draws them as they are.
    var presorted = false
    /// How each row is drawn. Standard rows are the full song rows; compact and table rows are denser.
    var rowStyle: MusicTrackRowStyle = .standard
    /// Lets a page drive picking from its own header: true starts it, false ends it, and ending it inside the list writes false back.
    var selecting: Binding<Bool>?
    var removeLabel = Localized.string("Remove from This Playlist")
    /// Warms the artwork just below the visible rows under this owner name (bounded by the shared prefetcher). Nil turns it off.
    var prefetchOwner: String?
    /// A chart list: what each row shows besides the song (resolving, a version note, unavailable) and what a tap does. Nil for any other list.
    var chartHooks: ((MusicTrack) -> MusicChartRowHooks?)?
    /// Rows coming into and leaving view, for lists that resolve what is on screen first.
    var onRowVisible: ((MusicTrack, Bool) -> Void)?
    /// A quiet trailing text for a row (the Library's play count in its Most played order). Nil for no detail.
    var trailingDetail: ((MusicTrack) -> String?)?
    /// A longer list the rows belong to (a film's songs shown in album groups): pressing a row queues this whole list from that row, not only its own group. Nil queues the shown list.
    var queueContext: [MusicTrack]?

    /// The queue a row plays into: the wider context when it holds the track, else the shown list.
    nonisolated static func queue(for track: MusicTrack, shown: [MusicTrack], context: [MusicTrack]?) -> [MusicTrack] {
        guard let context, context.contains(where: { $0.uid == track.uid }) else { return shown }
        return context
    }

    @State private var filter = ""
    @State private var ordering = MusicTrackOrdering()
    @State private var columns = MusicTrackColumns.load()
    @State private var selection = MusicTrackSelection()
    @State private var width: CGFloat = 0
    @State private var visibleBox = MusicVisibleRows()
    @State private var visibleTick = 0
    @State private var cache = MusicTrackListCache()
    @State private var armedRemove = false
    @FocusState private var filterFocused: Bool
    @Environment(\.musicOverlayHost) private var host
    @Environment(\.reddyAccent) private var accent
    @Environment(\.displayScale) private var displayScale

    /// The filtered and ordered list, worked out once per change of the input and kept, never on every body pass.
    private var snapshot: MusicTrackListCache.Snapshot {
        cache.snapshot(tracks: tracks, filter: filter, ordering: ordering, presorted: presorted)
    }
    private var shown: [MusicTrack] { snapshot.list }
    private var order: [String] { snapshot.uids }
    private var filtering: Bool { !presorted && !filter.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let snap = snapshot
        let list = snap.list
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                if showsTools && !tracks.isEmpty { tools(proxy: proxy, list: list) }
                if list.isEmpty && !tracks.isEmpty { noMatch }
                else if tracks.isEmpty && !hasMore && !loadingMore {
                    MusicEmptyState(symbol: "music.note.list", title: Localized.string("Nothing here yet"), message: emptyMessage).frame(minHeight: 200)
                } else {
                    LazyVStack(spacing: 2) {
                        if rowStyle == .table { MusicLibraryTableHeader(columns: denseColumns) }
                        ForEach(snap.indexed, id: \.element.uid) { i, t in
                            row(t, at: i, list: list, cells: snap.cells)
                                .id(t.uid)
                                .modifier(MusicRowDropTarget(enabled: onMove != nil || onDropTracks != nil, hub: hub, canReorder: canReorder) { payload in
                                    drop(payload, onto: i)
                                })
                        }
                        footer
                    }
                }
            }
            .background(GeometryReader { g in
                Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
            })
            .onAppear {
                if let key = listKey, !presorted { ordering = MusicOrderingMemory.load(key) }
                if showsAlbumByDefault, UserDefaults.standard.stringArray(forKey: MusicTrackColumns.key) == nil { columns.shown.insert(.album) }
                if selecting?.wrappedValue == true, !selection.active { selection.enter() }
                publish(list: list, proxy: proxy)
            }
            .onDisappear {
                host?.bar = nil; host?.pill = nil
                visibleBox.cancel()
                if chartHooks == nil { hub.player.cancelPreResolve() }
                if let o = prefetchOwner { MusicArtworkPrefetcher.shared.cancel(owner: o) }
            }
            .onChange(of: selection) { _, _ in
                if let selecting, selecting.wrappedValue != selection.active { selecting.wrappedValue = selection.active }
                publish(list: shown, proxy: proxy)
            }
            .onChange(of: selecting?.wrappedValue) { _, on in
                if on == true, !selection.active { selection.enter() } else if on != true, selection.active { selection.exit() }
            }
            .onChange(of: snap.signature) { _, _ in selection.prune(keeping: Set(order)); publish(list: shown, proxy: proxy); prefetchBelow() }
            .onChange(of: visibleTick) { _, _ in publish(list: shown, proxy: proxy); prefetchBelow(); preResolveVisible() }
            .onChange(of: hub.player.current?.uid) { _, _ in publish(list: shown, proxy: proxy) }
            .onChange(of: filter) { _, _ in keepLoadingWhileFiltering() }
            .onChange(of: tracks.count) { _, _ in keepLoadingWhileFiltering() }
        }
    }

    @ViewBuilder private func row(_ t: MusicTrack, at i: Int, list: [MusicTrack], cells: MusicTrackCells.Data) -> some View {
        let opts = options(for: t, at: i, count: list.count, cells: cells)
        let queue = Self.queue(for: t, shown: list, context: queueContext)
        switch rowStyle {
        case .standard:
            MusicTrackRow(track: t, index: numbered ? i : nil, queue: queue, hub: hub, hostRemove: removeAction(for: t), fromPlaylist: fromPlaylist, options: opts)
        case .compact, .table:
            MusicLibraryDenseRow(track: t, index: i, queue: queue, hub: hub, style: rowStyle, columns: denseColumns, options: opts, hostRemove: removeAction(for: t))
        }
    }

    /// Dense rows carry their own columns: artist and length when compact, plus the album in a table; narrow widths drop the album, then the artist.
    private var denseColumns: MusicTrackColumns {
        MusicTrackColumns(shown: rowStyle == .table ? [.artist, .album, .duration] : [.artist, .duration]).effective(width: width)
    }

    /// Looks up the streams of the first visible rows (at most 3, see `MusicPreResolver`) so pressing play finds them ready. Every list page goes
    /// through here (search, playlists, artist, library, album). Scrolling replaces the hint, leaving the page cancels it; chart lists have their own.
    private func preResolveVisible() {
        guard chartHooks == nil, !visibleBox.rows.isEmpty else { return }
        let list = shown
        let first = visibleBox.rows.sorted().filter { $0 < list.count }.prefix(3).map { list[$0] }
        if !first.isEmpty { hub.player.preResolve(Array(first)) }
    }

    /// Warms the covers of the next rows past the lowest visible one: a bounded window, replaced as the list scrolls and cancelled when it leaves.
    private func prefetchBelow() {
        guard let owner = prefetchOwner, let last = visibleBox.rows.max() else { return }
        let list = shown
        guard last + 1 < list.count else { return }
        let window = list[(last + 1)..<min(list.count, last + 1 + MusicArtworkPrefetcher.defaultWindow)]
        let addresses = window.compactMap { $0.thumbnails.best(minSide: 56) }
        MusicArtworkPrefetcher.shared.prefetch(addresses: addresses, artworkClass: .trackThumb, scale: displayScale, priority: .low, owner: owner)
    }

    // MARK: tools

    private func tools(proxy: ScrollViewProxy, list: [MusicTrack]) -> some View {
        HStack(spacing: Spacing.sm) {
            filterField
            Spacer(minLength: Spacing.sm)
            if canSort { sortMenu }
            columnMenu
            toolButton(selection.active ? "checkmark.circle.fill" : "checkmark.circle", selection.active ? "Stop selecting" : "Select songs", "control.music.listSelect") {
                if selection.active { selection.exit() } else { selection.enter() }
            }
            toolButton("arrow.down.to.line", "Scroll to the end of the list", "control.music.listScrollEnd") {
                if let last = list.last { withAnimation(AnimationTokens.standard) { proxy.scrollTo(last.uid, anchor: .bottom) } }
            }
            // Cmd+A picks every row while selecting.
            Button("") { selection.selectAll(order) }.keyboardShortcut("a", modifiers: .command).opacity(0).frame(width: 0, height: 0).disabled(!selection.active).accessibilityHidden(true).atlas("control.music.songListsMusictracklisttoolsKeyboardShortcut")
        }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary)
            TextField("Filter this list", text: $filter).textFieldStyle(.plain).font(Typography.body).focused($filterFocused)
                .accessibilityLabel("Filter this list").atlas("control.music.listFilter")
                #if os(macOS)
                .onExitCommand { if filtering { filter = "" } else { filterFocused = false } }
                #endif
            if filtering {
                Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").font(MusicTokens.iconSmall).frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).accessibilityLabel("Clear filter").atlas("control.music.songListsClearFilter")
            }
        }
        .padding(.leading, 12).padding(.trailing, filtering ? 0 : 12).frame(width: 240, height: MusicTokens.hitTarget + 4)
        .podcastFieldStyle(focused: filterFocused, accent: accent)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: Binding(get: { ordering.field }, set: { setOrdering(MusicTrackOrdering(field: $0, ascending: ordering.ascending)) })) {
                ForEach(MusicTrackSortField.allCases) { f in Text(verbatim: f.title).tag(f) }
            }
            .pickerStyle(.inline).atlas("control.music.songListsSortBy")
            Divider()
            Button(ordering.ascending ? "Switch to descending" : "Switch to ascending", systemImage: ordering.ascending ? "arrow.down" : "arrow.up") {
                setOrdering(MusicTrackOrdering(field: ordering.field, ascending: !ordering.ascending))
            }.atlas("control.music.songListsSwitchToDescending")
        } label: {
            Image(systemName: ordering.isDefault ? "arrow.up.arrow.down" : (ordering.ascending ? "arrow.up.arrow.down.circle.fill" : "arrow.down.arrow.up.circle.fill"))
                .font(MusicTokens.iconMedium).foregroundStyle(ordering.isDefault ? ColorTokens.textSecondary : accent)
                .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().hoverHighlight()
        .help("Sort").accessibilityLabel("Sort the list").atlas("control.music.listSort")
    }

    private var columnMenu: some View {
        Menu {
            Text("Columns")
            ForEach(MusicTrackColumn.allCases) { c in
                Toggle(isOn: Binding(get: { columns.has(c) }, set: { _ in columns = columns.toggled(c); columns.save() })) { Text(verbatim: c.title) }.atlas("control.music.songListsMusictracklistcolumnmenuToggle")
            }
        } label: {
            Image(systemName: "tablecells").font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.textSecondary)
                .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().hoverHighlight()
        .help("Choose columns").accessibilityLabel("Choose columns").atlas("control.music.listColumns")
    }

    private func toolButton(_ symbol: String, _ label: String, _ atlasID: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(MusicTokens.iconMedium).foregroundStyle(selection.active && symbol.hasPrefix("checkmark") ? accent : ColorTokens.textSecondary)
                .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight().help(LocalizedStringKey(label)).accessibilityLabel(LocalizedStringKey(label)).atlas(atlasID).atlas("control.music.songListsMusictracklisttoolbuttonButton")
    }

    private var canReorder: Bool {
        MusicDragAndDrop.canReorder(filtered: filtering, sortedAwayFromDefault: ordering.field != .original, descending: !ordering.ascending,
                                    selecting: selection.active, saving: false, morePagesToLoad: hasMore, targetBeyondLoaded: false)
    }

    /// A song dragged from this list moves to the drop row; anything else is handed to the page as songs to add.
    private func drop(_ payload: MusicDragPayload, onto row: Int) {
        if payload.kind == .track, let from = tracks.firstIndex(where: { $0.uid == payload.uid }), let onMove, canReorder {
            if from != row && from + 1 != row { onMove(IndexSet(integer: from), row) }
            return
        }
        guard let onDropTracks else { return }
        Task { @MainActor in
            let list = await MusicEntityActions.tracks(payload.entity, hub: hub)
            if !list.isEmpty { onDropTracks(list) }
        }
    }

    private func setOrdering(_ o: MusicTrackOrdering) {
        ordering = o
        if let key = listKey { MusicOrderingMemory.save(o, for: key) }
    }

    // MARK: rows

    private func options(for t: MusicTrack, at i: Int, count: Int, cells: MusicTrackCells.Data) -> MusicRowOptions {
        var o = MusicRowOptions()
        o.columns = columns.effective(width: width)
        o.cellData = cells
        o.selecting = selection.active
        o.isSelected = selection.contains(t.uid)
        o.handleClick = { track, kind in selection.click(track.uid, order: order, kind: kind) }
        let box = visibleBox
        o.chart = chartHooks?(t)
        o.trailingDetail = trailingDetail?(t)
        let seen = onRowVisible
        o.onAppear = {
            seen?(t, true)
            box.rows.insert(i)
            box.touch { visibleTick += 1 }
            if i >= count - 3, hasMore, !loadingMore, !loadFailed { loadMore?() }
        }
        o.onDisappear = { seen?(t, false); box.rows.remove(i); box.touch { visibleTick += 1 } }
        return o
    }

    private func removeAction(for t: MusicTrack) -> (label: String, action: () -> Void)? {
        guard let onRemove else { return nil }
        return (removeLabel, { onRemove([t]) })
    }

    @ViewBuilder private var footer: some View {
        if loadingMore {
            HStack(spacing: 8) { MusicLoadingIcon(size: MusicIconSize.small); Text("Loading more songs…").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
                .frame(maxWidth: .infinity, minHeight: 44).accessibilityElement(children: .combine)
        } else if loadFailed {
            MusicLoadMoreFailedLine { retry?() }
        }
    }

    private var noMatch: some View {
        VStack(spacing: 6) {
            Text(verbatim: Localized.string("No songs match “%@”.", filter.trimmingCharacters(in: .whitespaces))).font(Typography.body).foregroundStyle(ColorTokens.textSecondary)
            if hasMore { Text("Still loading the rest of the list.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary) }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    /// With a filter on, the next pages keep coming in the background until something matches or the list ends.
    private func keepLoadingWhileFiltering() {
        guard filtering, hasMore, !loadingMore, !loadFailed, shown.count < 20 else { return }
        loadMore?()
    }

    // MARK: overlay (selection bar and jump pill)

    private func publish(list: [MusicTrack], proxy: ScrollViewProxy) {
        guard let host else { return }
        if selection.active {
            let picked = selection.ordered(list)
            host.bar = MusicPageOverlayHost.Bar(
                selected: picked, total: list.count, hiddenByFilter: filtering ? max(0, tracks.count - list.count) : 0, stillLoading: hasMore ? 1 : 0,
                onRemove: onRemove.map { remove in { remove(picked); selection.exit() } },
                selectAll: { selection.selectAll(list.map(\.uid)) }, clear: { selection.clear() }, exit: { selection.exit() })
        } else { host.bar = nil }
        let visible = visibleBox.rows
        if let cur = hub.player.current?.uid, let idx = snapshot.position[cur], !visible.isEmpty, !visible.contains(idx) {
            host.pill = MusicPageOverlayHost.Pill(above: idx < (visible.min() ?? 0)) { withAnimation(AnimationTokens.standard) { proxy.scrollTo(cur, anchor: .center) } }
        } else { host.pill = nil }
    }
}

/// "Couldn't load more. Try again": shown under a list in place of replacing the page when one more page fails.
struct MusicLoadMoreFailedLine: View {
    let retry: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Text("Couldn't load more.").font(Typography.body).foregroundStyle(ColorTokens.textSecondary)
            Button("Try again", action: retry).musicButton(.secondary, size: .compact)
                .frame(minHeight: MusicTokens.hitTarget).hoverHighlight().accessibilityLabel("Try loading more again").atlas("control.music.loadMoreRetry")
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}

/// The insertion line of a row that accepts a dragged song or card.
private struct MusicRowDropTarget: ViewModifier {
    let enabled: Bool
    let hub: MusicHub
    let canReorder: Bool
    let perform: @MainActor (MusicDragPayload) -> Void
    @State private var targeted = false
    @Environment(\.reddyAccent) private var accent

    func body(content: Content) -> some View {
        if enabled {
            content
                .overlay(alignment: .top) { if targeted { Rectangle().fill(accent).frame(height: 2).allowsHitTesting(false) } }
                .onDrop(of: [MusicDragKind.browseItem.contentType], isTargeted: $targeted) { providers in
                    guard let p = providers.first else { return false }
                    let box = MusicDropBox(perform)
                    p.loadDataRepresentation(forTypeIdentifier: MusicDragKind.browseItem.identifier) { data, _ in
                        guard let data, let payload = MusicDragPayload.decode(data) else { return }
                        Task { @MainActor in box.run(payload) }
                    }
                    return true
                }
        } else { content }
    }
}
