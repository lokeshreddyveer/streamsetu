import SwiftUI

/// Movies and Series as one row per folder: "Name · count" and See all, about 12 tiles and a last "More ›" tile that opens the whole folder in the grid.
/// Lazy: a folder's tiles are read when its row first appears, the folder list grows 20 at a time, and a locked folder shows only its name and a lock.
struct FolderRowsView: View {
    let kind: ContentKind
    let posterWidth: CGFloat
    let memoryKey: String
    @Binding var topRow: String?
    let open: (FolderRowsModel.Row) -> Void
    @Environment(AppState.self) private var state
    @Environment(\.container) private var container
    @State private var model: FolderRowsModel

    init(kind: ContentKind, posterWidth: CGFloat, memoryKey: String, topRow: Binding<String?>, open: @escaping (FolderRowsModel.Row) -> Void) {
        self.kind = kind; self.posterWidth = posterWidth; self.memoryKey = memoryKey; _topRow = topRow; self.open = open
        _model = State(initialValue: FolderRowsModel(kind: kind))
    }

    private var reloadKey: String { "\(kind.rawValue)-\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)-\(state.folderLayoutRevision)-\(container?.parental.restrictionRevision ?? 0)-\(container?.profiles.activeID ?? "")" }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            if !model.loaded {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        FolderSkeleton(width: 160, height: 16, radius: 4).padding(.horizontal, 16)
                        HStack(spacing: 12) { ForEach(0..<4, id: \.self) { _ in FolderSkeleton(width: posterWidth, height: posterWidth * 1.5, radius: 8) } }.padding(.horizontal, 16)
                    }
                }
            } else if model.rows.isEmpty {
                EmptyState(symbol: "folder", title: "No folders yet", message: state.isSyncing ? "Folders appear as soon as the playlist has been read." : "This playlist has no \(kind == .movie ? "movie" : "series") folders.")
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                ForEach(model.visible) { row in
                    FolderRowCell(row: row, kind: kind, posterWidth: posterWidth, model: model, open: open).id(row.id)
                        .onAppear { if row.id == model.visible.last?.id { model.more() } }
                }
                if model.hasMore { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8) }
            }
        }
        .scrollTargetLayout().atlasScreen("screen.ios.folderRows")
        .padding(.top, 8)
        .task(id: reloadKey) {
            guard let c = container else { return }
            await model.reload(c, sourceID: state.activeSourceID, profile: c.profiles.activeID, restrictionKey: "\(c.parental.restrictionRevision)-\(c.profiles.activeID)-\(state.activeSourceID?.uuidString ?? "")")
            if topRow == nil, let saved = FolderScrollMemory.shared.get(memoryKey), model.reveal(saved) { topRow = saved }
        }
        .onChange(of: topRow) { _, id in if let id { FolderScrollMemory.shared.set(memoryKey, id) } }
    }
}

private struct FolderRowCell: View {
    let row: FolderRowsModel.Row
    let kind: ContentKind
    let posterWidth: CGFloat
    let model: FolderRowsModel
    let open: (FolderRowsModel.Row) -> Void
    @Environment(AppState.self) private var state
    @Environment(\.container) private var container

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open(row) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    FolderHeaderLabel(row: row, noun: .title)
                    Spacer(minLength: 8)
                    Text(row.locked ? "Open" : "See all").appFont(13, .medium).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").appFont(11, .semibold).foregroundStyle(.secondary).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.horizontal, 16)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(row.accessibilityTitle(.title))
            .accessibilityHint(row.locked ? "Asks for the PIN" : "Opens the whole folder")
            .atlas("control.ios.folderRows.openFolder")
            if !row.locked {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        if let items = model.tiles[row.id] {
                            ForEach(items) { item in
                                NavigationLink(value: item) { PosterCard(item: item, width: posterWidth, folderLine: .some(FolderTileLine.line(for: item, folder: row.name))) }.buttonStyle(.press).titleTileMenu(item).atlas("context.tile.menu")
                            }
                            Button { open(row) } label: {
                                VStack(spacing: 6) { Image(systemName: "chevron.right.circle").appFont(26); Text("More ›").appFont(14, .medium) }
                                    .foregroundStyle(.secondary).frame(width: posterWidth, height: posterWidth * 1.5)
                                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.press).accessibilityLabel("More in \(row.display)")
                            .atlas("control.ios.folderRows.more")
                        } else {
                            ForEach(0..<5, id: \.self) { _ in FolderSkeleton(width: posterWidth, height: posterWidth * 1.5, radius: 8) }
                        }
                    }.padding(.horizontal, 16)
                }
            }
        }
        .task(id: "\(model.epoch)-\(row.id)-\(row.locked)") { if let c = container { await model.ensureTiles(row, c, sourceID: state.activeSourceID, profile: c.profiles.activeID) } }
    }
}

/// A still placeholder (no shimmer, so nothing moves while the list scrolls or when Reduce Motion is on).
private struct FolderSkeleton: View {
    let width: CGFloat, height: CGFloat, radius: CGFloat
    var body: some View { RoundedRectangle(cornerRadius: radius).fill(Color.secondary.opacity(0.18)).frame(width: width, height: height).accessibilityHidden(true) }
}

/// Live TV as rows: Favourites and Recently Watched first, then each folder with its first channels (the provider's own order, never shuffled), what is on now and how far along it is.
struct LiveFolderRowsView: View {
    let play: (Channel, [Channel]) -> Void
    let open: (FolderRowsModel.Row) -> Void
    @Environment(AppState.self) private var state
    @Environment(\.container) private var container
    @State private var model = FolderRowsModel(kind: .channel)
    @State private var topRow: String?

    private var reloadKey: String { "\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)-\(state.folderLayoutRevision)-\(container?.parental.restrictionRevision ?? 0)-\(container?.profiles.activeID ?? "")" }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if !model.loaded {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            FolderSkeleton(width: 150, height: 16, radius: 4)
                            HStack(spacing: 12) { ForEach(0..<4, id: \.self) { _ in FolderSkeleton(width: 96, height: 96, radius: 12) } }
                        }.padding(.horizontal, 16)
                    }
                } else if model.rows.isEmpty {
                    EmptyState(symbol: "tv", title: "No channels yet", message: state.isSyncing ? "Channels appear as soon as the playlist has been read." : "This playlist has no live channels.").frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    ForEach(model.visible) { row in
                        LiveRowCell(row: row, model: model, play: play, open: open).id(row.id)
                            .onAppear { if row.id == model.visible.last?.id { model.more() } }
                    }
                }
            }
            .scrollTargetLayout().atlasScreen("screen.ios.folderRows").padding(.vertical, 8)
        }
        .scrollPosition(id: $topRow, anchor: .top)
        .task(id: reloadKey) {
            guard let c = container else { return }
            await model.reload(c, sourceID: state.activeSourceID, profile: c.profiles.activeID, restrictionKey: "\(c.parental.restrictionRevision)-\(c.profiles.activeID)-\(state.activeSourceID?.uuidString ?? "")")
            if topRow == nil, let saved = FolderScrollMemory.shared.get("live"), model.reveal(saved) { topRow = saved }
        }
        .onChange(of: topRow) { _, id in FolderScrollMemory.shared.set("live", id) }
    }
}

private struct LiveRowCell: View {
    let row: FolderRowsModel.Row
    let model: FolderRowsModel
    let play: (Channel, [Channel]) -> Void
    let open: (FolderRowsModel.Row) -> Void
    @Environment(AppState.self) private var state
    @Environment(\.container) private var container

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open(row) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    FolderHeaderLabel(row: row, noun: .channel)
                    Spacer(minLength: 8)
                    if row.special == nil { Text(row.locked ? "Open" : "See all").appFont(13, .medium).foregroundStyle(.secondary); Image(systemName: "chevron.right").appFont(11, .semibold).foregroundStyle(.secondary) }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.horizontal, 16).disabled(row.special != nil)
            .accessibilityAddTraits(.isHeader).accessibilityLabel(row.accessibilityTitle(.channel))
            .atlas("control.ios.folderRows.openFolder")
            if !row.locked {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        if let chans = model.channelTiles[row.id] {
                            ForEach(chans) { ch in
                                Button { play(ch, chans) } label: { tile(ch) }.buttonStyle(.press)
                            }
                            if row.special == nil {
                                Button { open(row) } label: {
                                    VStack(spacing: 6) { Image(systemName: "chevron.right.circle").appFont(24); Text("More ›").appFont(13, .medium) }
                                        .foregroundStyle(.secondary).frame(width: 104, height: 96).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(.press).accessibilityLabel("More in \(row.display)")
                                .atlas("control.ios.folderRows.more")
                            }
                        } else {
                            ForEach(0..<5, id: \.self) { _ in FolderSkeleton(width: 104, height: 120, radius: 12) }
                        }
                    }.padding(.horizontal, 16)
                }
            }
        }
        .task(id: "\(model.epoch)-\(row.id)-\(row.locked)") { if let c = container { await model.ensureTiles(row, c, sourceID: state.activeSourceID, profile: c.profiles.activeID) } }
    }

    private func tile(_ ch: Channel) -> some View {
        let p = model.onNow[ch.id]
        return VStack(spacing: 4) {
            ChannelLogo(url: ch.logoURL, name: ch.name, size: 72)
            Text(ch.name).appFont(11, .semibold).lineLimit(1).frame(width: 100)
            if let p {
                Text(p.title).appFont(10).foregroundStyle(.secondary).lineLimit(1).frame(width: 100)
                let total = max(1, p.end.timeIntervalSince(p.start)), done = min(1, max(0, Date().timeIntervalSince(p.start) / total))
                ProgressView(value: done).frame(width: 90).tint(ColorTokens.accentDefault).accessibilityHidden(true)
            }
        }
        .frame(width: 104)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ch.name)\(p.map { ", now \($0.title)" } ?? "")")
    }
}
