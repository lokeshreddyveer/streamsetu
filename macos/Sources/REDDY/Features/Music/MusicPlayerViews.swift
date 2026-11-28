import SwiftUI
import UniformTypeIdentifiers

// Shared player helpers and the queue. They read the player only; nothing here runs a timer or a repeating animation, so an idle or paused
// player costs nothing.

// MARK: pure helpers (tested without a view)

enum MusicStreamLabel {
    /// A short quality badge such as "AAC 256 kbps" or "FLAC 44.1 kHz".
    static func text(_ s: MusicStream) -> String {
        let codec = s.codec.uppercased()
        if s.isLossless {
            let khz = (s.sampleRate ?? 0) > 0 ? " " + String(format: "%g", Double(s.sampleRate ?? 0) / 1000) + " kHz" : ""
            return (codec.isEmpty ? "Lossless" : codec) + khz
        }
        if let b = s.bitrate, b > 0 { return (codec.isEmpty ? "Audio" : codec) + " \(b) kbps" }
        return codec.isEmpty ? "Audio" : codec
    }
}

enum MusicLyricsLogic {
    /// Index of the line being sung at `ms`: the last line that starts at or before it. Nil before the first line.
    static func lineIndex(in lines: [MusicLyricLine], atMs ms: Int64) -> Int? {
        guard !lines.isEmpty, ms >= lines[0].timeMs else { return nil }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].timeMs <= ms { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

enum MusicQueueLogic {
    /// SwiftUI's `onMove` gives the insertion offset in the ORIGINAL list; the player wants the final index.
    static func finalIndex(from: Int, insertionOffset: Int) -> Int { insertionOffset > from ? insertionOffset - 1 : insertionOffset }
    /// Indices of the tracks after the current one.
    static func upNext(count: Int, current: Int?) -> Range<Int> {
        let start = (current ?? -1) + 1
        return start < count ? start..<count : 0..<0
    }
    /// "Keep" turns a row the app chose into the person's own: a suggestion anywhere, an autoplay row only while it is still to come (a played one has nothing left to keep).
    static func offersKeep(_ e: MusicQueue.Entry, past: Bool) -> Bool { e.suggested || (e.auto && !past) }

    static func nextRepeat(_ m: MusicRepeat) -> MusicRepeat {
        switch m { case .off: .all; case .all: .one; case .one: .off }
    }

    /// "12 songs left - 1 hr 23 min": only rows after the playing one and before the first endless-playback row count; rows without a
    /// length count as zero; the time is rounded to the minute and left out under a minute. The words come from the language tables.
    static func remainingSummary(rows: [MusicQueue.Entry], current: Int?) -> String {
        guard let c = current, c + 1 < rows.count else { return "" }
        let upcoming = rows[(c + 1)...].prefix { !$0.auto }
        guard !upcoming.isEmpty else { return "" }
        var text = Localized.plural(upcoming.count, one: "%@ song left", other: "%@ songs left")
        let minutes = Int((upcoming.reduce(0.0) { $0 + max(0, $1.track.duration) } / 60).rounded())
        if minutes >= 1 { text += " - " + durationWords(minutes: minutes) }
        return text
    }

    /// "1 hr 23 min", "2 hr", "45 min".
    static func durationWords(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h > 0 { return m > 0 ? Localized.string("%1$d hr %2$d min", h, m) : Localized.string("%d hr", h) }
        return Localized.string("%d min", m)
    }
}

enum MusicLinks {
    static func artist(_ r: MusicArtistRef, providerID: String) -> MusicArtist { MusicArtist(id: r.id, providerID: providerID, name: r.name, thumbnails: r.thumbnails, externalURL: r.externalURL) }
    static func album(_ r: MusicAlbumRef, providerID: String) -> MusicAlbum {
        MusicAlbum(id: r.id, providerID: providerID, title: r.title, artists: r.artists, thumbnails: r.thumbnails, releaseDate: r.releaseDate, totalTracks: r.totalTracks, albumType: r.albumType, externalURL: r.externalURL)
    }
}

/// Which panel the host shows above the bar.
enum MusicPanel: String, Hashable { case nowPlaying, queue, lyrics }

// The bar lives in MusicPlayerBar.swift, the Now Playing panel in MusicNowPlayingPanel.swift, the bar's logic in MusicPlayerBarLogic.swift.

// MARK: lyrics
// The panel lives in Lyrics/MusicLyricsPanel.swift.

// MARK: room lock

extension View {
    /// Greys a transport control and explains why while this device follows a room host. Volume controls are never wrapped in this.
    func musicRoomLocked(_ locked: Bool) -> some View {
        self.disabled(locked)
            .opacity(locked ? 0.4 : 1)
            .overlay { if locked { Color.clear.contentShape(Rectangle()) } }
            .help(locked ? MusicRoomSession.lockExplanation : "")
            .accessibilityHint(locked ? MusicRoomSession.lockExplanation : "")
    }
}

// MARK: queue

/// Row frames for the drag's auto-scroll, kept outside the view's state: they change on every scroll frame and must not redraw the panel.
final class MusicQueueFrameBox {
    var frames: [UUID: CGRect] = [:]
    /// Drops the frames of rows that are no longer in the queue.
    func prune(keeping ids: Set<UUID>) {
        guard frames.count > ids.count else { return }
        frames = frames.filter { ids.contains($0.key) }
    }
}

/// The queue: played rows, the playing row, upcoming rows with their markers, and a divider before the endless-playback rows. Rows after the
/// playing one can be dragged to reorder; dragging near the top or bottom edge scrolls the list. The rows are grouped under Previously played, Now playing,
/// Play next, Up next and Autoplay; the list can be searched and rows can be selected and removed together.
struct MusicQueuePanel: View {
    let hub: MusicHub
    var player: MusicPlayer { hub.player }
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragging: Int?
    /// The id of the row being dragged: the payload carries a row number, and the queue can change under a drag (an autoplay merge, a removal).
    @State private var draggedID: UUID?
    @State private var dropAt: Int?
    @State private var topID: UUID?
    @State private var frameBox = MusicQueueFrameBox()
    @State private var boxHeight: CGFloat = 400
    @State private var scrollSpeed: CGFloat = 0
    @State private var lastDragOver = Date.distantPast
    @State private var scrollTask: Task<Void, Never>?
    @State private var carry: CGFloat = 0
    /// Windowed lists only: the first visible row (quantised, so the view changes once per row) and the spot the scroll anchor sits at.
    @State private var topRow = 0
    @State private var anchorY: CGFloat = 0
    @State private var searching = false
    @State private var query = ""
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var jumpRequest = 0
    @FocusState private var searchFocused: Bool

    private var editing: Bool { !hub.room.isFollowing }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var currentRowID: UUID? {
        guard let c = player.index, player.rows.indices.contains(c) else { return nil }
        return player.rows[c].id
    }

    var body: some View {
        let rows = player.rows
        VStack(alignment: .leading, spacing: 8) {
            header(rows)
            toolRow
            MusicStationRow(hub: hub)
            actionRow
            if searching { searchBar }
            if selecting { selectionBar(rows) }
            if editing, player.autoAddedCount > 0 { MusicAutoplayGroupButton(hub: hub) }
            if rows.isEmpty { MusicEmptyState(symbol: "list.bullet", title: Localized.string("The queue is empty"), message: Localized.string("Add tracks with Add to Queue or Play Next.")) }
            else if searching, !trimmedQuery.isEmpty { searchList(rows) }
            else { list(rows) }
        }
        .padding(.bottom, MusicSpace.xl)     // the panel is beside the floating bar, not under it
        .musicDropTracks(hub: hub) { if editing { player.enqueue($0) } }
        .onChange(of: rows.count) { _, _ in housekeeping() }
        .onChange(of: editing) { _, now in if !now { selecting = false; selected = [] } }
    }

    /// Row frames and the selection forget rows that left the queue.
    private func housekeeping() {
        let ids = Set(player.rows.map(\.id))
        frameBox.prune(keeping: ids)
        if !selected.isEmpty { selected = selected.intersection(ids) }
    }

    // MARK: header

    private func header(_ rows: [MusicQueue.Entry]) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("QUEUE").font(Typography.eyebrow).tracking(1.2).foregroundStyle(ColorTokens.textTertiary)
                if !rows.isEmpty {
                    if let s = MusicPlayingFrom.line(source: player.sourceName, providerNames: hub.registry.all.map { $0.info.name }) {
                        Text(verbatim: Localized.string("Playing from %@", s)).font(Typography.captionMedium).lineLimit(1).help(s)
                    }
                    let sum = MusicQueueLogic.remainingSummary(rows: rows, current: player.index)
                    if !sum.isEmpty { Text(verbatim: sum).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(2) }
                    if editing { MusicShuffleQueueMenu(hub: hub) }
                }
            }
            Spacer()
            if editing {
                HStack(spacing: 6) {
                    Text("Autoplay").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1).fixedSize()
                    Toggle("", isOn: Binding(get: { hub.library.settings.endlessPlayback }, set: { player.setAutoplay($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(accent).accessibilityLabel("Autoplay").atlas("control.music.playerAndQueueAutoplay")
                }
                .fixedSize().help("Keeps recommended music playing when the queue runs low.")
            }
        }
    }

    /// Search, select and the queue's own menu.
    @ViewBuilder private var toolRow: some View {
        if !player.rows.isEmpty {
            HStack(spacing: 4) {
                Button { toggleSearch() } label: {
                    Image(systemName: "magnifyingglass").font(MusicTokens.iconSmall)
                        .foregroundStyle(searching ? accent : ColorTokens.textSecondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hoverHighlight(radius: MusicCorner.control)
                .accessibilityLabel(Localized.string("Search the queue")).accessibilityAddTraits(searching ? .isSelected : [])
                .musicTooltip("Search the queue").atlas("control.music.queueSearchToggle")
                if editing {
                    Button { toggleSelecting() } label: {
                        Image(systemName: "checkmark.circle").font(MusicTokens.iconSmall)
                            .foregroundStyle(selecting ? accent : ColorTokens.textSecondary)
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).hoverHighlight(radius: MusicCorner.control)
                    .accessibilityLabel(Localized.string("Select songs")).accessibilityAddTraits(selecting ? .isSelected : [])
                    .musicTooltip("Select songs").atlas("control.music.queueSelectStart")
                    optionsMenu
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
            Button("Jump to current song", systemImage: "scope") { jumpRequest += 1 }.atlas("control.music.queueJumpCurrent")
            if player.shuffle {
                Button("Restore original order", systemImage: "arrow.uturn.backward") { player.shuffle = false }.atlas("control.music.queueRestoreOrder")
            }
            if player.backTitle != nil {
                Button("Back to the previous queue", systemImage: "arrow.uturn.backward.circle") { player.restorePreviousQueue() }.atlas("control.music.queueBackPrevious")
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textSecondary)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(Localized.string("Queue options")).musicTooltip("Queue options").atlas("control.music.queueOptionsMenu")
    }

    private func toggleSearch() {
        searching.toggle()
        if searching { searchFocused = true } else { query = ""; searchFocused = false }
    }

    private func toggleSelecting() {
        selecting.toggle()
        selected = []
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
            TextField("Search the queue", text: $query).textFieldStyle(.plain).font(Typography.body).focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(Localized.string("Clear search")).atlas("control.music.queueSearchClear")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(ColorTokens.elevated, in: RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous).strokeBorder(ColorTokens.line))
    }

    /// The bar over the list while songs are being picked: how many, pick every upcoming song, add them to a playlist, remove them, or finish.
    private func selectionBar(_ rows: [MusicQueue.Entry]) -> some View {
        let ids = MusicQueueSections.removableIDs(selected: selected, rows: rows, current: player.index)
        let upcoming = player.index.map { c in rows.indices.filter { $0 > c }.map { rows[$0].id } } ?? []
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: Localized.string("%@ selected", selected.count.formatted())).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
            MusicChipFlow(spacing: 14) {
                Button("Select upcoming") { selected = Set(upcoming) }
                    .buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(accent).lineLimit(1).fixedSize().atlas("control.music.queueSelectAll")
                Button("Add to playlist") { MusicChromeState.shared.addToPlaylist = rows.filter { selected.contains($0.id) }.map(\.track) }
                    .buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(accent).lineLimit(1).fixedSize().disabled(selected.isEmpty)
                    .atlas("control.music.queueSelectToPlaylist")
                Button("Remove") { player.removeRows(ids: ids); selected = [] }
                    .buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(ids.isEmpty ? ColorTokens.textTertiary : accent).lineLimit(1).fixedSize().disabled(ids.isEmpty)
                    .atlas("control.music.queueSelectRemove")
                Button("Done") { selecting = false; selected = [] }
                    .buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(accent).lineLimit(1).fixedSize().atlas("control.music.queueSelectDone")
            }
        }
    }

    @ViewBuilder private var actionRow: some View {
        if editing, player.backTitle != nil || player.hasManualRows || player.canUndoQueueEdit || player.canRedoQueueEdit || player.current != nil {
            // One line when it fits; in a narrow panel the links sit on two lines instead of breaking mid-word.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { actionsLead; Spacer(minLength: 0); actionsTrail }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 14) { actionsLead }
                    HStack(spacing: 14) { actionsTrail }
                }
            }
        }
    }

    @ViewBuilder private var actionsLead: some View {
        if let t = player.backTitle {
            Button { player.restorePreviousQueue() } label: { Label(Localized.string("Back to %@", t), systemImage: "arrow.uturn.backward").lineLimit(1).font(Typography.captionMedium) }
                .buttonStyle(.plain).foregroundStyle(accent).fixedSize().accessibilityLabel(Localized.string("Back to %@", t)).atlas("control.music.playerAndQueueBackTo")
        }
        if let cid = currentRowID {
            let armed = player.stopAfterEntryID == cid
            Button(armed ? "Stopping after this song" : "Stop after this song") { player.toggleStopAfterCurrent() }
                .buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(armed ? ColorTokens.textPrimary : accent).lineLimit(1).fixedSize()
                .accessibilityLabel(armed ? "Stopping after this song. Press to continue instead." : "Stop playback after this song").atlas("control.music.queueStopAfter")
        }
    }

    @ViewBuilder private var actionsTrail: some View {
        if player.hasManualRows || player.autoAddedCount > 0 || !player.queue.isEmpty {
            Button("Save as playlist") { MusicChromeState.shared.addToPlaylist = player.queue }
                .buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(accent).lineLimit(1).fixedSize()
                .accessibilityLabel("Save the queue as a playlist").atlas("control.music.queueSaveAsPlaylist")
        }
        if player.canUndoQueueEdit {
            Button("Undo") { player.undoQueueEdit() }.buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(accent).fixedSize()
                .modifier(MusicQueueUndoShortcut(active: !searchFocused, redo: false)).accessibilityLabel("Undo the last queue change").atlas("control.music.queueUndo")
        }
        if player.canRedoQueueEdit {
            Button("Redo") { player.redoQueueEdit() }.buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(accent).fixedSize()
                .modifier(MusicQueueUndoShortcut(active: !searchFocused, redo: true)).accessibilityLabel("Redo the queue change").atlas("control.music.queueRedo")
        }
        if player.upcomingCount > 0 {
            // Everything waiting after the playing song goes (Play next, Up next and Autoplay); the playing song and the ones already played stay, and Undo brings it all back.
            Button("Clear upcoming") { player.clearUpcoming() }.buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(accent).fixedSize()
                .accessibilityLabel("Clear the upcoming songs").atlas("control.music.playerAndQueueClearQueue")
        }
    }

    // MARK: list

    @ViewBuilder private func list(_ rows: [MusicQueue.Entry]) -> some View {
        if MusicQueueWindow.isWindowed(rowCount: rows.count) { windowedList(rows) } else { plainList(rows) }
    }

    /// The words typed in the search, matched against every row; the matching rows show without groups and cannot be dragged.
    private func searchList(_ rows: [MusicQueue.Entry]) -> some View {
        let hits = MusicQueueSections.matchingIndices(rows: rows, query: trimmedQuery)
        let cur = player.index
        return ScrollView {
            if hits.isEmpty {
                Text("No songs in the queue match").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).padding(.vertical, 12).frame(maxWidth: .infinity)
            }
            LazyVStack(spacing: 0) {
                ForEach(hits, id: \.self) { i in
                    row(rows[i], at: i, playing: i == cur, past: cur.map { i < $0 } ?? false, count: rows.count, reorderable: false)
                }
                Color.clear.frame(height: 48)
            }
        }
        .scrollIndicators(.hidden)
    }

    /// More than 200 rows: only the rows near the viewport (ten more above and below) are views; two spacers stand for the rest.
    private func windowedList(_ rows: [MusicQueue.Entry]) -> some View {
        let cur = player.index
        let firstAuto = cur.flatMap { c in rows.indices.first { $0 > c && rows[$0].auto } }
        let top = min(topRow, rows.count - 1)
        let layout = MusicQueueWindow.layout(rowCount: rows.count, headingAt: firstAuto,
                                             offset: MusicQueueWindow.rowY(top, headingAt: firstAuto), viewport: boxHeight)
        let range = layout.range.clamped(to: 0..<rows.count)
        let away = MusicQueueSections.currentIsOffscreen(current: cur, firstVisible: top, visibleCount: Int(boxHeight / MusicQueueDrag.rowHeight))
        return ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 0).background(GeometryReader { g in
                            Color.clear.preference(key: MusicQueueOffsetKey.self, value: -g.frame(in: .named("queueBox")).minY)
                        })
                        Color.clear.frame(height: layout.topPad)
                        ForEach(range, id: \.self) { i in
                            let e = rows[i]
                            if layout.showHeading, i == firstAuto { autoHeading }
                            row(e, at: i, playing: i == cur, past: cur.map { i < $0 } ?? false, count: rows.count)
                        }
                        Color.clear.frame(height: layout.bottomPad)
                        if dropAt == rows.count { Rectangle().fill(accent).frame(height: 2) }
                        if cur == rows.count - 1, !hub.library.settings.endlessPlayback, player.repeatMode == .off {
                            Text("The queue ends here.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).padding(.vertical, 10)
                        }
                        Color.clear.frame(height: 48)
                    }
                    Color.clear.frame(width: 1, height: 1).id(Self.anchorID).padding(.top, anchorY)
                }
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(name: "queueBox")
            .onPreferenceChange(MusicQueueOffsetKey.self) { y in
                let r = MusicQueueWindow.row(atOffset: y, rowCount: rows.count, headingAt: firstAuto)
                if r != topRow { topRow = r }
            }
            .background(GeometryReader { g in Color.clear.onAppear { boxHeight = g.size.height }.onChange(of: g.size.height) { _, h in boxHeight = h } })
            .overlay(alignment: .bottomTrailing) { if away, let c = cur { jumpButton(up: c < top) } }
            .onAppear {
                guard let c = cur, rows.indices.contains(c) else { return }
                jump(proxy, toRow: c, headingAt: firstAuto)
            }
            .onChange(of: jumpRequest) { _, _ in
                guard let c = cur, rows.indices.contains(c) else { return }
                jump(proxy, toRow: c, headingAt: firstAuto)
            }
            .onChange(of: scrollSpeed) { _, v in if v != 0 { startScrolling(proxy, rows: rows) } }
            .onDisappear { stopScrolling() }
        }
    }

    private static let anchorID = "music.queue.anchor"

    /// Scrolls so row `i` is at the top. The anchor is moved first and the scroll runs on the next turn, once it has its new place.
    private func jump(_ proxy: ScrollViewProxy, toRow i: Int, headingAt h: Int?) {
        anchorY = MusicQueueWindow.rowY(i, headingAt: h)
        Task { @MainActor in proxy.scrollTo(Self.anchorID, anchor: .top) }
    }

    private var autoHeading: some View {
        MusicAutoplayHeading(seedTitle: player.rows.last(where: { !$0.auto && !$0.suggested })?.track.title)
            .foregroundStyle(ColorTokens.textSecondary).frame(maxWidth: .infinity, alignment: .leading).frame(height: MusicQueueWindow.headingHeight)
            .overlay(alignment: .top) { Rectangle().fill(ColorTokens.line).frame(height: 1) }
    }

    /// The header in front of the first row of a part: Previously played, Now playing, Play next or Up next. (Autoplay keeps its own heading.)
    private func sectionHeader(_ s: MusicQueueSection, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: Localized.string(s.title)).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
            if s != .nowPlaying { Text(verbatim: count.formatted()).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary) }
            Spacer(minLength: 0)
        }
        .frame(height: MusicQueueWindow.headingHeight, alignment: .bottomLeading).padding(.bottom, 4)
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }

    private func plainList(_ rows: [MusicQueue.Entry]) -> some View {
        let cur = player.index
        let heads = MusicQueueSections.headers(rows: rows, current: cur)
        let counts = MusicQueueSections.counts(rows: rows, current: cur)
        let top = topID.flatMap { id in rows.firstIndex { $0.id == id } }
        let away = top.map { MusicQueueSections.currentIsOffscreen(current: cur, firstVisible: $0, visibleCount: Int(boxHeight / MusicQueueDrag.rowHeight)) } ?? false
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, e in
                        if let h = heads[i] {
                            if h == .autoplay { autoHeading } else { sectionHeader(h, count: counts[h] ?? 0) }
                        }
                        row(e, at: i, playing: i == cur, past: cur.map { i < $0 } ?? false, count: rows.count)
                    }
                    if dropAt == rows.count { Rectangle().fill(accent).frame(height: 2) }
                    if cur == rows.count - 1, !hub.library.settings.endlessPlayback, player.repeatMode == .off {
                        Text("The queue ends here.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).padding(.vertical, 10)
                    }
                    Color.clear.frame(height: 48)
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $topID, anchor: .top)
            .scrollIndicators(.hidden)
            .coordinateSpace(name: "queueBox")
            .background(GeometryReader { g in Color.clear.onAppear { boxHeight = g.size.height }.onChange(of: g.size.height) { _, h in boxHeight = h } })
            .overlay(alignment: .bottomTrailing) { if away, let c = cur, let t = top { jumpButton(up: c < t) } }
            .onAppear { if let c = cur, rows.indices.contains(c) { proxy.scrollTo(rows[c].id, anchor: .top) } }
            .onChange(of: jumpRequest) { _, _ in
                guard let c = cur, rows.indices.contains(c) else { return }
                withAnimation(MusicMotion.animation(.panel, reduce: reduceMotion)) { proxy.scrollTo(rows[c].id, anchor: .center) }
            }
            .onChange(of: scrollSpeed) { _, v in if v != 0 { startScrolling(proxy, rows: rows) } }
            .onDisappear { stopScrolling() }
        }
    }

    /// Shown while the playing song is out of sight: one press brings it back.
    private func jumpButton(up: Bool) -> some View {
        Button { jumpRequest += 1 } label: {
            Label(Localized.string("Current"), systemImage: up ? "arrow.up" : "arrow.down").font(Typography.captionMedium)
                .foregroundStyle(ColorTokens.textPrimary).padding(.horizontal, 10).padding(.vertical, 6)
                .background(ColorTokens.surface, in: Capsule()).overlay(Capsule().strokeBorder(ColorTokens.lineStrong)).contentShape(Capsule())
        }
        .buttonStyle(.plain).padding(8)
        .accessibilityLabel(Localized.string("Jump to current song")).musicTooltip("Jump to current song").atlas("control.music.queueJumpCurrent")
    }

    // MARK: rows

    private func row(_ e: MusicQueue.Entry, at i: Int, playing: Bool, past: Bool, count: Int, reorderable: Bool = true) -> some View {
        let t = e.track
        let canDrag = reorderable && !selecting && MusicQueueDrag.canDrag(row: i, playing: player.index, editingAllowed: editing)
        let picked = selected.contains(e.id)
        let stopsHere = player.stopAfterEntryID == e.id
        return HStack(spacing: 10) {
            Button {
                if selecting { toggleSelected(e.id) }
                else if editing, let k = indexOf(e.id) { player.jump(to: k) }
            } label: {
                HStack(spacing: 10) {
                    if selecting {
                        Image(systemName: picked ? "checkmark.circle.fill" : "circle").font(MusicTokens.iconSmall)
                            .foregroundStyle(picked ? accent : ColorTokens.textTertiary).accessibilityHidden(true)
                    }
                    MusicArtwork(track: t, size: 36, corner: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: MusicDisplayTitle.display(for: t)?.title ?? t.title).font(Typography.rowMedium).foregroundStyle(playing ? accent : ColorTokens.textPrimary).lineLimit(1)
                            .help(MusicDisplayTitle.display(for: t)?.raw ?? "")
                        HStack(spacing: 5) {
                            markers(e)
                            if stopsHere {
                                Image(systemName: "stop.circle").font(.system(size: 10)).foregroundStyle(accent).help("Playback stops after this song")
                            }
                            Text(verbatim: (e.auto || e.suggested) && e.reason != nil ? "\(t.displayArtistLine) \u{00B7} \(e.reason ?? "")" : t.displayArtistLine)
                                .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(verbatim: MusicTime.clock(t.duration)).font(Typography.timestamp).foregroundStyle(ColorTokens.textTertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            .accessibilityLabel(selecting ? Localized.string("Select %@", t.title) : (hub.room.controlsLocked ? Localized.string("Following the host") : Localized.string("Play %@", t.title)))
            .accessibilityAddTraits(picked ? .isSelected : [])
            .atlas("control.music.playerAndQueuePlay")
            .contextMenu { rowMenu(e, at: i, playing: playing, count: count) }
            if !selecting, !playing, editing, MusicQueueLogic.offersKeep(e, past: past) {
                Button { player.keepRow(id: e.id) } label: { Image(systemName: "plus.circle").font(.system(size: 11)).foregroundStyle(accent) }
                    .buttonStyle(.plain).help("Keep this song in the queue").accessibilityLabel(Localized.string("Keep %@ in the queue", t.title)).atlas("control.music.queueKeepAuto")
            }
            if !selecting, !playing, editing {
                Button { player.removeRows(ids: [e.id]) } label: { Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(ColorTokens.textTertiary) }
                    .buttonStyle(.plain).accessibilityLabel(Localized.string("Remove %@ from queue", t.title)).atlas("control.music.playerAndQueueRemoveFromQueue")
            }
        }
        .frame(height: MusicQueueDrag.rowHeight)
        .accessibilityAction(named: Text(Localized.string("Move up"))) { moveRow(e.id, .up) }
        .accessibilityAction(named: Text(Localized.string("Move down"))) { moveRow(e.id, .down) }
        .accessibilityAction(named: Text(Localized.string("Move to play next"))) { moveRow(e.id, .next) }
        .opacity(past ? 0.55 : (dragging == i ? MusicQueueDrag.draggedOpacity : 1))
        .background(playing ? accent.opacity(0.10) : (picked ? accent.opacity(0.06) : Color.clear))
        .overlay(alignment: .top) { if dropAt == i { Rectangle().fill(accent).frame(height: 2) } }
        .background(GeometryReader { g in Color.clear.onChange(of: g.frame(in: .named("queueBox"))) { _, f in frameBox.frames[e.id] = f }.onAppear { frameBox.frames[e.id] = g.frame(in: .named("queueBox")) } })
        .modifier(MusicQueueRowDrag(enabled: reorderable && !selecting && editing, canDrag: canDrag, row: i, delegate: MusicQueueDropDelegate(
            row: i, rowCount: count, player: player, enabled: canDrag || (editing && i > (player.index ?? -1)),
            frame: { [frameBox] in frameBox.frames[e.id] }, boxHeight: { boxHeight },
            draggedID: { draggedID },
            state: { dragging = $0; dropAt = $1; scrollSpeed = $2; if $2 != 0 { lastDragOver = Date() } }), onStart: { dragging = i; draggedID = e.id }))
        .accessibilityElement(children: .contain)
    }

    /// The small badges in front of the artists: how the row got into the queue.
    @ViewBuilder private func markers(_ e: MusicQueue.Entry) -> some View {
        if e.queued { marker(Localized.string("Next"), Localized.string("Added with Play Next")) }
        else if e.queuedEnd { marker(Localized.string("Queued"), e.queuedFrom.map { Localized.string("Added to the queue from %@", $0) } ?? Localized.string("Added to the queue")) }
        else if e.suggested { marker(Localized.string("Suggested"), Localized.string("Recommended by Smart Shuffle. Remove it or keep it.")) }
        else if e.auto { Image(systemName: "infinity").font(.system(size: 9)).foregroundStyle(ColorTokens.textTertiary).help("Added by autoplay") }
    }

    private func marker(_ text: String, _ help: String) -> some View {
        Text(verbatim: text).font(Typography.micro).foregroundStyle(accent).lineLimit(1).fixedSize().padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(accent.opacity(0.5))).help(help)
    }

    private func toggleSelected(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// The row's place now (rows can change between drawing and a press).
    private func indexOf(_ id: UUID) -> Int? { player.rows.firstIndex { $0.id == id } }

    private enum MoveTo { case up, down, next, bottom }

    /// The same reordering as dragging, found by the row's own id so a queue that changed since the menu opened cannot move the wrong row.
    private func moveRow(_ id: UUID, _ m: MoveTo) {
        guard editing, let from = indexOf(id), let c = player.index, from > c else { return }
        let count = player.rows.count
        let to: Int
        switch m {
        case .up: to = from - 1
        case .down: to = from + 1
        case .next: to = c + 1
        case .bottom: to = MusicQueueSections.bottomIndex(rows: player.rows, from: from, current: c)
        }
        guard to > c, to < count, to != from else { return }
        if m == .next { player.moveToPlayNext(from: from) } else { player.moveUpcoming(from: from, to: to) }
    }

    // MARK: row menu

    /// The universal song menu with the queue's own actions in front.
    @ViewBuilder private func rowMenu(_ e: MusicQueue.Entry, at i: Int, playing: Bool, count: Int) -> some View {
        if editing {
            queueRowItems(e, at: i, playing: playing, count: count)
            Divider()
        }
        MusicTrackMenuContent(track: e.track, hub: hub, hostRemove: removal(for: e, playing: playing))
    }

    private func removal(for e: MusicQueue.Entry, playing: Bool) -> (label: String, action: () -> Void)? {
        guard editing, !playing else { return nil }
        let id = e.id
        return (label: "Remove from Queue", action: { player.removeRows(ids: [id]) })
    }

    @ViewBuilder private func queueRowItems(_ e: MusicQueue.Entry, at i: Int, playing: Bool, count: Int) -> some View {
        if let c = player.index, i >= c {
            let armed = player.stopAfterEntryID == e.id
            Button(armed ? Localized.string("Keep playing after this song") : Localized.string("Stop after this song"), systemImage: "stop.circle") { player.toggleStopAfter(entryID: e.id) }
                .atlas("control.music.queueStopAfterRow")
            if i > c {
                if i - 1 > c { Button(Localized.string("Move Up"), systemImage: "arrow.up") { moveRow(e.id, .up) }.atlas("control.music.queueMoveUp") }
                if MusicQueueSections.canMoveDown(rows: player.rows, row: i) { Button(Localized.string("Move Down"), systemImage: "arrow.down") { moveRow(e.id, .down) }.atlas("control.music.queueMoveDown") }
                if i > c + 1 { Button(Localized.string("Move to Play Next"), systemImage: "text.insert") { moveRow(e.id, .next) }.atlas("control.music.queueMoveNext") }
                if MusicQueueSections.bottomIndex(rows: player.rows, from: i, current: c) != i { Button(Localized.string("Move to Bottom"), systemImage: "arrow.down.to.line") { moveRow(e.id, .bottom) }.atlas("control.music.queueMoveBottom") }
            }
        }
        if !selecting {
            Button(Localized.string("Select"), systemImage: "checkmark.circle") { selecting = true; selected = [e.id] }.atlas("control.music.queueSelectRow")
        }
    }

    /// The drag payload, registered under our own type and visible to this app only. Anything else dropped on the queue is refused.
    fileprivate static func provider(row: Int) -> NSItemProvider {
        let p = NSItemProvider()
        let data = Data(MusicDragGuard.payload(row: row).utf8)
        p.registerDataRepresentation(forTypeIdentifier: MusicDragKind.queueRow.identifier, visibility: .ownProcess) { done in done(data, nil); return nil }
        return p
    }

    // MARK: auto-scroll while dragging

    /// A timer step every 16 ms using real elapsed time (one step counts at most 100 ms), stopping on drop, drag end, or when no drag-over
    /// has arrived for three seconds.
    private func startScrolling(_ proxy: ScrollViewProxy, rows: [MusicQueue.Entry]) {
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(MusicQueueDrag.autoScrollStep * 1_000_000_000))
                let now = Date()
                let dt = now.timeIntervalSince(last); last = now
                if scrollSpeed == 0 || now.timeIntervalSince(lastDragOver) > MusicQueueDrag.autoScrollIdleStop { break }
                carry += MusicQueueDrag.autoScrollDistance(speed: scrollSpeed, elapsed: dt)
                let whole = Int(carry / MusicQueueDrag.rowHeight)
                guard whole != 0 else { continue }
                carry -= CGFloat(whole) * MusicQueueDrag.rowHeight
                let now2 = player.rows
                if MusicQueueWindow.isWindowed(rowCount: now2.count) {
                    let cur = player.index
                    let h = cur.flatMap { c in now2.indices.first { $0 > c && now2[$0].auto } }
                    jump(proxy, toRow: min(max(0, topRow + whole), max(0, now2.count - 1)), headingAt: h)
                    continue
                }
                let from = topID.flatMap { id in now2.firstIndex { $0.id == id } } ?? 0
                let target = min(max(0, from + whole), max(0, now2.count - 1))
                if now2.indices.contains(target) { proxy.scrollTo(now2[target].id, anchor: .top) }
            }
            scrollSpeed = 0
        }
    }

    private func stopScrolling() { scrollTask?.cancel(); scrollTask = nil; scrollSpeed = 0; carry = 0 }
}

/// Cmd-Z and Shift-Cmd-Z undo and redo a queue change, except while the queue's search field has focus (there they belong to the text field).
private struct MusicQueueUndoShortcut: ViewModifier {
    let active: Bool
    let redo: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if active { content.keyboardShortcut("z", modifiers: redo ? [.command, .shift] : .command) } else { content }
    }
}

/// Drag and drop for one queue row, applied only while reordering is allowed (not while searching or selecting).
private struct MusicQueueRowDrag: ViewModifier {
    let enabled: Bool
    let canDrag: Bool
    let row: Int
    let delegate: MusicQueueDropDelegate
    let onStart: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            if canDrag {
                content
                    .onDrag { onStart(); return MusicQueuePanel.provider(row: row) }
                    .onDrop(of: [MusicDragKind.queueRow.contentType], delegate: delegate)
            } else {
                content.onDrop(of: [MusicDragKind.queueRow.contentType], delegate: delegate)
            }
        } else {
            content
        }
    }
}

/// One row's drop target. The top half of a row means "in front of this row", the bottom half "in front of the next one".
private struct MusicQueueDropDelegate: DropDelegate {
    let row: Int
    let rowCount: Int
    let player: MusicPlayer
    let enabled: Bool
    let frame: () -> CGRect?
    let boxHeight: () -> CGFloat
    /// The row the drag started on, by id.
    let draggedID: () -> UUID?
    /// (dragging, dropAt, scroll speed)
    let state: (Int?, Int?, CGFloat) -> Void

    private func target(_ info: DropInfo) -> Int { MusicQueueDrag.dropIndex(overRow: row, yInRow: info.location.y) }

    /// Only our own queue-row drags: a file, link or text from elsewhere is refused before it can do anything.
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [MusicDragKind.queueRow.contentType]) }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? { update(info); return DropProposal(operation: enabled ? .move : .forbidden) }

    func dropExited(info: DropInfo) { state(nil, nil, 0) }

    func performDrop(info: DropInfo) -> Bool {
        defer { state(nil, nil, 0) }
        guard enabled, let provider = info.itemProviders(for: [MusicDragKind.queueRow.contentType]).first else { return false }
        let at = target(info)
        _ = provider.loadDataRepresentation(forTypeIdentifier: MusicDragKind.queueRow.identifier) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8), let from = MusicDragGuard.row(inPayload: text) else { return }
            Task { @MainActor in
                // The row at that number must still be the one that was picked up; a queue that changed mid-drag moves nothing.
                guard let id = draggedID(), player.rows.indices.contains(from), player.rows[from].id == id else { return }
                if let to = MusicQueueDrag.moveTarget(from: from, dropAt: at) { player.moveUpcoming(from: from, to: to) }
            }
        }
        return true
    }

    private func update(_ info: DropInfo) {
        let y = (frame()?.minY ?? 0) + info.location.y
        state(row, enabled ? target(info) : nil, MusicQueueDrag.autoScrollSpeed(pointerY: y, boxHeight: boxHeight()))
    }
}

/// The scroll offset of a windowed queue, read from a marker at the top of its content.
private struct MusicQueueOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
