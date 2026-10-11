import SwiftUI
import Observation

/// Folder order and visibility for one playlist and content type. The new order is shown at once, saved in the
/// background, and used by the sidebar everywhere.
@MainActor @Observable
final class FolderOrderViewModel {
    private(set) var folders: [CatalogCategory] = []
    private(set) var hidden: Set<String> = []
    private(set) var loading = false
    var message: String?

    func load(_ c: AppContainer, sourceID: UUID?, kind: ContentKind) async {
        loading = folders.isEmpty
        let r = await Task.detached { () -> ([CatalogCategory], Set<String>) in
            ((try? c.catalog.categories(sourceID: sourceID, kind: kind, includeHidden: true)) ?? [], Set((try? c.favoritesRepo.hiddenIDs(kind: "category")) ?? []))
        }.value
        folders = r.0; hidden = r.1; loading = false
    }

    func move(from: IndexSet, to: Int, _ c: AppContainer, _ state: AppState) {
        folders.move(fromOffsets: from, toOffset: to)
        save(c, state)
    }

    func shift(_ id: String, by delta: Int, toEdge: Bool = false, _ c: AppContainer, _ state: AppState) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        let j = toEdge ? (delta < 0 ? 0 : folders.count - 1) : min(max(0, i + delta), folders.count - 1)
        guard j != i else { return }
        let item = folders.remove(at: i)
        folders.insert(item, at: j)
        save(c, state)
    }

    func sortAlphabetically(_ c: AppContainer, _ state: AppState) {
        folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save(c, state)
    }

    func resetToProviderOrder(_ c: AppContainer, _ state: AppState, sourceID: UUID?, kind: ContentKind) {
        let ids = folders.map(\.id)
        Task {
            await Task.detached { try? c.catalog.clearFolderOrder(ids) }.value
            await load(c, sourceID: sourceID, kind: kind)
            state.reloadFolders()
            say("Back to the provider's order")
        }
    }

    func setHidden(_ on: Bool, _ id: String, _ c: AppContainer, _ state: AppState) {
        if on { hidden.insert(id) } else { hidden.remove(id) }
        Task {
            await Task.detached { if on { try? c.favoritesRepo.hide(id, kind: "category") } else { try? c.favoritesRepo.unhide(id) } }.value
            state.reloadFolders()
        }
    }

    private func save(_ c: AppContainer, _ state: AppState) {
        let ids = folders.map(\.id)
        Task {
            await Task.detached { try? c.catalog.setFolderOrder(ids) }.value
            state.reloadFolders()
            say("Order saved")
        }
    }

    private func say(_ text: String) {
        message = text
        Task { try? await Task.sleep(nanoseconds: 2_200_000_000); if message == text { message = nil } }
    }
}

struct FoldersPane: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @State private var vm = FolderOrderViewModel()
    @State private var kind: ContentKind = .channel
    @State private var sourceID: UUID?
    @State private var query = ""

    private var shown: [CatalogCategory] { query.isEmpty ? vm.folders : vm.folders.filter { $0.name.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Type", selection: $kind) { Text("Live TV").tag(ContentKind.channel); Text("Movies").tag(ContentKind.movie); Text("Series").tag(ContentKind.series) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                if state.sources.count > 1 {
                    Picker("Playlist", selection: $sourceID) { ForEach(state.sources) { Text($0.name).tag(UUID?.some($0.id)) } }.pickerStyle(.menu).labelsHidden().fixedSize()
                }
                InlineSearchField(text: $query, prompt: "Find a folder").frame(maxWidth: 240)
                Spacer()
                if let m = vm.message { Text(m).font(Typography.caption).foregroundStyle(ColorTokens.success).transition(.opacity) }
                Menu {
                    Button("Sort A–Z") { if let c = container { vm.sortAlphabetically(c, state) } }
                    Button("Back to provider order") { if let c = container { vm.resetToProviderOrder(c, state, sourceID: sourceID, kind: kind) } }
                } label: { Label("Order", systemImage: "arrow.up.arrow.down") }.menuStyle(.button).fixedSize()
            }.padding(.horizontal, 20).padding(.vertical, 10)
            Text("Drag a folder, or use the arrows, to put it where you want it in the sidebar. Hidden folders stay in your library.")
                .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 8)
            Divider().overlay(ColorTokens.line)
            if vm.loading { LoadingView(label: "Loading folders…") }
            else if vm.folders.isEmpty { EmptyStateView(symbol: "folder", title: "No folders", message: "This playlist has no folders for this type yet.") }
            else {
                List {
                    ForEach(shown) { f in
                        FolderRow(folder: f, hidden: vm.hidden.contains(f.id), canReorder: query.isEmpty,
                                  lock: container?.parental.hasPIN == true ? (container?.parental.isLocked(f.id) ?? false) : nil,
                                  onLock: { if let p = container?.parental { if !p.setFolder(f.id, locked: $0) { router.modal = .unlockRestricted } } },
                                  onHide: { if let c = container { vm.setHidden($0, f.id, c, state) } },
                                  onShift: { d, edge in if let c = container { vm.shift(f.id, by: d, toEdge: edge, c, state) } })
                            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)).listRowSeparator(.hidden).listRowBackground(Color.clear)
                    }
                    .onMove(perform: query.isEmpty ? { from, to in if let c = container { vm.move(from: from, to: to, c, state) } } : nil)
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
        .task(id: "\(kind.rawValue)-\(sourceID?.uuidString ?? "")-\(state.catalogVersion)") {
            if sourceID == nil { sourceID = state.activeSourceID }
            if let c = container { await vm.load(c, sourceID: sourceID ?? state.activeSourceID, kind: kind) }
        }
    }
}

private struct FolderRow: View {
    let folder: CatalogCategory
    let hidden: Bool
    let canReorder: Bool
    /// nil when no PIN exists (no lock control); otherwise whether this folder is locked.
    var lock: Bool?
    var onLock: (Bool) -> Void = { _ in }
    let onHide: (Bool) -> Void
    let onShift: (Int, Bool) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").font(.system(size: 12)).foregroundStyle(canReorder ? ColorTokens.textTertiary : ColorTokens.textTertiary.opacity(0.3)).frame(width: 18)
            Image(systemName: FolderIcons.symbol(for: folder.name)).font(.system(size: 13)).foregroundStyle(ColorTokens.textSecondary).frame(width: 18)
            Text(folder.name).font(Typography.rowMedium).lineLimit(1)
            Text(folder.itemCount.formatted()).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            Spacer()
            if canReorder {
                HStack(spacing: 2) {
                    arrow("arrow.up.to.line", "Move to top") { onShift(-1, true) }
                    arrow("chevron.up", "Move up") { onShift(-1, false) }
                    arrow("chevron.down", "Move down") { onShift(1, false) }
                    arrow("arrow.down.to.line", "Move to bottom") { onShift(1, true) }
                }.opacity(hovering ? 1 : 0)
            }
            if let lock {
                Button { onLock(!lock) } label: { Image(systemName: lock ? "lock.fill" : "lock.open").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(lock ? ColorTokens.warning : ColorTokens.textTertiary).help(lock ? "Locked with PIN — click to unlock" : "Lock with PIN").accessibilityLabel(lock ? "Unlock folder \(folder.name)" : "Lock folder \(folder.name)")
            }
            Button { onHide(!hidden) } label: { Label(hidden ? "Hidden" : "Visible", systemImage: hidden ? "eye.slash.fill" : "eye").labelStyle(.iconOnly).font(.system(size: 13)) }
                .buttonStyle(.plain).foregroundStyle(hidden ? ColorTokens.warning : ColorTokens.textSecondary).help(hidden ? "Hidden from the sidebar — click to show" : "Hide from the sidebar").accessibilityLabel(hidden ? "Show folder \(folder.name) in the sidebar" : "Hide folder \(folder.name) from the sidebar")
        }
        .padding(.horizontal, 10).frame(height: 40).opacity(hidden ? 0.5 : 1)
        .background(hovering ? Color.white.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .animation(AnimationTokens.quick, value: hovering)
    }

    private func arrow(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).help(help).accessibilityLabel(help)
    }
}
