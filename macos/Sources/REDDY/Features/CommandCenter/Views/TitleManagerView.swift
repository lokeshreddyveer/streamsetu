import SwiftUI

/// Organise the Movies or the Series of the open playlist locally, the way the Channel manager organises channels: find a title, hide or show it, favourite it,
/// save it for later, and reorder or hide whole folders. Nothing here changes the provider; every action takes effect on screen at once.
struct TitleManagerView: View {
    let kind: ContentKind
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var tab: Tab = .titles
    @State private var rows: [ManagedTitle] = []
    @State private var hiddenIDs: Set<String> = []
    @State private var scope: Scope = .shown
    @State private var search = ""
    @State private var selection = Set<String>()
    @State private var loading = true
    @State private var visibleCount = Self.page
    @State private var message: String?

    private static let page = 200

    enum Tab: String, CaseIterable, Identifiable { case titles = "Titles", folders = "Folders"; var id: String { rawValue } }
    enum Scope: String, CaseIterable, Identifiable { case shown = "Shown", hidden = "Hidden", favorites = "Favorites"; var id: String { rawValue } }

    struct ManagedTitle: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let year: Int?
        let folder: String?
        let poster: String?
    }

    private var noun: String { kind == .series ? "series" : "movies" }
    private var heading: String { kind == .series ? "Series manager" : "Movies manager" }

    var body: some View {
        VStack(spacing: 0) {
            top
            Divider().overlay(ColorTokens.line)
            switch tab {
            case .titles: titles
            case .folders: FoldersPane(kind: kind)
            }
        }
        .task(id: "\(kind.rawValue)|\(state.activeSourceID?.uuidString ?? "")|\(state.showsAllPlaylists)") { await load() }
    }

    private var top: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(heading).font(Typography.title)
                Text("Hide, favorite and organise locally. Nothing here changes your provider.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            }
            Spacer()
            Picker("View", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 190).atlas("control.commandCenter.tabs")
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: titles

    private func inScope(_ r: ManagedTitle) -> Bool {
        switch scope {
        case .shown: return !hiddenIDs.contains(r.id)
        case .hidden: return hiddenIDs.contains(r.id)
        case .favorites: return state.isFavorite(r.id)
        }
    }

    private var matching: [ManagedTitle] {
        rows.filter { r in
            inScope(r) && (search.isEmpty || r.title.localizedCaseInsensitiveContains(search) || (r.folder ?? "").localizedCaseInsensitiveContains(search))
        }
    }

    @ViewBuilder private var titles: some View {
        let list = matching
        VStack(spacing: 0) {
            controls(count: list.count)
            actionBar(list)
            Divider().overlay(ColorTokens.line)
            if loading { LoadingView(label: "Loading \(noun)…") }
            else if rows.isEmpty { EmptyStateView(symbol: kind == .series ? "tv" : "film", title: "No \(noun)", message: "Add a playlist with \(noun) to manage them here.") }
            else if list.isEmpty { EmptyStateView(symbol: "magnifyingglass", title: "Nothing matches", message: "Try another search or filter.") }
            else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(list.prefix(visibleCount)) { r in
                            row(r).onAppear { if r.id == list.prefix(visibleCount).last?.id, visibleCount < list.count { visibleCount += Self.page } }
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
        }
    }

    private func controls(count: Int) -> some View {
        HStack(spacing: 10) {
            InlineSearchField(text: $search, prompt: "Search \(noun) or folders").frame(maxWidth: 320)
            HStack(spacing: 6) {
                ForEach(Scope.allCases) { s in
                    Button { scope = s; selection = []; visibleCount = Self.page } label: {
                        Text(s.rawValue).font(Typography.captionMedium).padding(.horizontal, 11).frame(height: 26)
                            .background(scope == s ? ColorTokens.accent.opacity(0.9) : Color.white.opacity(0.06), in: Capsule())
                            .foregroundStyle(scope == s ? Color.white : ColorTokens.textSecondary)
                    }.buttonStyle(.plain).atlas("control.commandCenter.filterChip")
                }
            }
            Spacer()
            Text("\(count.formatted()) \(noun)").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
        }.padding(.horizontal, 20).padding(.vertical, 10)
    }

    /// Always visible, so what can be done is never a mystery. Buttons wake up as soon as something is selected.
    private func actionBar(_ list: [ManagedTitle]) -> some View {
        let chosen = list.filter { selection.contains($0.id) }
        let n = chosen.count
        let allHidden = n > 0 && chosen.allSatisfy { hiddenIDs.contains($0.id) }
        return HStack(spacing: 8) {
            Button { selection = n == list.count ? [] : Set(list.map(\.id)) } label: {
                Image(systemName: n > 0 && n == list.count ? "checkmark.square.fill" : n > 0 ? "minus.square.fill" : "square").font(.system(size: 15))
            }.buttonStyle(.plain).help(n == list.count && n > 0 ? "Clear selection" : "Select all \(list.count.formatted()) shown").atlas("control.commandCenter.selectAll")
            Text(n == 0 ? "Select \(noun) to edit them" : "\(n.formatted()) selected").font(Typography.rowMedium)
                .foregroundStyle(n == 0 ? ColorTokens.textSecondary : ColorTokens.textPrimary)
            Spacer()
            if let message { Text(message).font(Typography.caption).foregroundStyle(ColorTokens.success).transition(.opacity) }
            bar(allHidden ? "Show" : "Hide", allHidden ? "eye" : "eye.slash", n > 0) { setHidden(!allHidden, ids: chosen.map(\.id)) }
            bar("Favorite", "heart", n > 0) {
                let allFav = chosen.allSatisfy { state.isFavorite($0.id) }
                for t in chosen where state.isFavorite(t.id) == allFav { _ = state.toggleFavorite(t.id, kind: kind) }
                say(allFav ? "Removed from favorites" : "Added to favorites")
            }
            bar("Watch later", "bookmark", n > 0) {
                let allLater = chosen.allSatisfy { state.isWatchLater($0.id) }
                for t in chosen where state.isWatchLater(t.id) == allLater { _ = state.toggleWatchLater(t.id, kind: kind) }
                say(allLater ? "Removed from Watch Later" : "Saved to Watch Later")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(n > 0 ? Color.white.opacity(0.04) : .clear)
        .animation(AnimationTokens.standard, value: n > 0)
    }

    private func bar(_ title: String, _ symbol: String, _ enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).labelStyle(.titleAndIcon) }
            .buttonStyle(SecondaryButtonStyle()).disabled(!enabled).opacity(enabled ? 1 : 0.4).atlas("control.commandCenter.bulkAction")
    }

    private func row(_ r: ManagedTitle) -> some View {
        let picked = selection.contains(r.id)
        let isHidden = hiddenIDs.contains(r.id)
        return HStack(spacing: 12) {
            Image(systemName: picked ? "checkmark.square.fill" : "square").font(.system(size: 15)).foregroundStyle(picked ? ColorTokens.accent : ColorTokens.textTertiary)
            ArtworkImage(url: r.poster, kind: .poster, contentMode: .fill, symbol: kind == .series ? "tv" : "film")
                .frame(width: 34, height: 51).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: r.title).font(Typography.rowMedium).lineLimit(1)
                Text(verbatim: [r.year.map(String.init), r.folder].compactMap { $0 }.joined(separator: " · ")).font(Typography.caption)
                    .foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
            }
            Spacer()
            if state.isFavorite(r.id) { Image(systemName: "heart.fill").font(.system(size: 11)).foregroundStyle(ColorTokens.accent) }
            if state.isWatchLater(r.id) { Image(systemName: "bookmark.fill").font(.system(size: 11)).foregroundStyle(ColorTokens.textSecondary) }
            if isHidden { Image(systemName: "eye.slash").font(.system(size: 11)).foregroundStyle(ColorTokens.textTertiary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .opacity(isHidden && scope != .hidden ? 0.5 : 1)
        .background(picked ? Color.white.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if picked { selection.remove(r.id) } else { selection.insert(r.id) } }
        .contextMenu {
            Button(isHidden ? "Show" : "Hide", systemImage: isHidden ? "eye" : "eye.slash") { setHidden(!isHidden, ids: [r.id]) }.atlas("control.commandCenter.bulkAction")
            Button(state.isFavorite(r.id) ? "Remove from favorites" : "Add to favorites", systemImage: "heart") { _ = state.toggleFavorite(r.id, kind: kind) }.atlas("control.commandCenter.bulkAction")
            Button(state.isWatchLater(r.id) ? "Remove from Watch Later" : "Watch later", systemImage: "bookmark") { _ = state.toggleWatchLater(r.id, kind: kind) }.atlas("control.commandCenter.bulkAction")
        }
        .atlas("control.commandCenter.bulkAction")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    // MARK: actions and loading

    private func say(_ text: String) {
        message = text
        Task { try? await Task.sleep(nanoseconds: 2_200_000_000); if message == text { message = nil } }
    }

    private func setHidden(_ on: Bool, ids: [String]) {
        guard let c = container, !ids.isEmpty else { return }
        let kindRaw = kind.rawValue
        for id in ids { if on { hiddenIDs.insert(id) } else { hiddenIDs.remove(id) } }
        selection.subtract(ids)
        Task {
            await Task.detached { for id in ids { if on { try? c.favoritesRepo.hide(id, kind: kindRaw) } else { try? c.favoritesRepo.unhide(id) } } }.value
            state.catalogVersion += 1
            say(on ? "Hidden" : "Shown again")
        }
    }

    private func load() async {
        guard let c = container else { return }
        let source = state.showsAllPlaylists ? nil : state.activeSourceID
        let kind = self.kind
        loading = rows.isEmpty
        let result = await Task.detached { () -> ([ManagedTitle], Set<String>) in
            var q = VODQuery()
            q.sourceID = source; q.includeHidden = true; q.sort = .title; q.limit = 5000
            let hidden = Set((try? c.favoritesRepo.hiddenIDs(kind: kind.rawValue)) ?? [])
            if kind == .series {
                let list = (try? c.catalog.series(q)) ?? []
                return (list.map { ManagedTitle(id: $0.id, title: $0.title, year: $0.releaseYear, folder: $0.categoryName, poster: $0.posterURL) }, hidden)
            }
            let list = (try? c.catalog.movies(q)) ?? []
            return (list.map { ManagedTitle(id: $0.id, title: $0.title, year: $0.releaseYear, folder: $0.categoryName, poster: $0.posterURL) }, hidden)
        }.value
        rows = result.0; hiddenIDs = result.1; loading = false
    }
}
