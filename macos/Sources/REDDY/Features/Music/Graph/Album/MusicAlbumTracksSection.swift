import SwiftUI

// The Tracks pill: the tracklist of this release in its own order, with a search box, a sort / filter that only changes the view (never the stored order),
// the playback modes menu, and per-disc collapse, play, shuffle and queue. Rows are the soundtrack page's own rows (the universal row and context menu).

struct MusicAlbumTracksSection: View {
    let page: MusicSoundtrackPageModel
    let extras: MusicAlbumExtrasModel
    @State private var query = ""
    @State private var sort = MusicAlbumTrackView.Sort.releaseOrder
    @State private var filter = MusicAlbumTrackView.Filter.all
    @State private var collapsed = Set<Int>()
    @State private var selecting = false
    @State private var selected = Set<String>()
    @FocusState private var focusedRow: MusicEntityID?
    private let memoryKey: String?

    init(page: MusicSoundtrackPageModel, extras: MusicAlbumExtrasModel, memoryKey: String? = nil) {
        self.page = page; self.extras = extras; self.memoryKey = memoryKey
        let f = memoryKey.map { MusicPageMemoryCenter.shared.memory(for: $0).filters } ?? [:]
        _query = State(initialValue: f["albumQuery"] ?? "")
        _sort = State(initialValue: f["albumSort"].flatMap(MusicAlbumTrackView.Sort.init(rawValue:)) ?? .releaseOrder)
        _filter = State(initialValue: f["albumFilter"].flatMap(MusicAlbumTrackView.Filter.init(rawValue:)) ?? .all)
        _collapsed = State(initialValue: Set((f["albumCollapsed"] ?? "").split(separator: ",").compactMap { Int($0) }))
    }

    private func remember() {
        guard let memoryKey else { return }
        let collapsedText = collapsed.sorted().map(String.init).joined(separator: ",")
        MusicPageMemoryCenter.shared.update(memoryKey) { m in
            m.filters["albumQuery"] = query.isEmpty ? nil : query
            m.filters["albumSort"] = sort == .releaseOrder ? nil : sort.rawValue
            m.filters["albumFilter"] = filter == .all ? nil : filter.rawValue
            m.filters["albumCollapsed"] = collapsedText.isEmpty ? nil : collapsedText
        }
    }

    private var hub: MusicHub { page.hub }
    private var liked: Set<String> { Set(hub.library.liked.map(\.uid)) }
    private var played: Set<String> { Set(hub.library.history.filter { HomeTaste.counts($0) }.map(\.track.uid)) }
    private var isPlainView: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty && sort == .releaseOrder && filter == .all }

    private var items: [MusicAlbumTrackItem] {
        page.rows.map { MusicAlbumTrackItem(id: $0.trackUID ?? $0.id.rawValue, title: $0.title, artistLine: $0.singerLine, disc: $0.disc, number: $0.number, durationMs: $0.durationMs, isPlayable: $0.isPlayable) }
    }

    private var rowsByID: [String: MusicSoundtrackSongRow] {
        Dictionary(page.rows.map { ($0.trackUID ?? $0.id.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            if page.rows.isEmpty {
                MusicSoundtrackSongsSection(page: page)
            } else {
                toolbar
                if selecting { selectionBar }
                let shown = MusicAlbumTrackView.view(items, query: query, sort: sort, filter: filter, liked: filter == .favourites ? liked : [], played: filter == .unplayed ? played : [])
                let byID = rowsByID
                let viewRows = shown.compactMap { byID[$0.id] }
                let visibleTracks = isPlainView ? nil : viewRows.compactMap { page.track(for: $0) }
                if viewRows.isEmpty {
                    Text("No songs match.").musicText(.secondary).foregroundStyle(ColorTokens.textTertiary).padding(.vertical, MusicSpace.md)
                } else if isPlainView {
                    let groups = MusicAlbumTrackView.discs(viewRows, disc: \.disc)
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                        if let d = g.disc { discHeader(d, count: g.items.count, durationMs: MusicAlbumTrackView.totalDurationMs(g.items.map(\.durationMs))) }
                        if g.disc == nil || !collapsed.contains(g.disc ?? 0) { rows(g.items, playList: visibleTracks) }
                    }
                } else {
                    rows(viewRows, playList: visibleTracks)
                }
                if page.songsNeedRetry {
                    HStack(spacing: MusicSpace.xs) {
                        Text("Some songs could not be loaded.").musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                        Button(Localized.string("Try again")) { page.retrySongs() }.musicButton(.tertiary, size: .compact, accentText: true).atlas("control.music.albumTracksRetry")
                    }
                    .padding(.horizontal, MusicSpace.xs)
                }
            }
        }
        .onChange(of: query) { _, _ in remember() }
        .onChange(of: sort) { _, _ in remember() }
        .onChange(of: filter) { _, _ in remember() }
        .onChange(of: collapsed) { _, _ in remember() }
        .task(id: "\(page.rows.count)|\(MusicEntityRuntime.shared.store.revision)") { extras.loadMakers(recordings: page.rows.map(\.id), force: true) }
    }

    private func rows(_ list: [MusicSoundtrackSongRow], playList: [MusicTrack]? = nil) -> some View {
        // Every row of `list` is drawn: the plain view hands over one expanded disc at a time, and a sorted or filtered view shows all its rows whatever is collapsed.
        let reachable = list
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(list) { row in
                MusicSoundtrackSongRowView(page: page, row: row, focus: $focusedRow, move: { step, end in move(from: row.id, by: step, toEnd: end, in: reachable) }, makers: extras.makers[row.id],
                                           selecting: selecting && row.trackUID != nil, selected: row.trackUID.map { selected.contains($0) } ?? false, toggleSelect: { toggle(row) }, playList: playList)
            }
        }
    }

    private func move(from id: MusicEntityID, by step: Int, toEnd: Bool, in list: [MusicSoundtrackSongRow]) {
        let ids = list.map(\.id)
        guard let i = ids.firstIndex(of: id), !ids.isEmpty else { return }
        focusedRow = toEnd ? (step < 0 ? ids.first : ids.last) : ids[max(0, min(ids.count - 1, i + step))]
    }

    // MARK: toolbar

    private var toolbar: some View {
        HStack(spacing: MusicSpace.xs) {
            HStack(spacing: MusicSpace.xxs) {
                Image(systemName: "magnifyingglass").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
                TextField(Localized.string("Search this album"), text: $query).textFieldStyle(.plain).atlas("control.music.albumTrackSearch")
            }
            .padding(.horizontal, MusicSpace.xs).frame(minHeight: MusicTokens.hitTarget)
            .background(ColorTokens.elevated, in: RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous))
            Menu {
                ForEach(MusicAlbumTrackView.Sort.allCases, id: \.self) { s in
                    Button { sort = s } label: { if sort == s { Label(sortTitle(s), systemImage: "checkmark") } else { Text(verbatim: sortTitle(s)) } }.atlas("control.music.albumTrackSort")
                }
                Divider()
                ForEach(MusicAlbumTrackView.Filter.allCases, id: \.self) { f in
                    Button { filter = f } label: { if filter == f { Label(filterTitle(f), systemImage: "checkmark") } else { Text(verbatim: filterTitle(f)) } }.atlas("control.music.albumTrackFilter")
                }
            } label: { Label(Localized.string("Sort and filter"), systemImage: "arrow.up.arrow.down") }
            .menuStyle(.button).musicButton(.secondary, size: .compact).fixedSize()
            .accessibilityLabel(Localized.string("Sort and filter")).atlas("control.music.albumTrackSortMenu")
            modesMenu
            Button { selecting.toggle(); if !selecting { selected = [] } } label: {
                Label(selecting ? Localized.string("Done") : Localized.string("Select"), systemImage: selecting ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .musicButton(.secondary, size: .compact).fixedSize().disabled(page.tracks.isEmpty).atlas("control.music.albumSelectToggle")
        }
    }

    // MARK: selection

    private func toggle(_ row: MusicSoundtrackSongRow) {
        guard let uid = row.trackUID else { return }
        if selected.contains(uid) { selected.remove(uid) } else { selected.insert(uid) }
    }

    /// The chosen songs in album order.
    /// The songs on screen under the current search and filter: what "Select all" selects.
    private var visibleUIDs: Set<String> {
        let shown = MusicAlbumTrackView.view(items, query: query, sort: sort, filter: filter, liked: filter == .favourites ? liked : [], played: filter == .unplayed ? played : [])
        let byID = rowsByID
        var rows = shown.compactMap { byID[$0.id] }
        // In the plain view the songs of a collapsed disc are not drawn, so "Select all" must not act on them (a sorted or filtered view shows every row).
        if isPlainView, !collapsed.isEmpty { rows = rows.filter { $0.disc == nil || !collapsed.contains($0.disc ?? 0) } }
        return Set(rows.compactMap(\.trackUID))
    }

    private var selectedTracks: [MusicTrack] { page.tracks.filter { selected.contains($0.uid) } }

    private var selectionBar: some View {
        HStack(spacing: MusicSpace.xs) {
            Text(verbatim: Localized.plural(selected.count, one: "%@ song selected", other: "%@ songs selected")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
            Spacer()
            Button(!visibleUIDs.isEmpty && visibleUIDs.isSubset(of: selected) ? Localized.string("Clear selection") : Localized.string("Select all")) {
                selected = visibleUIDs.isSubset(of: selected) ? [] : selected.union(visibleUIDs)
            }
            .musicButton(.tertiary, size: .compact, accentText: true).atlas("control.music.albumSelectAll")
            Button(Localized.string("Play Next"), systemImage: "text.insert") {
                let list = selectedTracks; guard !list.isEmpty else { return }
                if hub.player.playNext(list) { MusicToasts.shared.success(Localized.string("Playing next.")) }
            }
            .musicButton(.secondary, size: .compact).disabled(selected.isEmpty).atlas("control.music.albumSelectPlayNext")
            Button(Localized.string("Add to Queue"), systemImage: "text.append") {
                let list = selectedTracks; guard !list.isEmpty else { return }
                if hub.player.enqueue(list) { MusicToasts.shared.success(Localized.string("Added to the queue.")) }
            }
            .musicButton(.secondary, size: .compact).disabled(selected.isEmpty).atlas("control.music.albumSelectQueue")
            Button(Localized.string("Like"), systemImage: "heart") {
                let fresh = MusicAlbumPageLogic.toLike(selectedTracks, isLiked: { hub.library.isLiked($0) })
                guard !fresh.isEmpty else { return }
                for t in fresh { hub.library.toggleLike(t) }
                MusicToasts.shared.success(Localized.string("Added to Liked Songs."))
            }
            .musicButton(.secondary, size: .compact).disabled(selected.isEmpty).atlas("control.music.albumSelectLike")
            Button(Localized.string("Add to playlist"), systemImage: "music.note.list") { MusicChromeState.shared.addToPlaylist = selectedTracks }
                .musicButton(.secondary, size: .compact).disabled(selected.isEmpty).atlas("control.music.albumSelectPlaylist")
        }
        .padding(.horizontal, MusicSpace.xs)
    }

    private func sortTitle(_ s: MusicAlbumTrackView.Sort) -> String {
        switch s {
        case .releaseOrder: Localized.string("Album order")
        case .title: Localized.string("Title")
        case .duration: Localized.string("Longest first")
        }
    }
    private func filterTitle(_ f: MusicAlbumTrackView.Filter) -> String {
        switch f {
        case .all: Localized.string("All songs")
        case .favourites: Localized.string("Favourites only")
        case .unplayed: Localized.string("Unplayed only")
        }
    }

    private var discNumbers: [Int] { MusicAlbumTrackView.discNumbers(page.tracks.map(\.discNumber)) }

    private var modesMenu: some View {
        Menu {
            Button(Localized.string("Play in album order"), systemImage: "play.fill") { run(.sequence) }.atlas("control.music.albumPlayMode")
            Button(Localized.string("Shuffle album"), systemImage: "shuffle") { run(.shuffle) }.atlas("control.music.albumPlayMode")
            if let cur = hub.player.current?.uid, page.tracks.contains(where: { $0.uid == cur }) {
                Button(Localized.string("Continue album"), systemImage: "arrow.forward.circle") { run(.continueAlbum(currentUID: cur)) }.atlas("control.music.albumPlayMode")
            }
            Button(Localized.string("Favourites only"), systemImage: "heart") { run(.favouritesOnly) }.atlas("control.music.albumPlayMode")
            Button(Localized.string("Unplayed songs only"), systemImage: "sparkles") { run(.unplayedOnly) }.atlas("control.music.albumPlayMode")
            if discNumbers.count > 1 {
                Divider()
                ForEach(discNumbers, id: \.self) { d in
                    Button(Localized.string("Play disc %@", String(d)), systemImage: "opticaldisc") { run(.disc(d)) }.atlas("control.music.albumPlayMode")
                    Button(Localized.string("Shuffle disc %@", String(d)), systemImage: "shuffle") { run(.shuffleDisc(d)) }.atlas("control.music.albumPlayMode")
                }
            }
        } label: { Label(Localized.string("Play options"), systemImage: "play.circle") }
        .menuStyle(.button).musicButton(.secondary, size: .compact).fixedSize()
        .disabled(page.tracks.isEmpty)
        .accessibilityLabel(Localized.string("Play options")).atlas("control.music.albumPlayModesMenu")
    }

    private func run(_ mode: MusicAlbumPlaybackMode) {
        guard let plan = MusicAlbumPlayback.plan(mode, tracks: page.tracks, liked: liked, played: played) else {
            MusicToasts.shared.show(Localized.string("Nothing to play here yet.")); return
        }
        // Continue album: the song already playing keeps playing; only the rest of the album is queued after it.
        if case .continueAlbum(let uid?) = mode, hub.player.current?.uid == uid {
            let upcoming = Set(hub.player.queue.dropFirst((hub.player.index ?? -1) + 1).map(\.uid))
            let rest = MusicAlbumPlayback.continuation(page.tracks, currentUID: uid)
            let fresh = MusicAlbumPlayback.notQueued(rest, upcoming: upcoming)
            if !fresh.isEmpty { if hub.player.enqueue(fresh) { MusicToasts.shared.success(Localized.string("Added to the queue.")) } }
            else { MusicToasts.shared.show(rest.isEmpty ? Localized.string("This is the last song of the album.") : Localized.string("The rest of the album is already queued.")) }
            return
        }
        if plan.shuffled { hub.playShuffled(plan.tracks, sourceName: page.displayHeader?.title) } else { hub.play(plan.tracks, at: plan.startIndex, sourceName: page.displayHeader?.title) }
    }

    // MARK: discs

    private func discHeader(_ d: Int, count: Int, durationMs: Int64) -> some View {
        HStack(spacing: MusicSpace.xs) {
            Button {
                if collapsed.contains(d) { collapsed.remove(d) } else { collapsed.insert(d) }
            } label: {
                Label(Localized.string("Disc %@", String(d)), systemImage: collapsed.contains(d) ? "chevron.right" : "chevron.down").musicText(.caption).foregroundStyle(ColorTokens.textSecondary)
            }
            .buttonStyle(.plain).accessibilityLabel(collapsed.contains(d) ? Localized.string("Expand disc %@", String(d)) : Localized.string("Collapse disc %@", String(d)))
            .accessibilityAddTraits(.isHeader).atlas("control.music.albumDiscToggle")
            Text(verbatim: Localized.plural(count, one: "%@ song", other: "%@ songs") + (durationMs > 0 ? " · " + MusicDurationText.total(ms: durationMs) : "")).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
            Spacer()
            Menu {
                Button(Localized.string("Play disc"), systemImage: "play.fill") { run(.disc(d)) }.atlas("control.music.albumDiscMenu")
                Button(Localized.string("Shuffle disc"), systemImage: "shuffle") { run(.shuffleDisc(d)) }.atlas("control.music.albumDiscMenu")
                Button(Localized.string("Play Next"), systemImage: "text.insert") { queue(d, next: true) }.atlas("control.music.albumDiscMenu")
                Button(Localized.string("Add to Queue"), systemImage: "text.append") { queue(d, next: false) }.atlas("control.music.albumDiscMenu")
            } label: { Image(systemName: "ellipsis").font(MusicTokens.iconSmall) }
            .menuStyle(.button).menuIndicator(.hidden).musicButton(.icon, size: .compact).fixedSize()
            .accessibilityLabel(Localized.string("Disc %@", String(d))).atlas("control.music.albumDiscMenu")
        }
        .padding(.leading, MusicSpace.xs).padding(.top, MusicSpace.xs)
    }

    private func queue(_ d: Int, next: Bool) {
        let list = page.tracks.filter { ($0.discNumber ?? 1) == d }
        guard !list.isEmpty else { return }
        if next { if hub.player.playNext(list, from: page.displayHeader?.title) { MusicToasts.shared.success(Localized.string("Playing next.")) } }
        else if hub.player.enqueue(list, from: page.displayHeader?.title) { MusicToasts.shared.success(Localized.string("Added to the queue.")) }
    }
}
