import SwiftUI

// What the Library tabs draw below the controls: collections of cards or rows, the history list, the empty and loading states.

/// Albums, artists or playlists as a grid of cards, a list or a compact list. Lazy; the covers just past the last visible one are warmed in a
/// bounded window under `owner` and dropped when the collection leaves.
struct MusicLibraryCollection<Item: Sendable, Card: View, Row: View>: View {
    let items: [Item]
    /// A stable, unique id for each item (the `uid` of a song, album or artist).
    let idPath: KeyPath<Item, String>
    let mode: MusicLibraryViewMode
    let owner: String
    let artworkClass: MusicArtworkClass
    let thumbs: (Item) -> [MusicThumbnail]
    @ViewBuilder var card: (Item) -> Card
    @ViewBuilder var row: (Item, Bool) -> Row
    @State private var seen = MusicVisibleRows()
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if mode == .grid {
                LazyVGrid(columns: MusicLayout.gridColumns, spacing: MusicSpace.md) {
                    ForEach(numbered) { n in
                        card(n.item).onAppear { note(n.index) }
                    }
                }
            } else {
                LazyVStack(spacing: MusicSpace.xxs) {
                    ForEach(numbered) { n in
                        row(n.item, mode == .compact).onAppear { note(n.index) }
                    }
                }
            }
        }
        .onDisappear { seen.cancel(); MusicArtworkPrefetcher.shared.cancel(owner: owner) }
    }

    private struct Numbered: Identifiable { let index: Int; let item: Item; let id: String }
    private var numbered: [Numbered] { items.indices.map { Numbered(index: $0, item: items[$0], id: items[$0][keyPath: idPath]) } }

    private func note(_ i: Int) {
        seen.rows.insert(i)
        seen.touch { warm() }
    }

    private func warm() {
        guard let last = seen.rows.max(), last + 1 < items.count else { return }
        let next = items[(last + 1)..<min(items.count, last + 1 + MusicArtworkPrefetcher.defaultWindow)]
        let addresses = next.compactMap { thumbs($0).best(minSide: artworkClass.requestPoints) }
        MusicArtworkPrefetcher.shared.prefetch(addresses: addresses, artworkClass: artworkClass, scale: displayScale, priority: .low, owner: owner)
        // Keep the set small: only the rows near the end matter.
        if seen.rows.count > 200 { seen.rows = seen.rows.filter { $0 > last - 100 } }
    }
}

/// An album, artist or playlist as one line: cover, name, a second line, a count on the right.
struct MusicLibraryEntityRow: View {
    let title: String
    var subtitle: String = ""
    var trailing: String = ""
    let thumbs: [MusicThumbnail]
    var round = false
    var compact = false
    var entity: MusicEntity?
    /// A playlist's song covers: its picture is a local 2x2 of the distinct ones (or the first alone) instead of the first song's cover.
    var members: [[MusicThumbnail]]?
    let hub: MusicHub
    let action: () -> Void
    @State private var hovering = false

    private var cover: CGFloat { compact ? MusicSpace.xl : MusicSpace.huge }

    var body: some View {
        HStack(spacing: MusicSpace.sm) {
            if let members {
                MusicPlaylistCoverArt(members: members, name: title, size: cover, corner: MusicCorner.control)
            } else {
                MusicArtwork(thumbs, size: cover, corner: round ? cover / 2 : MusicCorner.control,
                             subject: entity.map { MusicArtworkSubject.derive($0) } ?? (round ? MusicArtworkSubject.personNamed(title) : nil))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title).musicText(.body).foregroundStyle(ColorTokens.textPrimary).lineLimit(1)
                if !compact, !subtitle.isEmpty { Text(verbatim: subtitle).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if compact, !subtitle.isEmpty {
                Text(verbatim: subtitle).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !trailing.isEmpty { Text(verbatim: trailing).musicText(.secondary).monospacedDigit().foregroundStyle(ColorTokens.textTertiary) }
        }
        .padding(.horizontal, MusicSpace.sm).frame(height: compact ? MusicLibraryRowMetrics.compactHeight : MusicLibraryRowMetrics.tableHeight + MusicSpace.xs)
        .background(hovering ? ColorTokens.elevated : Color.clear, in: RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .contextMenu {
            if let entity {
                Button("Play", systemImage: "play.fill") { Task { await MusicEntityActions.play(entity, hub: hub) } }.atlas("control.music.libraryEntityPlay")
                Button("Shuffle", systemImage: "shuffle") { Task { await MusicEntityActions.play(entity, shuffle: true, hub: hub) } }.atlas("control.music.libraryEntityShuffle")
                Button("Add to Queue", systemImage: "text.badge.plus") { Task { await MusicEntityActions.addToQueue(entity, hub: hub) } }.atlas("control.music.libraryEntityQueue")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: [title, subtitle].filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
        .atlasCovers("control.music.libraryRow")
    }
}

/// The listening history as rows in time order, grouped by day, with the first page shown and a button for the next. One row per play, so the
/// same song can appear many times: rows are identified by position.
struct MusicLibraryHistoryList: View {
    let records: [PlayRecord]
    let mode: MusicLibraryViewMode
    let groupByDay: Bool
    let hub: MusicHub
    @State private var pages = 1

    var body: some View {
        let count = MusicLibraryHistoryPaging.visible(total: records.count, pages: pages)
        let slice = Array(records.prefix(count))
        let queue = slice.map(\.track)
        let dates = slice.map(\.at)
        LazyVStack(alignment: .leading, spacing: MusicSpace.xxs) {
            ForEach(slice.indices, id: \.self) { i in
                if groupByDay, MusicLibraryHistoryDays.startsDay(i, dates: dates) {
                    Text(verbatim: MusicHistoryLogic.dayLabel(dates[i])).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
                        .padding(.top, MusicSpace.sm).accessibilityAddTraits(.isHeader)
                }
                if mode == .compact {
                    MusicLibraryDenseRow(track: slice[i].track, index: i, queue: queue, hub: hub, style: .compact, columns: MusicTrackColumns(shown: [.artist, .duration]))
                } else {
                    MusicTrackRow(track: slice[i].track, index: nil, queue: queue, hub: hub)
                }
            }
            if count < records.count {
                Button { pages += 1 } label: { Text(verbatim: Localized.string("Show more (%d of %d)", count, records.count)) }
                    .musicButton(.secondary, size: .compact).frame(maxWidth: .infinity).padding(.top, MusicSpace.sm)
                    .accessibilityLabel("Show more history").atlas("control.music.libraryShowMore")
            }
        }
    }
}

// MARK: - states

/// Placeholders with the geometry of what will load: cards in a grid, or rows.
struct MusicLibrarySkeleton: View {
    let mode: MusicLibraryViewMode
    var body: some View {
        Group {
            if mode == .grid {
                LazyVGrid(columns: MusicLayout.gridColumns, spacing: MusicSpace.md) {
                    ForEach(0..<12, id: \.self) { _ in MusicSkeletonCard(width: MusicCardGeometry.defaultWidth) }
                }
            } else {
                VStack(spacing: MusicSpace.xxs) {
                    ForEach(0..<10, id: \.self) { _ in MusicSkeletonRow().frame(height: MusicLibraryRowMetrics.tableHeight).padding(.horizontal, MusicSpace.sm) }
                }
            }
        }
        .musicSkeletonPulse()
        .accessibilityElement(children: .ignore).accessibilityLabel("Loading your library")
    }
}

/// An empty tab: what it is for, and real ways to fill it. Each button opens something that already exists (the page performs it).
struct MusicLibraryEmptyView: View {
    let tab: MusicLibraryTab
    var perform: (MusicLibraryEmptyAction) -> Void

    private var copy: (title: String, message: String) {
        switch tab {
        case .songs: (Localized.string("Your library is empty"), Localized.string("Songs you like, playlists you make and music you bring in show up here."))
        case .albums: (Localized.string("No saved albums yet"), Localized.string("Save an album from its page and it will be kept here."))
        case .artists: (Localized.string("No followed artists yet"), Localized.string("Follow an artist from their page to find them here."))
        case .playlists: (Localized.string("No playlists yet"), Localized.string("Make a playlist, or bring ones you already have."))
        case .podcasts: (Localized.string("No saved episodes yet"), Localized.string("Episodes you like are listed here."))
        case .history: (Localized.string("Nothing played yet"), Localized.string("Songs you play are listed here, on this device only."))
        case .local: (Localized.string("No local files yet"), Localized.string("Add a music folder to play files stored on this Mac. Nothing is uploaded."))
        }
    }

    var body: some View {
        VStack(spacing: MusicSpace.md) {
            MusicEmptyState(glyph: tab == .history ? .note : .emptyLibrary, title: copy.title, message: copy.message)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: MusicSpace.sm, alignment: .top)], spacing: MusicSpace.sm) {
                ForEach(MusicLibraryEmptyAction.actions(for: tab)) { a in
                    Button { perform(a) } label: {
                        HStack(alignment: .top, spacing: MusicSpace.sm) {
                            Image(systemName: a.symbol).font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.textSecondary).frame(width: MusicSpace.xl)
                            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                                Text(verbatim: a.title).musicText(.card)
                                Text(verbatim: a.detail).musicText(.caption).foregroundStyle(ColorTokens.textSecondary).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(MusicSpace.sm).frame(maxWidth: .infinity, alignment: .leading)
                        .background(ColorTokens.elevated, in: RoundedRectangle(cornerRadius: MusicCorner.compactCard, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).hoverHighlight().accessibilityLabel(Text(verbatim: a.title)).accessibilityHint(Text(verbatim: a.detail))
                    .atlasCovers("control.music.libraryEmptyAction")
                }
            }
            .frame(maxWidth: 760)
        }
        .frame(maxWidth: .infinity)
    }
}
