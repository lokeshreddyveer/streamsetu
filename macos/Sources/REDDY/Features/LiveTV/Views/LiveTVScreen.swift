import SwiftUI

/// Live TV: sidebar (groups) | channel list | player and programme info. Exactly three functional columns.
struct LiveTVScreen: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @Environment(AppSettings.self) private var settings
    @State private var vm = LiveTVViewModel()
    @AppStorage("live.channelListWidth") private var storedListWidth: Double = 300
    @AppStorage("live.channelListCollapsed") private var listCollapsed = false

    private var playback: PlaybackCoordinator? { container?.playback }
    private var currentChannel: Channel? { playback?.currentChannel }
    private var filter: LiveFilter { LiveFilter(router.selection) }
    private var taskKey: String { "\(filter)-\(vm.listID ?? "")-\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)-\(settings.collapseDuplicates)-\(settings.defaultChannelSort.rawValue)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageHead(title: "Live TV")
            LiveToolbar(label: folderLabel, listCollapsed: $listCollapsed, search: Binding(get: { vm.search }, set: { vm.search = $0; if let c = container { vm.scheduleSearch(c) } }),
                        count: vm.channels.count, searching: !vm.search.isEmpty, focusToken: router.focusSearch,
                        lists: vm.lists, activeListID: Binding(get: { vm.listID }, set: { vm.listID = $0 }))
            LiveSplit(listWidth: $storedListWidth, collapsed: $listCollapsed) {
                channelColumn
            } player: {
                playerColumn
            }
            .surface(radius: 10)
        }
        .padding(.horizontal, LayoutTokens.gutter).padding(.top, 10).padding(.bottom, 12)
        .task(id: taskKey) {
            vm.sourceID = state.activeSourceID; vm.filter = filter
            if let c = container { await vm.reload(c) }
        }
        .task(id: "\(playback?.current?.itemID ?? "")-\(state.catalogVersion)") { if let c = container { await vm.loadDetails(for: currentChannel, c) } }
        .task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 60_000_000_000); if let c = container { await vm.refreshNowNext(c); await vm.loadDetails(for: currentChannel, c) } } }
    }

    // MARK: channel list

    private var folderLabel: String {
        if let id = vm.listID, let l = vm.lists.first(where: { $0.id == id }) { return "List · \(l.name)" }
        switch router.selection {
        case .folder(let id): return state.folderName(id) ?? "Group"
        case .shortcut(let s): return s.title
        }
    }

    private var channelColumn: some View {
        VStack(spacing: 0) {
            if !state.hasLibrary {
                EmptyStateView(symbol: "list.bullet.rectangle", title: "No playlist", message: "Add a playlist to watch live TV.", actionTitle: "Add playlist") { router.modal = .addPlaylist }
            } else if vm.loading {
                VStack(spacing: 6) { ForEach(0..<9, id: \.self) { _ in SkeletonBlock(height: 40, radius: 7) } }.padding(.horizontal, 8)
                Spacer()
            } else if vm.channels.isEmpty {
                EmptyStateView(symbol: vm.filter == .favorites ? "heart" : "tv", title: emptyTitle, message: emptyMessage)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(vm.channels) { ch in
                            Button { clicked(ch) } label: {
                                LiveChannelRow(channel: ch, nowNext: vm.nowNext[ch.id], isPlaying: currentChannel?.id == ch.id, isSelected: vm.selectedID == ch.id,
                                               isFavorite: state.isFavorite(ch.id),
                                               onFavorite: { state.toggleFavorite(ch.id, kind: .channel); if vm.filter == .favorites, let c = container { Task { await vm.reload(c) } } })
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture(count: 2).onEnded { if settings.clickBehavior == .doubleClick { play(ch) } })
                            .onKeyPress(.return) { play(ch); return .handled }
                            .task { if let c = container { vm.want(ch.id, c) } }
                            .contextMenu { ChannelContextMenu(channel: ch, onPlay: { play(ch) }, onChanged: { if let c = container { Task { await vm.reload(c) } } }) }
                            .accessibilityLabel("\(ch.name)\(vm.nowNext[ch.id]?.first(where: { $0.isLive() }).map { ", now \($0.title)" } ?? "")")
                            .accessibilityAddTraits(currentChannel?.id == ch.id ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var emptyTitle: String {
        if !vm.search.isEmpty { return "No matches" }
        switch vm.filter { case .favorites: return "No favorite channels"; case .recent: return "Nothing watched yet"; case .added: return "Nothing new"; default: return "No channels" }
    }
    private var emptyMessage: String {
        if !vm.search.isEmpty { return "Nothing in “\(folderLabel)” matches “\(vm.search)”." }
        switch vm.filter {
        case .favorites: return "Tap the heart on a channel to keep it here."
        case .recent: return "Channels you actually watch appear here."
        default: return "This group is empty, or the playlist is still updating."
        }
    }

    // MARK: player + programme info

    /// The player column. The video box takes the full width of the column whenever the height allows, at the stream's own
    /// aspect ratio (16:9 only until it reports one); the compact information area sits below and scrolls if needed.
    private var playerColumn: some View {
        GeometryReader { g in
            if let p = playback, p.currentChannel != nil, let ch = currentChannel {
                let aspect = LivePlayerLayout.displayAspect(width: p.metrics.width, height: p.metrics.height)
                let inner = CGSize(width: max(0, g.size.width - 24), height: max(0, g.size.height - 24))
                let stage = LivePlayerLayout.stageSize(available: inner, aspect: aspect, reservedBelow: vm.upcoming.isEmpty ? 96 : 210)
                VStack(alignment: .leading, spacing: 10) {
                    LivePlayerStage(playback: p, program: vm.upcoming.first { $0.isLive() }, nextProgram: vm.upcoming.first { $0.start > Date() })
                        .frame(width: stage.width, height: stage.height)
                        .frame(maxWidth: .infinity)                                   // centred when the height is the limit
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            channelHeader(ch)
                            if vm.upcoming.isEmpty {
                                Text("No programme information for this channel.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                            } else {
                                CurrentProgramCard(channel: ch, upcoming: vm.upcoming, past: vm.past, onCatchup: { p in playback?.playCatchup(channel: ch, program: p) })
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                .padding(12)
            } else {
                EmptyStateView(symbol: "play.tv", title: "Pick a channel", message: "Choose a channel to start watching. It keeps playing while you browse.")
            }
        }
    }

    private func channelHeader(_ ch: Channel) -> some View {
        HStack(spacing: 8) {
            Button { state.toggleFavorite(ch.id, kind: .channel) } label: {
                Label(state.isFavorite(ch.id) ? "Favorited" : "Favorite", systemImage: state.isFavorite(ch.id) ? "heart.fill" : "heart")
            }.buttonStyle(SecondaryButtonStyle())
            Button { router.navigate(.guide, .shortcut(.allChannels)) } label: { Label("TV Guide", systemImage: "calendar") }.buttonStyle(SecondaryButtonStyle())
            Button { playback?.isFullscreen = true } label: { Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right") }.buttonStyle(SecondaryButtonStyle())
            if vm.variants.count > 1 {
                Menu {
                    ForEach(vm.variants, id: \.variant.id) { v in Button { play(v.variant) } label: { Label(v.label, systemImage: v.variant.id == ch.id ? "checkmark" : "") } }
                } label: { Label("Streams", systemImage: "square.stack.3d.up") }.menuStyle(.button).buttonStyle(SecondaryButtonStyle()).fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: actions

    /// A click. With "Single click plays" it starts the channel; with "Double click plays" it only selects it.
    private func clicked(_ ch: Channel) {
        if settings.clickBehavior == .singleClick { play(ch) } else { vm.selectedID = ch.id }
    }

    private func play(_ ch: Channel) {
        vm.selectedID = ch.id
        playback?.play(channel: ch, queue: vm.channels)
    }
}

/// Compact glass bar above the channels: search on the left, group label and count on the right.
struct LiveToolbar: View {
    let label: String
    @Binding var listCollapsed: Bool
    @Binding var search: String
    let count: Int
    let searching: Bool
    var focusToken = 0
    /// The person's own named lists that hold channels, and the one being viewed.
    var lists: [CatalogCollection] = []
    @Binding var activeListID: String?
    @FocusState private var focused: Bool
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(ColorTokens.textTertiary)
                TextField("Search channels or programmes…", text: $search).textFieldStyle(.plain).font(Typography.row).focused($focused)
                    .accessibilityLabel("Search channels in \(label)")
                if searching {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)) }
                        .buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10).frame(height: 30).frame(maxWidth: 450)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(focused ? accent.opacity(0.55) : ColorTokens.glassEdge.opacity(0.7)))
            Button { listCollapsed.toggle() } label: {
                Image(systemName: listCollapsed ? "sidebar.left" : "sidebar.squares.left").font(.system(size: 13)).frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).help(listCollapsed ? "Show channel list" : "Hide channel list")
            .accessibilityLabel(listCollapsed ? "Show channel list" : "Hide channel list")
            if !lists.isEmpty || activeListID != nil {
                Menu {
                    Button { activeListID = nil } label: { Label("Everything in this view", systemImage: activeListID == nil ? "checkmark" : "") }
                    Divider()
                    ForEach(lists) { l in Button { activeListID = l.id } label: { Label("\(l.name) (\(l.itemCount))", systemImage: activeListID == l.id ? "checkmark" : "") } }
                } label: { Label(activeListID == nil ? "Lists" : "List on", systemImage: "list.star") }
                    .menuStyle(.button).fixedSize().help("Your own channel lists, like Sports or Kids")
            }
            Spacer(minLength: 8)
            Text(label).font(Typography.rowMedium).lineLimit(1).truncationMode(.tail).frame(maxWidth: 200, alignment: .trailing)
            Rectangle().fill(ColorTokens.line).frame(width: 1, height: 14)
            Text(searching ? "\(count.formatted()) match\(count == 1 ? "" : "es")" : "\(count.formatted()) channel\(count == 1 ? "" : "s")")
                .font(Typography.caption).monospacedDigit().foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(GlassBackground(radius: 10))
        .onChange(of: focusToken) { _, _ in focused = true }
    }
}


/// Channel list | divider | player. The divider can be dragged (or adjusted from the keyboard and VoiceOver) to resize the
/// list; the list can also be collapsed. Resizing only changes frames: the player column keeps its identity, so the video
/// surface and the playback session are untouched.
struct LiveSplit<List: View, Player: View>: View {
    @Binding var listWidth: Double
    @Binding var collapsed: Bool
    @ViewBuilder var list: List
    @ViewBuilder var player: Player
    @State private var dragStart: Double?
    @State private var hovering = false

    var body: some View {
        GeometryReader { g in
            let width = LivePlayerLayout.channelListWidth(stored: CGFloat(listWidth), containerWidth: g.size.width)
            HStack(spacing: 0) {
                if !collapsed {
                    list.frame(width: width)
                    divider(container: g.size.width)
                }
                player.frame(maxWidth: .infinity)
            }
        }
    }

    private func divider(container: CGFloat) -> some View {
        Rectangle().fill(hovering || dragStart != nil ? ColorTokens.lineStrong : ColorTokens.line).frame(width: 1)
            .frame(width: 9).background(Color.clear).contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if dragStart == nil { dragStart = listWidth }
                    listWidth = Double(LivePlayerLayout.channelListWidth(stored: CGFloat((dragStart ?? listWidth) + v.translation.width), containerWidth: container))
                }
                .onEnded { _ in dragStart = nil })
            .accessibilityElement().accessibilityLabel("Channel list width")
            .accessibilityValue("\(Int(listWidth)) points")
            .accessibilityAdjustableAction { dir in
                switch dir {
                case .increment: listWidth = min(Double(LivePlayerLayout.listRange.upperBound), listWidth + 20)
                case .decrement: listWidth = max(Double(LivePlayerLayout.listRange.lowerBound), listWidth - 20)
                @unknown default: break
                }
            }
    }
}
