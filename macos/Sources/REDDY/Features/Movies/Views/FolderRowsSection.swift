import SwiftUI

/// Movies and Series as one row per folder: "Name · count" and See all, about 12 tiles, and a last "More ›" tile that opens the whole folder in the grid
/// (with its sort, filter and search). Rows are lazy: a folder's tiles are read the first time its row appears, and the list grows 20 folders at a time.
struct FolderRowsSection: View {
    let kind: ContentKind
    let memoryKey: String
    @Binding var topRow: String?
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @State private var model: FolderRowsModel

    init(kind: ContentKind, memoryKey: String, topRow: Binding<String?>) {
        self.kind = kind; self.memoryKey = memoryKey; _topRow = topRow; _model = State(initialValue: FolderRowsModel(kind: kind))
    }

    private var reloadKey: String { "\(kind.rawValue)-\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)-\(container?.parental.restrictionRevision ?? 0)-\(container?.profiles.activeID ?? "")" }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            if !model.loaded {
                ForEach(0..<3, id: \.self) { _ in skeleton }
            } else if model.rows.isEmpty {
                EmptyStateView(symbol: "folder", title: "No folders yet", message: "This playlist has no \(kind == .movie ? "movie" : "series") folders, or it is still loading.").frame(height: 240)
            } else {
                ForEach(model.visible) { row in
                    FolderRowView(row: row, kind: kind, model: model).id(row.id)
                        .onAppear { if row.id == model.visible.last?.id { model.more() } }
                }
                if model.hasMore { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 8) }
            }
        }
        .scrollTargetLayout()
        .task(id: reloadKey) {
            guard let c = container else { return }
            await model.reload(c, sourceID: state.activeSourceID, profile: c.profiles.activeID, restrictionKey: "\(c.parental.restrictionRevision)-\(c.profiles.activeID)-\(state.activeSourceID?.uuidString ?? "")")
            if topRow == nil, let saved = FolderScrollMemory.shared.get(memoryKey), model.reveal(saved) { topRow = saved }
        }
        .onChange(of: topRow) { _, id in if let id { FolderScrollMemory.shared.set(memoryKey, id) } }          // nil only means "not set" (a profile switch), never "scrolled to nothing"
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonBlock(width: 180, height: 16, radius: 4)
            HStack(spacing: 11) { ForEach(0..<7, id: \.self) { _ in SkeletonBlock(width: 130, height: 190, radius: 8) } }
        }
    }
}

private struct FolderRowView: View {
    let row: FolderRowsModel.Row
    let kind: ContentKind
    let model: FolderRowsModel
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tab: AppTab { kind == .movie ? .movies : .series }
    private func open() {
        container?.smartMix.noteFolderOpened(profile: container?.profiles.activeID ?? "main", categoryID: row.id)
        router.openFolder(tab, categoryID: row.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if row.locked { Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(ColorTokens.textSecondary) }
                Text(row.display).font(.system(size: 16, weight: .semibold)).tracking(-0.2).lineLimit(1).truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader).accessibilityLabel(row.accessibilityTitle)
                // The count is quiet: smaller, dim, in brackets, on the name's baseline, and it never wraps or gets cut before the name does.
                if !row.locked { Text(row.countText).font(.system(size: 12)).foregroundStyle(ColorTokens.textTertiary).lineLimit(1).fixedSize().layoutPriority(1) }
                Spacer(minLength: 8)
                Button(action: open) {
                    HStack(spacing: 3) { Text(row.locked ? "Open" : "See all"); Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
                }.buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
                    .accessibilityLabel(row.locked ? "Open \(row.spokenName), asks for the PIN" : "See all in \(row.spokenName)")
            }
            if !row.locked { tiles }
        }
        .accessibilityElement(children: .contain)
        .task(id: "\(model.epoch)-\(row.id)-\(row.locked)") { if let c = container { await model.ensureTiles(row, c, sourceID: state.activeSourceID, profile: c.profiles.activeID) } }
    }

    @ViewBuilder private var tiles: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 11) {
                if let items = model.tiles[row.id] {
                    ForEach(items) { item in LibraryItemCard(item: item, width: 130, folderLine: .some(FolderTileLine.line(for: item, folder: row.name))) }
                    moreTile
                } else {
                    ForEach(0..<8, id: \.self) { _ in SkeletonBlock(width: 130, height: 190, radius: 8) }
                }
            }.padding(.vertical, 10).padding(.horizontal, 5)
        }
        .scrollIndicators(.hidden).padding(.vertical, -8).padding(.horizontal, -5)
    }

    private var moreTile: some View {
        Button(action: open) {
            VStack(spacing: 8) {
                Image(systemName: "chevron.right.circle").font(.system(size: 26, weight: .light))
                Text("More ›").font(Typography.bodyMedium)
            }
            .foregroundStyle(ColorTokens.textSecondary)
            .frame(width: 130, height: 190).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).focusable().onKeyPress(.return) { open(); return .handled }
        .accessibilityLabel("More in \(row.display)")
    }
}
