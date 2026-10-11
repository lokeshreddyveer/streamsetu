import Testing
import SwiftUI
import AppKit
@testable import REDDY

/// Renders the real shell off-screen (NSHostingView in a borderless window) so native controls, the sidebar, the header
/// and the bottom player are drawn exactly as the app draws them.
/// Runs only when REDDY_SNAPSHOT_DIR is set:  REDDY_SNAPSHOT_DIR=/tmp/snaps Scripts/run-tests.sh SnapshotTests
@Suite("Snapshots (opt-in)", .enabled(if: ProcessInfo.processInfo.environment["REDDY_SNAPSHOT_DIR"] != nil))
@MainActor struct SnapshotTests {
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REDDY_SNAPSHOT_DIR"] ?? NSTemporaryDirectory())

    struct Scene {
        let container: AppContainer
        let state: AppState
        let router: AppRouter
    }

    func scene(tab: AppTab = .home, _ selection: SidebarSelection? = nil, playlists: Int = 1) throws -> Scene {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        try FixtureLibrary.seed(c)
        for i in 1..<max(1, playlists) { try FixtureLibrary.seedEmpty(c, name: "Playlist \(i + 1)") }
        try FixtureLibrary.seedUserData(c)
        let state = AppState(container: c, defaults: UserDefaults(suiteName: "snap-\(UUID().uuidString)")!)
        state.reload(); state.loaded = true
        let router = AppRouter()
        router.navigate(tab, selection)
        return Scene(container: c, state: state, router: router)
    }

    /// Draws `view` at `size` after letting async loads settle.
    func capture<V: View>(_ view: V, size: CGSize, settle: Double = 1.6, name: String) async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host
        win.appearance = NSAppearance(named: .darkAqua)
        let end = Date().addingTimeInterval(settle)
        while Date() < end { try await Task.sleep(nanoseconds: 60_000_000); Self.pump(0.03) }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { Issue.record("no bitmap for \(name)"); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name + ".png"))
        win.orderOut(nil)
    }

    func shell(_ s: Scene) -> some View {
        MainShell(router: s.router, keys: PlayerKeyMonitor(), container: s.container, state: s.state)
    }

    nonisolated static func pump(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    static let sizes: [(String, CGSize)] = [("1440", CGSize(width: 1440, height: 900)), ("1024", CGSize(width: 1024, height: 680))]

    @Test func home() async throws {
        for (tag, size) in Self.sizes { let s = try scene(); try await capture(shell(s), size: size, settle: 2.5, name: "home-\(tag)") }
    }
    @Test func moviesFeatured() async throws {
        for (tag, size) in Self.sizes { let s = try scene(tab: .movies, .shortcut(.featured)); try await capture(shell(s), size: size, name: "movies-featured-\(tag)") }
    }
    @Test func moviesAll() async throws {
        for (tag, size) in Self.sizes { let s = try scene(tab: .movies, .shortcut(.allMovies)); try await capture(shell(s), size: size, name: "movies-all-\(tag)") }
    }
    @Test func series() async throws {
        for (tag, size) in Self.sizes { let s = try scene(tab: .series, .shortcut(.library)); try await capture(shell(s), size: size, name: "series-\(tag)") }
    }
    @Test func live() async throws {
        for (tag, size) in Self.sizes { let s = try scene(tab: .liveTV, .shortcut(.allChannels)); try await capture(shell(s), size: size, name: "live-\(tag)") }
    }
    @Test func guide() async throws {
        for (tag, size) in Self.sizes { let s = try scene(tab: .guide, .shortcut(.allChannels)); try await capture(shell(s), size: size, settle: 2.2, name: "guide-\(tag)") }
    }
    @Test func playlistMenu() async throws {
        for (tag, size) in Self.sizes { let s = try scene(playlists: 3); s.router.playlistMenuOpen = true; try await capture(shell(s), size: size, name: "playlist-\(tag)") }
    }
    @Test func accountMenu() async throws {
        let s = try scene(); s.router.accountMenuOpen = true
        try await capture(shell(s), size: Self.sizes[0].1, name: "account-1440")
    }
    @Test func detailDialog() async throws {
        let s = try scene(tab: .movies, .shortcut(.allMovies))
        let m = try #require(try s.container.catalog.movies(VODQuery(limit: 1)).first)
        s.router.open(movie: m)
        try await capture(shell(s), size: Self.sizes[0].1, name: "detail-1440")
    }
    static let allSizes: [(String, CGSize)] = [("1024", CGSize(width: 1024, height: 680)), ("1280", CGSize(width: 1280, height: 800)), ("1440", CGSize(width: 1440, height: 900)), ("1728", CGSize(width: 1728, height: 1117))]

    @Test func homeCardPages() async throws {
        for (tag, size) in Self.allSizes {
            let a = try scene(tab: .home, .shortcut(.continueWatching)); try await capture(shell(a), size: size, settle: 3, name: "continue-\(tag)")
            let b = try scene(tab: .home, .shortcut(.recentlyWatched)); try await capture(shell(b), size: size, settle: 3, name: "recent-\(tag)")
            let c = try scene(tab: .home, .shortcut(.favorites)); try await capture(shell(c), size: size, settle: 3, name: "favorites-\(tag)")
        }
    }
    @Test func inlineSearch() async throws {
        for (tag, size) in Self.sizes {
            let s = try scene(tab: .movies, .shortcut(.allMovies)); s.router.searchQuery = "harvest"
            try await capture(shell(s), size: size, settle: 6, name: "search-movies-\(tag)")
        }
        let h = try scene(); h.router.searchQuery = "news"
        try await capture(shell(h), size: Self.sizes[0].1, settle: 6, name: "search-home-1440")
    }
    @Test func movieBottomBar() async throws {
        let st = BottomPlayerState(title: "The Last Voyage 1", meta: "2018 · Drama", status: "Playing", artworkURL: nil, isLive: false, isPlaying: true,
                                   isBusy: false, failed: false, position: 2712, duration: 6000, volume: 0.8, muted: false)
        let bar = ReddyBottomPlayer(state: st, onTitle: {}, onTogglePlay: {}, onToggleMute: {}, onVolume: { _ in }, onSeek: { _ in }, onExpand: {}, onStop: {})
            .reddyTheme(try scene().container.settings)
        try await capture(VStack(spacing: 0) { Spacer(); bar }.background(ColorTokens.background), size: CGSize(width: 1440, height: 160), name: "movie-bar-1440")
        try await capture(VStack(spacing: 0) { Spacer(); bar }.background(ColorTokens.background), size: CGSize(width: 1024, height: 160), name: "movie-bar-1024")
    }
    @Test func onboarding() async throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let state = AppState(container: c, defaults: UserDefaults(suiteName: "snap-\(UUID().uuidString)")!)
        state.reload(); state.loaded = true
        let s = Scene(container: c, state: state, router: AppRouter())
        try await capture(shell(s), size: Self.sizes[0].1, name: "onboarding-1440")
    }

    /// Settings must open quickly: every page is built and laid out.
    @Test func settingsPages() async throws {
        let sc = try scene()
        func env<V: View>(_ v: V) -> some View { v.environment(sc.container.settings).environment(sc.state).environment(sc.router).environment(\.container, sc.container).environment(\.artwork, sc.container.artwork).reddyTheme(sc.container.settings) }
        let pages: [(String, AnyView)] = [
            ("general", AnyView(GeneralSettingsPage())), ("playback", AnyView(PlaybackSettingsPage())),
            ("library", AnyView(LibrarySettingsPage(vm: LibrarySettingsViewModel()))), ("advanced", AnyView(AdvancedSettingsPage(vm: AdvancedSettingsViewModel())))]
        for (name, page) in pages {
            let started = Date()
            try await capture(env(page).frame(width: 660), size: CGSize(width: 660, height: 760), settle: 0.8, name: "settings-\(name)")
            let took = Date().timeIntervalSince(started)
            #expect(took < 15, "Settings page \(name) took \(took)s to render")
        }
        try await capture(env(SettingsView()), size: CGSize(width: 660, height: 620), settle: 0.8, name: "settings-window")
    }

    @Test func channelManager() async throws {
        let sc = try scene()
        func env<V: View>(_ v: V) -> some View { v.environment(sc.container.settings).environment(sc.state).environment(sc.router).environment(\.container, sc.container).environment(\.artwork, sc.container.artwork).reddyTheme(sc.container.settings).background(ColorTokens.background) }
        try await capture(env(ChannelCommandCenterView()), size: CGSize(width: 940, height: 640), settle: 1.5, name: "manager-channels")
        try await capture(env(FoldersPane()), size: CGSize(width: 940, height: 580), settle: 1.5, name: "manager-folders")
    }

    @Test func themes() async throws {
        defer { ThemeStore.current = .obsidian }
        for t in [AppTheme.glossyBlack, .liquidGlass] {
            let sc = try scene()
            sc.container.settings.theme = t
            try await capture(shell(sc), size: CGSize(width: 1440, height: 900), settle: 2, name: "theme-\(t.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))")
        }
        let sc = try scene()
        func env<V: View>(_ v: V) -> some View { v.environment(sc.container.settings).environment(sc.state).environment(sc.router).environment(\.container, sc.container).environment(\.artwork, sc.container.artwork).reddyTheme(sc.container.settings) }
        try await capture(env(GeneralSettingsPage()).frame(width: 660), size: CGSize(width: 660, height: 620), settle: 0.8, name: "settings-general-themes")
    }
}
