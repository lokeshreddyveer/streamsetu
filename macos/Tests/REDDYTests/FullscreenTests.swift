import Testing
import AppKit
import Foundation
@testable import REDDY

/// Stand-in for the fullscreen window: records what the controller asks for and lets a test deliver the AppKit callbacks.
@MainActor final class FakeFullscreenWindow: FullscreenWindowing {
    var onDidEnter: (() -> Void)?, onDidExit: (() -> Void)?, onClosed: (() -> Void)?
    private(set) var collapsed = 0, presented = 0, toggles = 0, dismissed = 0
    func present(over mainWindow: NSWindow?, completion: @escaping () -> Void) { presented += 1; completion() }
    func finishExit(completion: @escaping () -> Void) { collapsed += 1; completion() }
    func toggleNativeFullscreen() { toggles += 1 }
    func dismiss() { dismissed += 1 }
    func completeEnter() { onDidEnter?() }
    func completeExit() { onDidExit?() }
}

@Suite("Fullscreen playback") @MainActor struct FullscreenTests {
    struct Rig {
        let c: AppContainer
        let fs: FullscreenController
        let windows: () -> [FakeFullscreenWindow]
        let channel: Channel
    }

    func rig() throws -> Rig {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-fs-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let src = try c.sources.addM3U(name: "Local", url: "http://127.0.0.1:9/list.m3u")
        var ch = TestSupport.channel(src, "a", "Channel A"); ch.streamRef = "http://127.0.0.1:9/live/a.ts"
        try c.indexer.commitChannels(source: src, categories: [], channels: [ch])
        let stored = try #require(try c.catalog.channels(ChannelQuery(collapseVariants: false)).first)
        var made: [FakeFullscreenWindow] = []
        let fs = FullscreenController(playback: c.playback, makeWindow: { let w = FakeFullscreenWindow(); made.append(w); return w })
        return Rig(c: c, fs: fs, windows: { made }, channel: stored)
    }

    func settle() async { for _ in 0..<3 { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) } }

    @Test func twentyCyclesNeverTouchThePlaybackSession() async throws {
        let r = try rig(), p = r.c.playback
        let router = AppRouter(); router.navigate(.movies, .folder("cat-9"))
        p.play(channel: r.channel)
        let player = p.avPlayer, loads = p.loadCount, item = p.current
        for i in 1...20 {
            p.isFullscreen = true; r.fs.request(true)
            #expect(r.fs.phase == .entering && p.surfaceOwner == .fullscreen, "the video moves to the fullscreen window first (cycle \(i))")
            r.windows().last?.completeEnter()
            #expect(r.fs.phase == .fullscreen && p.fullscreenPhase == .fullscreen)
            p.isFullscreen = false; r.fs.request(false)
            #expect(r.fs.phase == .exiting)
            r.windows().last?.completeExit()
            #expect(r.fs.phase == .windowed && p.surfaceOwner != .fullscreen, "the fullscreen window lets go of the video")
            await settle()
            #expect(p.surfaceOwner == .expanded, "leaving fullscreen shows the video in the expanded player, never in the small bar")
            #expect(p.avPlayer === player, "the same AVPlayer throughout")
            #expect(p.loadCount == loads && p.current == item, "no restart, same item")
        }
        #expect(r.windows().count == 20 && r.windows().allSatisfy { $0.dismissed == 1 && $0.presented == 1 && $0.toggles == 2 }, "one window per cycle, each dismissed exactly once")
        #expect(router.tab == .movies && router.selection == .folder("cat-9"), "navigation is untouched")
    }

    @Test func rapidToggleSettlesOnTheLastRequest() async throws {
        let r = try rig(), p = r.c.playback
        p.play(channel: r.channel)
        r.fs.request(true); r.fs.request(false); r.fs.request(true); r.fs.request(false)
        #expect(r.windows().count == 1 && r.fs.phase == .entering, "requests during a transition do not start another")
        r.windows()[0].completeEnter()                       // the entry finishes, then the pending exit begins
        #expect(r.fs.phase == .exiting)
        r.windows()[0].completeExit()
        await settle()
        #expect(r.fs.phase == .windowed && p.surfaceOwner == .expanded && r.windows().count == 1)
        r.fs.request(true); r.fs.request(false); r.fs.request(true)
        r.windows()[1].completeEnter()
        #expect(r.fs.phase == .fullscreen, "last request was 'on', so it stays on")
        r.windows()[1].completeExit()                         // system exit (green button / menu)
        await settle()
        #expect(r.fs.phase == .windowed && p.isFullscreen == false)
    }

    @Test func leavingBySystemControlsResetsTheRequestAndTheButton() async throws {
        let r = try rig(), p = r.c.playback
        p.play(channel: r.channel)
        p.isFullscreen = true; r.fs.request(true); r.windows()[0].completeEnter()
        r.windows()[0].completeExit()                         // not requested by us
        await settle()
        #expect(p.isFullscreen == false && p.fullscreenPhase == .windowed && p.surfaceOwner == .expanded)
    }

    @Test func nothingHappensWithoutPlayback() throws {
        let r = try rig()
        r.c.playback.isFullscreen = true
        r.fs.request(true)
        #expect(r.windows().isEmpty && r.fs.phase == .windowed && r.c.playback.isFullscreen == false)
    }

    @Test func closingTheFullscreenWindowRestoresEverything() throws {
        let r = try rig(), p = r.c.playback
        p.play(channel: r.channel); p.isFullscreen = true; r.fs.request(true)
        r.windows()[0].onClosed?()
        #expect(r.fs.phase == .windowed && p.isFullscreen == false && p.surfaceOwner == .expanded)
    }

    @Test func onlyOneSurfaceOwnerAtATime() throws {
        let p = try rig().c.playback
        #expect(p.surfaceOwner == .bar)
        p.isExpanded = true; #expect(p.surfaceOwner == .expanded)
        p.isPoppedOut = true; #expect(p.surfaceOwner == .popout)
        p.fullscreenPhase = .entering; #expect(p.surfaceOwner == .fullscreen, "fullscreen outranks everything")
        p.fullscreenPhase = .windowed; p.isPoppedOut = false; p.isExpanded = false
        #expect(p.surfaceOwner == .bar)
    }

    @Test func stoppingPlaybackLeavesFullscreen() throws {
        let r = try rig(), p = r.c.playback
        p.play(channel: r.channel); p.isFullscreen = true
        p.stop()
        #expect(p.isFullscreen == false && p.isExpanded == false && p.current == nil)
    }

    @Test func fullscreenFromExpandedPlayerReturnsToIt() async throws {
        let r = try rig(), p = r.c.playback
        p.play(channel: r.channel)
        p.isExpanded = true
        p.restoreExpandedAfterFullscreen = true; p.isExpanded = false; p.isFullscreen = true; r.fs.request(true)
        r.windows()[0].completeEnter()
        p.isFullscreen = false; r.fs.request(false); r.windows()[0].completeExit()
        await settle()
        #expect(p.isExpanded, "back to the expanded player, same session")
    }

    // MARK: real windows (needs a logged-in display; opt-in)

    /// Drives real NSWindows through native fullscreen. Needs a window server, so it is opt-in: REDDY_UI_TESTS=1.
    /// Plays a real local movie (REDDY_TEST_MEDIA, or a system wallpaper clip) so a stream failure cannot be mistaken for a restart.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDDY_UI_TESTS"] != nil))
    func realWindowsTwentyCycles() async throws {
        _ = NSApplication.shared
        let media = ProcessInfo.processInfo.environment["REDDY_TEST_MEDIA"] ?? "/System/Library/Desktop Pictures/.wallpapers/Sonoma/Sonoma Graphic Dark Landscape.mov"
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-fs-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let src = try c.sources.addM3U(name: "Local", url: "http://127.0.0.1:9/list.m3u")
        var m = TestSupport.movie(src, "m", "Clip", year: 2024); m.streamRef = URL(fileURLWithPath: media).absoluteString
        try c.indexer.commitMovies(source: src, categories: [], movies: [m])
        let movie = try #require(try c.catalog.movies(VODQuery(sourceID: src.id)).first)
        let p = c.playback
        let fs = FullscreenController(playback: p, makeWindow: { PlayerFullscreenWindow(title: "REDDY", content: FullscreenPlayerRoot(container: c)) })
        let main = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 700), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        main.makeKeyAndOrderFront(nil)
        let frame = main.frame
        p.play(movie: movie)
        for _ in 0..<100 where !(p.state == .playing || p.state.isBusy == false && p.state != .idle) { try await Task.sleep(nanoseconds: 50_000_000) }
        let player = p.avPlayer, loads = p.loadCount, item = p.current
        print("UI-TEST state before:", p.state, "loads:", loads)
        func wait(_ phase: FullscreenPhase) async { for _ in 0..<600 where fs.phase != phase { try? await Task.sleep(nanoseconds: 25_000_000) } }
        for i in 1...20 {
            p.isFullscreen = true; fs.request(true); await wait(.fullscreen)
            #expect(fs.phase == .fullscreen, "enter \(i)")
            #expect(p.surfaceOwner == .fullscreen)
            p.isFullscreen = false; fs.request(false); await wait(.windowed)
            #expect(fs.phase == .windowed && p.surfaceOwner == .expanded, "exit \(i)")
            #expect(main.frame == frame, "main window geometry unchanged")
            #expect(p.avPlayer === player && p.loadCount == loads && p.current == item, "no restart (cycle \(i))")
        }
        print("UI-TEST state after:", p.state, "loads:", p.loadCount, "windows:", NSApp.windows.count)
        p.stop()
    }
}
