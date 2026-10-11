import SwiftUI

/// Organise the library locally: channels (rename, regroup, hide, favourite, match a guide) and folders (reorder, hide).
/// Nothing here changes the provider. Every action takes effect on screen at once and is saved in the background.
struct ChannelCommandCenterView: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var vm = CommandCenterViewModel()
    @State private var tab: Tab = .channels
    @State private var sheet: Sheet?
    @State private var confirmRestore = false

    enum Tab: String, CaseIterable, Identifiable { case channels = "Channels", folders = "Folders"; var id: String { rawValue } }
    enum Sheet: Identifiable {
        case rename(Channel), category([Channel]), guide(Channel)
        var id: String { switch self { case .rename(let c): "r\(c.id)"; case .category: "c"; case .guide(let c): "g\(c.id)" } }
    }

    var body: some View {
        VStack(spacing: 0) {
            top
            Divider().overlay(ColorTokens.line)
            switch tab {
            case .channels: ChannelsPane(vm: vm, sheet: $sheet, confirmRestore: $confirmRestore)
            case .folders: FoldersPane()
            }
        }
        .task(id: "\(vm.sourceID?.uuidString ?? "")") { if let c = container { await vm.load(c) } }
        .task(id: state.favoriteIDs.count) { vm.setFavorites(state.favoriteIDs) }
        .sheet(item: $sheet) { s in
            switch s {
            case .rename(let ch): TextPromptSheet(title: "Rename channel", note: "Only changes how it appears in StreamSetu.", initial: ch.name, action: "Rename") { if let c = container { vm.rename(ch.id, to: $0, c) } }
            case .category(let chs): CategorySheet(count: chs.count, existing: vm.categories) { name in if let c = container { vm.setCategory(name, ids: chs.map(\.id), c); bump() } }
            case .guide(let ch): AssignGuideSheet(channel: ch) { id in if let c = container { vm.assignGuide(id, channel: ch, c); bump() } }
            }
        }
        .confirmationDialog("Restore provider defaults for \(vm.selection.count) channel(s)?", isPresented: $confirmRestore) {
            Button("Restore Defaults", role: .destructive) { if let c = container { vm.restore(ids: Array(vm.selection), c); bump(); Task { await vm.load(c, force: true) } } }
        } message: { Text("Renames, category changes, guide matches and hidden state are removed for the selection.") }
    }

    /// Other screens pick up the change once, a moment after the last edit, instead of after every click.
    @State private var bumpTask: Task<Void, Never>?
    private func bump() {
        bumpTask?.cancel()
        bumpTask = Task { try? await Task.sleep(nanoseconds: 700_000_000); if !Task.isCancelled { state.catalogVersion += 1 } }
    }

    private var top: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Channel manager").font(Typography.title)
                Text("Rename, regroup, hide and reorder locally. Nothing here changes your provider.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            }
            Spacer()
            Picker("View", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }
}

// MARK: - Channels

private struct ChannelsPane: View {
    @Bindable var vm: CommandCenterViewModel
    @Binding var sheet: ChannelCommandCenterView.Sheet?
    @Binding var confirmRestore: Bool
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            controls
            actionBar
            Divider().overlay(ColorTokens.line)
            if vm.loading { LoadingView(label: "Loading channels…") }
            else if vm.channels.isEmpty { EmptyStateView(symbol: "slider.horizontal.3", title: "No channels", message: "Add a playlist to manage its channels here.") }
            else if vm.visible.isEmpty { EmptyStateView(symbol: "magnifyingglass", title: "Nothing matches", message: "Try another search or filter.") }
            else { list }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                InlineSearchField(text: $vm.search, prompt: "Search channels or folders").frame(maxWidth: 320)
                if state.sources.count > 1 {
                    Picker("Playlist", selection: $vm.sourceID) { Text("All playlists").tag(UUID?.none); ForEach(state.sources) { Text($0.name).tag(UUID?.some($0.id)) } }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                }
                Spacer()
                Text(summary).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(CCFilter.allCases) { f in
                        let n = vm.counts[f] ?? 0
                        if f == .all || f == vm.filter || n > 0 { FilterChip(title: f.rawValue, count: n, on: vm.filter == f) { vm.filter = f } }
                    }
                }.padding(.vertical, 1)
            }.scrollIndicators(.hidden)
        }.padding(.horizontal, 20).padding(.vertical, 10)
    }

    private var summary: String {
        "\(vm.channels.count.formatted()) channels · \(vm.duplicateClusters) duplicate groups"
    }

    /// Always visible, so what can be done is never a mystery. Buttons wake up as soon as something is selected.
    private var actionBar: some View {
        let sel = vm.selectedChannels
        let n = sel.count
        return HStack(spacing: 8) {
            Button { n == 0 || !vm.allMatchingSelected ? vm.selectAllMatching() : vm.clearSelection() } label: {
                Image(systemName: vm.allMatchingSelected ? "checkmark.square.fill" : n > 0 ? "minus.square.fill" : "square").font(.system(size: 15))
            }.buttonStyle(.plain).help(vm.allMatchingSelected ? "Clear selection" : "Select all \(vm.matchCount.formatted()) shown")
            Text(n == 0 ? "Select channels to edit them" : "\(n.formatted()) selected").font(Typography.rowMedium).foregroundStyle(n == 0 ? ColorTokens.textSecondary : ColorTokens.textPrimary)
            Spacer()
            if let m = vm.message { Text(m).font(Typography.caption).foregroundStyle(ColorTokens.success).transition(.opacity) }
            bar("Rename", "pencil", n == 1) { sheet = .rename(sel[0]) }
            bar("Folder", "folder", n > 0) { sheet = .category(sel) }
            bar("Guide", "calendar", n == 1) { sheet = .guide(sel[0]) }
            bar(sel.allSatisfy { vm.isHidden($0.id) } && n > 0 ? "Show" : "Hide", "eye.slash", n > 0) {
                if let c = container { vm.setHidden(!sel.allSatisfy { vm.isHidden($0.id) }, ids: sel.map(\.id), c); bumpSoon() }
            }
            bar("Favorite", "heart", n > 0) {
                let allFav = sel.allSatisfy { state.isFavorite($0.id) }
                for ch in sel where state.isFavorite(ch.id) == allFav { _ = state.toggleFavorite(ch.id, kind: .channel) }
            }
            bar("Restore", "arrow.uturn.backward", n > 0) { confirmRestore = true }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(n > 0 ? Color.white.opacity(0.04) : .clear)
        .animation(AnimationTokens.standard, value: n > 0)
    }

    private func bumpSoon() { Task { try? await Task.sleep(nanoseconds: 700_000_000); state.catalogVersion += 1 } }

    private func bar(_ title: String, _ symbol: String, _ enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).labelStyle(.titleAndIcon) }
            .buttonStyle(SecondaryButtonStyle()).disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(vm.visible) { ch in
                    ChannelRow(channel: ch, vm: vm, selected: vm.selection.contains(ch.id), sheet: $sheet, confirmRestore: $confirmRestore)
                        .onAppear { if ch.id == vm.visible.last?.id { vm.showMore() } }
                }
                if vm.hasMore { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(14) }
            }.padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}

private struct ChannelRow: View {
    let channel: Channel
    let vm: CommandCenterViewModel
    let selected: Bool
    @Binding var sheet: ChannelCommandCenterView.Sheet?
    @Binding var confirmRestore: Bool
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var hovering = false

    private var hidden: Bool { vm.isHidden(channel.id) }
    private var fav: Bool { state.isFavorite(channel.id) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.square.fill" : "square").font(.system(size: 15)).foregroundStyle(selected ? Color.accentColor : ColorTokens.textTertiary)
            ChannelLogo(url: channel.logoURL, name: channel.name, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(channel.name).font(Typography.rowMedium).lineLimit(1)
                    if vm.isEdited(channel.id) { Image(systemName: "pencil.circle.fill").font(.system(size: 11)).foregroundStyle(ColorTokens.textSecondary).help("Edited locally") }
                    if vm.duplicateIDs.contains(channel.id) { Image(systemName: "square.on.square").font(.system(size: 10)).foregroundStyle(ColorTokens.warning).help("Likely duplicate") }
                }
                Text([channel.categoryName ?? "No folder", state.sources.count > 1 ? state.sourceName(channel.sourceID) : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if vm.hasGuide(channel.id) { Image(systemName: "calendar").font(.system(size: 11)).foregroundStyle(ColorTokens.success).help("Has a guide") }
            Button { if let c = container { vm.setHidden(!hidden, ids: [channel.id], c) } } label: { Image(systemName: hidden ? "eye.slash.fill" : "eye").font(.system(size: 12)) }
                .buttonStyle(.plain).foregroundStyle(hidden ? ColorTokens.warning : ColorTokens.textTertiary).help(hidden ? "Hidden — click to show" : "Hide").accessibilityLabel(hidden ? "Show channel" : "Hide channel")
                .opacity(hovering || hidden ? 1 : 0.55)
            Button { _ = state.toggleFavorite(channel.id, kind: .channel) } label: { Image(systemName: fav ? "heart.fill" : "heart").font(.system(size: 12)) }
                .buttonStyle(.plain).foregroundStyle(fav ? ColorTokens.live : ColorTokens.textTertiary).help(fav ? "Remove from favorites" : "Add to favorites").accessibilityLabel(fav ? "Remove from favorites" : "Add to favorites")
                .opacity(hovering || fav ? 1 : 0.55)
        }
        .padding(.horizontal, 10).frame(height: 46)
        .opacity(hidden ? 0.5 : 1)
        .background(selected ? Color.white.opacity(0.07) : hovering ? Color.white.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { vm.toggle(channel.id) }
        .onHover { hovering = $0 }
        .animation(AnimationTokens.quick, value: selected)
        .contextMenu {
            Button("Rename…") { sheet = .rename(channel) }
            Button("Move to folder…") { sheet = .category(selected ? vm.selectedChannels : [channel]) }
            Button("Match guide…") { sheet = .guide(channel) }
            Divider()
            Button(hidden ? "Show" : "Hide") { if let c = container { vm.setHidden(!hidden, ids: [channel.id], c) } }
            Button(fav ? "Remove from favorites" : "Add to favorites") { _ = state.toggleFavorite(channel.id, kind: .channel) }
            Divider()
            Button("Restore provider defaults") { vm.selection = [channel.id]; confirmRestore = true }
        }
    }
}

private struct FilterChip: View {
    let title: String
    let count: Int
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if count > 0 { Text(count.formatted()).foregroundStyle(on ? .white.opacity(0.8) : ColorTokens.textTertiary) }
            }
            .font(Typography.captionMedium).padding(.horizontal, 11).frame(height: 26)
            .background(on ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.06), in: Capsule())
            .foregroundStyle(on ? .white : ColorTokens.textSecondary)
        }.buttonStyle(.plain).animation(AnimationTokens.quick, value: on)
    }
}

// MARK: - Sheets

struct TextPromptSheet: View {
    let title: String
    let note: String
    let initial: String
    let action: String
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Typography.heading)
            Text(note).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            TextField("", text: $text).textFieldStyle(.roundedBorder).focused($focused).onSubmit(save)
            HStack { Spacer(); SecondaryButton(title: "Cancel") { dismiss() }; PrimaryButton(title: action, action: save).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty) }
        }
        .padding(22).frame(width: 400).background(ColorTokens.background)
        .onAppear { text = initial; focused = true }
    }
    private func save() { guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }; onDone(text); dismiss() }
}

struct CategorySheet: View {
    let count: Int
    let existing: [String]
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matches: [String] { query.isEmpty ? Array(existing.prefix(60)) : existing.filter { $0.localizedCaseInsensitiveContains(query) }.prefix(60).map { $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move \(count) channel\(count == 1 ? "" : "s") to a folder").font(Typography.heading)
            InlineSearchField(text: $query, prompt: "Search folders or type a new name")
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(matches, id: \.self) { name in
                        Button { onDone(name); dismiss() } label: { HStack { Image(systemName: "folder").foregroundStyle(ColorTokens.textSecondary); Text(name).font(Typography.row); Spacer() }.padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle()) }
                            .buttonStyle(.plain).hoverHighlight()
                    }
                }
            }.frame(height: 220)
            HStack {
                let new = query.trimmingCharacters(in: .whitespaces)
                if !new.isEmpty, !existing.contains(where: { $0.caseInsensitiveCompare(new) == .orderedSame }) {
                    PrimaryButton(title: "Create “\(new)”", symbol: "plus") { onDone(new); dismiss() }
                }
                Spacer(); SecondaryButton(title: "Cancel") { dismiss() }
            }
        }.padding(22).frame(width: 440).background(ColorTokens.background)
    }
}

struct AssignGuideSheet: View {
    let channel: Channel
    var onDone: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.container) private var container
    @State private var guide: [(id: String, name: String)] = []
    @State private var query = ""
    @State private var loaded = false

    private var results: [(id: String, name: String)] {
        let q = MetadataNormalizer.normalize(query.isEmpty ? channel.name : query)
        return Array(guide.filter { MetadataNormalizer.normalize($0.name).contains(q) || $0.id.lowercased().contains(q) }.prefix(200))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Match guide for “\(channel.name)”").font(Typography.heading)
            Text("Pick the guide channel that carries this channel's schedule. Automatic matching never overrides your choice.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            InlineSearchField(text: $query, prompt: "Search guide channels")
            if !loaded { ProgressView().frame(maxWidth: .infinity).frame(height: 240) }
            else if results.isEmpty { Text(guide.isEmpty ? "This playlist has no guide data yet." : "No guide channel matches.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).frame(maxWidth: .infinity).frame(height: 240) }
            else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(results, id: \.id) { g in
                            Button { onDone(g.id); dismiss() } label: { HStack { Text(g.name).font(Typography.row); Spacer(); Text(g.id).font(Typography.mono).foregroundStyle(ColorTokens.textTertiary).lineLimit(1) }.padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle()) }
                                .buttonStyle(.plain).hoverHighlight()
                        }
                    }
                }.frame(height: 240)
            }
            HStack { SecondaryButton(title: "Remove match") { onDone(nil); dismiss() }; Spacer(); SecondaryButton(title: "Cancel") { dismiss() } }
        }
        .padding(22).frame(width: 520).background(ColorTokens.background)
        .task { if let c = container { guide = await Task.detached { (try? c.epgRepo.guideChannels(sourceID: channel.sourceID)) ?? [] }.value }; loaded = true }
    }
}
