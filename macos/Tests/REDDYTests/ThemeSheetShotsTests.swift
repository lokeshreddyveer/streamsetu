import Testing
import SwiftUI
import AppKit
@testable import REDDY

/// Renders one standard "theme sheet" per theme offscreen to PNG files for a look: top bar in two states, the sidebar with a selection,
/// a hero and a shelf with a focused tile, the Settings controls, a dialog and a podcast-style player bar. Runs only when THEME_SHEETS names a folder;
/// THEME_SHEET_THEMES narrows it to some theme names (comma separated). Native glass renders blank offscreen, so the frosted approximation is drawn.
@Suite("Theme sheets") @MainActor struct ThemeSheetShotsTests {
    struct Sheet: View {
        @State var q = ""
        @State var on = true
        @State var off = false
        @State var level = 0.6
        @State var seg = 0
        @State var text = "Focused field"
        @FocusState var focus: Bool
        var body: some View {
            let s = SidebarViewState(title: "Movies", pinned: SidebarModel.pinned(for: .movies), folders: [], selection: .shortcut(Shortcut.pinned(for: .movies)[0]), collapsed: false, playlistName: "Demo", playlists: [], activePlaylistID: nil, playlistMenuOpen: false)
            VStack(spacing: 0) {
                ForEach(Array([TopLevelDestination.streamSetu, .service(.netflix)].enumerated()), id: \.offset) { _, dest in
                    ReddyTopBar(state: TopBarState(tab: .movies, initials: "LO", accountMenuOpen: false, width: 1200, destination: dest, services: [.netflix]), query: $q, focusToken: 0, onSelectTab: { _ in }, onToggleAccount: {})
                        .frame(height: 68)
                }
                HStack(spacing: 0) {
                    ReddySidebar(state: s, folderQuery: $q, onSelect: { _ in }, onToggleCollapse: {}, onTogglePlaylistMenu: {}, onSwitchPlaylist: { _ in }, onAddPlaylist: {}).frame(width: 240)
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Featured tonight").font(Typography.pageTitle).foregroundStyle(ColorTokens.textPrimary)
                            Text("A hero panel with a synopsis in secondary text and a hint line in tertiary.").font(Typography.body).foregroundStyle(ColorTokens.textSecondary)
                            Text("2024 · 2h 10m · Drama").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                            HStack { Button("Play") {}.buttonStyle(.borderedProminent); Button("More info") {}.buttonStyle(.bordered) }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).surface()
                        HStack(spacing: 10) {
                            ForEach(0..<6, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LinearGradient(colors: [Color(hue: Double(i) / 6, saturation: 0.35, brightness: 0.45), Color(hue: Double(i) / 6, saturation: 0.4, brightness: 0.2)], startPoint: .top, endPoint: .bottom))
                                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(i == 2 ? ColorTokens.accentDefault : ColorTokens.line, lineWidth: i == 2 ? 3 : 1))
                                    .scaleEffect(i == 2 ? 1.05 : 1)
                            }
                        }
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("Toggle on", isOn: $on).toggleStyle(.switch)
                                Toggle("Toggle off", isOn: $off).toggleStyle(.switch)
                                Slider(value: $level)
                                PodcastSegmented(options: [0, 1, 2], selection: $seg, title: { LocalizedStringKey(["Now playing", "Queue", "Notes"][$0]) })
                                TextField("Search", text: $text).textFieldStyle(.roundedBorder)
                                ProgressView(value: 0.55)
                            }.padding(14).frame(width: 330).surface()
                            ZStack {
                                Color.clear
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Remove this playlist?").font(Typography.heading).foregroundStyle(ColorTokens.textPrimary)
                                    Text("Its channels stay in your library.").font(Typography.body).foregroundStyle(ColorTokens.textSecondary)
                                    HStack { Spacer(); Button("Cancel") {}.buttonStyle(.bordered); Button("Remove") {}.buttonStyle(.borderedProminent) }
                                }.padding(16).frame(width: 300).background(GlassBackground(radius: 14))
                            }.frame(maxWidth: .infinity)
                        }
                    }.padding(16)
                }
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6).fill(ColorTokens.card).frame(width: 40, height: 40)
                    VStack(alignment: .leading) { Text("Episode 12").font(Typography.bodyMedium).foregroundStyle(ColorTokens.textPrimary); Text("Garden Show").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
                    PodcastScrubber(fraction: 0.4, onChange: { _ in })
                    Image(systemName: "play.fill").foregroundStyle(ColorTokens.textPrimary)
                }.padding(.horizontal, 16).frame(height: 64).background(PodcastBarBackground())
            }
            .frame(width: 1200, height: 720)
            .background(ThemeBackdrop())
            .environment(\.colorScheme, .dark).environment(\.reddyAccent, ColorTokens.accentDefault).tint(ColorTokens.accentDefault).font(Typography.body)
        }
    }

    func render(_ view: some View, size: CGSize, to url: URL) async throws {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host; win.appearance = NSAppearance(named: .darkAqua)
        win.orderBack(nil)
        for _ in 0..<12 { try await Task.sleep(nanoseconds: 50_000_000) }
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        withExtendedLifetime(win) {}
    }

    @Test func renderTheThemeSheets() async throws {
        guard let dir = ProcessInfo.processInfo.environment["THEME_SHEETS"] else { return }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let only = ProcessInfo.processInfo.environment["THEME_SHEET_THEMES"]?.split(separator: ",").map(String.init)
        let saved = ThemeStore.current; defer { ThemeStore.current = saved; ThemeStore.state.frostedOnly = false }
        ThemeStore.state.frostedOnly = true
        for t in AppTheme.allCases where t != .custom && (only == nil || only!.contains(t.rawValue)) {
            ThemeStore.current = t
            let tag = t.rawValue.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "é", with: "e")
            try await render(Sheet(), size: CGSize(width: 1200, height: 720), to: URL(fileURLWithPath: dir).appendingPathComponent("\(tag).png"))
        }
    }

    /// The real screens (Home, Movies, Series, Live TV, TV Guide, Settings) in the shell, for the themes named in THEME_SCREEN_THEMES.
    /// Needs REDDY_SNAPSHOT_DIR (where SnapshotTests writes) and THEME_SCREENS=1.
    @Test func renderTheScreens() async throws {
        guard ProcessInfo.processInfo.environment["THEME_SCREENS"] != nil, ProcessInfo.processInfo.environment["REDDY_SNAPSHOT_DIR"] != nil else { return }
        _ = NSApplication.shared
        let names = (ProcessInfo.processInfo.environment["THEME_SCREEN_THEMES"] ?? "Liquid Glass,Liquid Glass Blue,Obsidian,Graphite").split(separator: ",").map(String.init)
        let saved = ThemeStore.current; defer { ThemeStore.current = saved; ThemeStore.state.frostedOnly = false }
        ThemeStore.state.frostedOnly = true
        let snap = SnapshotTests()
        let tabs: [(String, AppTab)] = [("home", .home), ("movies", .movies), ("series", .series), ("live", .liveTV), ("guide", .guide)]
        for n in names {
            guard let t = AppTheme(rawValue: n) else { continue }
            let tag = n.replacingOccurrences(of: " ", with: "-")
            for (name, tab) in tabs {
                let sc = try snap.scene(tab: tab)
                sc.container.settings.theme = t
                try await snap.capture(snap.shell(sc).reddyTheme(sc.container.settings), size: CGSize(width: 1440, height: 900), settle: 2.2, name: "\(tag)-\(name)")
            }
            let sc = try snap.scene()
            sc.container.settings.theme = t
            func env<V: View>(_ v: V) -> some View { v.environment(sc.container.settings).environment(sc.state).environment(sc.router).environment(\.container, sc.container).environment(\.artwork, sc.container.artwork).reddyTheme(sc.container.settings).background(ThemeBackdrop()) }
            try await snap.capture(env(GeneralSettingsPage()).frame(width: 660), size: CGSize(width: 660, height: 720), settle: 0.8, name: "\(tag)-settings")
        }
    }
}
