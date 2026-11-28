import SwiftUI

/// Type to find anything Music can do (commands, your playlists, places) and run it with Return. Everything here is the person acting, so it is fully allowed.
struct MusicCommandPalette: View {
    let hub: MusicHub
    let close: () -> Void
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool
    @Environment(\.reddyAccent) private var accent

    private struct Item: Identifiable { var id: String; var title: String; var symbol: String; var call: MusicCommandCall }

    private var items: [Item] {
        var all: [Item] = MusicCommandName.allCases.filter { !$0.takesArgument && $0 != .nowPlaying }.map { Item(id: $0.rawValue, title: $0.title, symbol: Self.symbol($0), call: MusicCommandCall(name: $0.rawValue)) }
        all += hub.library.playlists.map { Item(id: "pl-" + $0.id.uuidString, title: Localized.string("Play playlist: %@", $0.name), symbol: "music.note.list", call: MusicCommandCall(name: "playPlaylist", argument: $0.id.uuidString)) }
        all += MusicListeningMode.allCases.map { Item(id: "mode-" + $0.rawValue, title: Localized.string("Listening mode: %@", $0.title), symbol: $0.symbol, call: MusicCommandCall(name: "listeningMode", argument: $0.rawValue)) }
        all += [10, 30, 60].map { Item(id: "sleep\($0)", title: Localized.string("Sleep timer: %@ minutes", String($0)), symbol: "moon.zzz", call: MusicCommandCall(name: "sleepTimer", argument: String($0))) }
        let q = MusicText.normalize(query)
        guard !q.isEmpty else { return all }
        return all.filter { MusicText.normalize($0.title).contains(q) }
    }

    private static func symbol(_ c: MusicCommandName) -> String {
        switch c {
        case .playPause, .play: "playpause"; case .pause: "pause"; case .next: "forward.end"; case .previous: "backward.end"; case .seekForward: "goforward.10"; case .seekBack: "gobackward.10"
        case .volumeUp: "speaker.plus"; case .volumeDown: "speaker.minus"; case .like: "heart"; case .shuffleOn, .shuffleOff: "shuffle"; case .repeatCycle: "repeat"
        case .stopAfterSong: "stop.circle"; case .playLiked, .playLikedShuffled: "heart.text.square"; case .openListenNow: "play.circle"; case .openExplore: "safari"
        case .openSearch: "magnifyingglass"; case .openLibrary: "heart.text.square"; case .openRadio: "dot.radiowaves.left.and.right"; case .openDownloads: "arrow.down.circle"; case .openRecentlyAdded: "clock.badge.checkmark"
        default: "command"
        }
    }

    var body: some View {
        let list = items
        VStack(spacing: 0) {
            HStack(spacing: MusicSpace.sm) {
                Image(systemName: "command").foregroundStyle(ColorTokens.textTertiary)
                TextField(Localized.string("Type a command"), text: $query).textFieldStyle(.plain).font(.system(size: 16)).focused($focused)
                    .onSubmit { run(list) }.onChange(of: query) { _, _ in selected = 0 }.atlas("control.music.paletteField")
                    .onKeyPress(.downArrow) { selected = min(list.count - 1, selected + 1); return .handled }
                    .onKeyPress(.upArrow) { selected = max(0, selected - 1); return .handled }
            }.padding(MusicSpace.md)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, it in
                            Button { selected = i; run(list) } label: {
                                HStack(spacing: MusicSpace.sm) {
                                    Image(systemName: it.symbol).frame(width: 22).foregroundStyle(i == selected ? accent : ColorTokens.textSecondary)
                                    Text(verbatim: it.title).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, MusicSpace.md).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: MusicCorner.control).fill(i == selected ? accent.opacity(0.14) : .clear))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(it.id).atlas("control.music.paletteItem")
                        }
                    }.padding(MusicSpace.xs)
                }
                .onChange(of: selected) { _, i in if list.indices.contains(i) { proxy.scrollTo(list[i].id) } }
            }
            if list.isEmpty { Text(Localized.string("Nothing matches.")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).padding(MusicSpace.lg) }
        }
        .frame(width: 520, height: 420)
        .onAppear { focused = true }
        .onExitCommand { close() }
    }

    private func run(_ list: [Item]) {
        guard list.indices.contains(selected) else { return }
        let it = list[selected]
        close()
        let r = MusicAutomation.perform(it.call, from: .palette, hub: hub)
        if !r.ok { MusicToasts.shared.show(r.message, kind: .error) }
    }
}
