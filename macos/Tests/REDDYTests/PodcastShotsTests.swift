import Testing
import SwiftUI
import AppKit
@testable import REDDY

/// Renders the Podcasts screens offscreen to PNG files for a look. Runs only when PODCAST_SHOTS names a folder; synthetic data only, no network.
@Suite("Podcast shots") @MainActor struct PodcastShotsTests {
    private static func feedXML() -> String {
        let items = (1...12).map { n in """
        <item><title>Episode \(n): A long title about gardens, soil and the people who dig</title><description><![CDATA[<p>In this episode we talk about growing food in small spaces and what to plant first. We also answer listener questions about compost, light and watering through the winter months.</p><p>Learn more about your ad choices. Visit megaphone.fm/adchoices</p>]]></description>
        <enclosure url="https://cdn.example/\(n).mp3" type="audio/mpeg"/><pubDate>Tue, \(String(format: "%02d", n)) Oct 2026 08:00:00 +0000</pubDate><itunes:duration>\(1500 + n * 120)</itunes:duration><guid>g\(n)</guid></item>
        """ }.joined()
        return """
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>The Evening Garden</title><itunes:author>Radio One</itunes:author>
        <description>Weekly conversations about growing things, from balconies to allotments. Practical advice, plant stories and a little history. New episodes every Tuesday morning.</description>
        <itunes:category text="Leisure"/><itunes:category text="Society &amp; Culture"/>\(items)</channel></rss>
        """
    }

    private func shot<V: View>(_ view: V, _ size: CGSize, _ file: String, dir: String) async throws {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height).background(ColorTokens.background).environment(\.colorScheme, .dark).environment(\.reddyAccent, ColorTokens.accentDefault)))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host; win.appearance = NSAppearance(named: .darkAqua)
        win.orderBack(nil)
        for _ in 0..<30 { try await Task.sleep(nanoseconds: 50_000_000) }
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
        withExtendedLifetime(win) {}
    }

    @Test func renderThePodcastScreens() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PODCAST_SHOTS"] else { return }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let d = UserDefaults(suiteName: "podcast.shots.\(UUID())")!
        let xml = Self.feedXML()
        let search = #"{"results":[\#((1...10).map { #"{"collectionName":"Garden Show \#($0)","artistName":"Author \#($0)","feedUrl":"https://f.example/\#($0)"}"# }.joined(separator: ","))]}"#
        let service = PodcastService(defaults: d, fetch: { url in Data((url.host == "itunes.apple.com" ? search : xml).utf8) })
        let chart = #"{"feed":{"results":[\#((1...12).map { #"{"id":"\#($0)"}"# }.joined(separator: ","))]}}"#
        let lookup = #"{"results":[\#((1...12).map { #"{"collectionId":\#($0),"collectionName":"Top Show Number \#($0)","artistName":"Network \#($0)","feedUrl":"https://t.example/\#($0)"}"# }.joined(separator: ","))]}"#
        let catalog = PodcastCatalogService(region: "us", directory: FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID())"), fetch: { url in Data((url.path == "/lookup" ? lookup : chart).utf8) })
        let lib = PodcastLibrary(defaults: d)
        let hub = PodcastsHub(service: service, catalog: catalog, library: lib, player: PodcastPlayer(library: lib, engine: AVPodcastEngine(), autoTick: false))
        for n in 1...3 { _ = try await service.subscribe(URL(string: "https://feeds.example/\(n).xml")!) }
        hub.reloadFollowing()
        let feedURL = URL(string: "https://feeds.example/1.xml")!
        lib.noteLatest(Date(timeIntervalSince1970: 100), for: feedURL); lib.noteLatest(Date(timeIntervalSince1970: 900), for: feedURL)
        let feed = try #require(PodcastParser.parse(Data(xml.utf8)))
        let sub = hub.following[0]
        for n in [2, 5] { let r = PodcastEpisodeRef(feed.episodes[n], show: sub); lib.setPosition(r, position: 700, duration: 1800) }
        lib.markPlayed(PodcastEpisodeRef(feed.episodes[1], show: sub), true)
        hub.loadTop()
        for _ in 0..<40 { if case .loaded = hub.top { break }; try await Task.sleep(nanoseconds: 25_000_000) }
        let saved = ThemeStore.current; ThemeStore.state.frostedOnly = true; defer { ThemeStore.current = saved; ThemeStore.state.frostedOnly = false }
        let only = ProcessInfo.processInfo.environment["PODCAST_SHOT_THEMES"]?.split(separator: ",").map(String.init)
        for theme in AppTheme.allCases where theme != .custom && (only == nil || only!.contains(theme.rawValue)) {
            ThemeStore.current = theme
            let t = theme.rawValue.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "é", with: "e")
            func page(_ v: some View, _ w: CGFloat, _ h: CGFloat) -> some View { HStack(spacing: 0) { PodcastsSidebar(hub: hub); v }.frame(width: w, height: h).background(ThemeBackdrop()) }
            hub.player.close(); hub.nav = PodcastsNav(); hub.clearSearch()
            hub.select(.discover)
            try await shot(page(PodcastsMainView(hub: hub), 1440, 900), CGSize(width: 1440, height: 900), "\(t)-home.png", dir: dir)
            hub.term = "garden"; hub.search()
            for _ in 0..<40 where hub.found.isEmpty { try await Task.sleep(nanoseconds: 25_000_000) }
            try await shot(page(PodcastsMainView(hub: hub), 1440, 700), CGSize(width: 1440, height: 700), "\(t)-search.png", dir: dir)
            hub.clearSearch()
            hub.open(sub)
            try await shot(page(PodcastsMainView(hub: hub), 1440, 900), CGSize(width: 1440, height: 900), "\(t)-show-wide.png", dir: dir)
            if only != nil { try await shot(PodcastsMainView(hub: hub).background(ThemeBackdrop()), CGSize(width: 760, height: 900), "\(t)-show-narrow.png", dir: dir) }
            hub.back()
            hub.player.play(PodcastEpisodeRef(feed.episodes[2], show: sub))
            hub.player.pause()
            hub.library.clearQueue(); hub.library.addToQueue(PodcastEpisodeRef(feed.episodes[4], show: sub))
            try await shot(VStack(spacing: 0) { Spacer(); PodcastPlayerBar(hub: hub) }.background(ThemeBackdrop()), CGSize(width: 1440, height: 120), "\(t)-bar.png", dir: dir)
            try await shot(PodcastNowPlayingPanel(hub: hub).background(ColorTokens.panel), CGSize(width: 900, height: 560), "\(t)-panel.png", dir: dir)
            if only != nil {
                let vs = SidebarViewState(title: "Movies", pinned: SidebarModel.pinned(for: .movies), folders: [], selection: .shortcut(Shortcut.pinned(for: .movies)[0]), collapsed: false, playlistName: "Demo", playlists: [], activePlaylistID: nil, playlistMenuOpen: false)
                var q = ""
                try await shot(HStack(spacing: 0) { ReddySidebar(state: vs, folderQuery: Binding(get: { q }, set: { q = $0 }), onSelect: { _ in }, onToggleCollapse: {}, onTogglePlaylistMenu: {}, onSwitchPlaylist: { _ in }, onAddPlaylist: {}); PodcastsSidebar(hub: hub) }.background(ThemeBackdrop()), CGSize(width: 400, height: 400), "\(t)-sidebars.png", dir: dir)
            }
            hub.player.close()
        }
    }
}
