import Testing
import Foundation
@testable import REDDY

/// Exercises the real libmpv engine. Skipped unless REDDY_LIBMPV points at a libmpv build and REDDY_TEST_MEDIA at a file:
///   REDDY_LIBMPV=/path/libmpv.2.dylib REDDY_TEST_MEDIA=/path/sample.mkv Scripts/run-tests.sh MPVEngine
@Suite("MPV engine (opt-in)", .enabled(if: ProcessInfo.processInfo.environment["REDDY_LIBMPV"] != nil && ProcessInfo.processInfo.environment["REDDY_TEST_MEDIA"] != nil))
@MainActor struct MPVEngineTests {
    func request() -> PlaybackRequest {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REDDY_TEST_MEDIA"]!)
        return PlaybackRequest(itemID: "test", kind: .movie, sourceID: UUID(), title: "Sample", url: url, isLive: false)
    }

    func waitFor(_ engine: MPVPlayerEngine, seconds: Double = 15, _ cond: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 100_000_000) }
        return cond()
    }

    @Test func playsAnMKVSeeksPausesAndRendersFrames() async throws {
        #expect(MPVPlayerEngine.isAvailable, "libmpv should load from REDDY_LIBMPV")
        let e = MPVPlayerEngine()
        var states: [PlaybackState] = []
        let collector = Task { @MainActor in for await s in e.stateUpdates { states.append(s) } }
        try await e.load(request())
        #expect(await waitFor(e) { e.state == .playing }, "reaches playing; states: \(states)")
        #expect(await waitFor(e) { e.position > 1.0 }, "position advances, now \(e.position)")
        #expect(await waitFor(e) { e.metrics.width > 0 }, "video size reported")
        print("  MPV metrics:", e.metrics.summary, "| duration:", e.duration ?? -1, "| audio tracks:", e.availableAudioTracks().count, "| codecs:", e.metrics.videoCodec ?? "-", e.metrics.audioCodec ?? "-")
        #expect(await waitFor(e) { e.screenshot() != nil }, "frames are rendered to pixel buffers")
        if let img = e.screenshot() { #expect(img.width > 0 && img.height > 0); print("  frame:", img.width, "x", img.height) }
        #expect((e.duration ?? 0) > 1)

        e.pause()
        #expect(e.state == .paused)
        let frozen = e.position
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(abs(e.position - frozen) < 0.2, "paused video does not advance")
        try await e.play()
        #expect(await waitFor(e) { e.state == .playing })

        try await e.seek(to: 3)
        #expect(await waitFor(e) { e.position >= 2.5 }, "seek lands near the target, at \(e.position)")
        e.setVolume(0.3); e.setMuted(true); e.setRate(1.5)
        e.stop()
        #expect(e.state == .idle)
        collector.cancel()
        #expect(states.contains(.preparing) && states.contains(.playing), "state stream saw the lifecycle: \(states)")
    }

    @Test func reportsAMissingFileAsAFailureNotASpinner() async throws {
        let e = MPVPlayerEngine()
        var req = request(); req = PlaybackRequest(itemID: "x", kind: .movie, sourceID: UUID(), title: "Missing", url: URL(fileURLWithPath: "/nonexistent/none.mkv"), isLive: false)
        try await e.load(req)
        let failed = await waitFor(e, seconds: 10) { if case .failed = e.state { true } else { false } }
        #expect(failed, "state: \(e.state)")
        e.stop()
    }

    /// Regression: tearing the engine down while its event thread sat in mpv_wait_event destroyed the context under it,
    /// and libmpv aborted (ta_set_parent assertion). Channel switches and retries do exactly this, back to back.
    @Test func rapidLoadAndStopNeverCrashes() async throws {
        let e = MPVPlayerEngine()
        e.setMuted(true)
        for i in 0..<60 {
            try await e.load(request())
            try await Task.sleep(nanoseconds: UInt64((i % 7) * 9_000_000))     // land at different points of the event loop
            if i % 3 == 0 { e.stop() }
        }
        e.stop()
        #expect(e.state == .idle)
    }
}

@Suite("MPV version probe (opt-in)", .enabled(if: ProcessInfo.processInfo.environment["REDDY_LIBMPV"] != nil))
struct MPVVersionProbeTests {
    /// Settings starts this from two pages at once; it must neither crash nor disagree with itself.
    @Test func concurrentProbesAreSafe() async {
        let results = await withTaskGroup(of: LibraryVersions.self) { g in
            for _ in 0..<6 { g.addTask { EngineInfoService.libraryVersions() } }
            var all: [LibraryVersions] = []
            for await r in g { all.append(r) }
            return all
        }
        #expect(Set(results.map { $0.mpv ?? "" }).count == 1)
    }
}

@Suite("MPV option check (opt-in)", .enabled(if: ProcessInfo.processInfo.environment["REDDY_LIBMPV"] != nil))
struct MPVOptionTests {
    /// Every option the settings can produce must be one the real libmpv accepts, with the values REDDY sends.
    @Test func everyConfigurationOptionIsAcceptedByLibmpv() {
        let lib = MPVLibrary.shared
        guard lib.isAvailable, let create = lib.create else { Issue.record("libmpv did not load"); return }
        var rejected: [String] = []
        for profile in RenderingProfile.allCases {
            for hw in HardwareDecoding.allCases {
                var c = MPVConfiguration()
                c.renderingProfile = profile; c.hardwareDecoding = hw; c.stereoDownmix = true; c.lowLatency = true; c.deinterlace = true; c.isLive = true; c.liveRewind = true
                c.preferredAudioLanguages = ["te", "en"]; c.preferredSubtitleLanguages = ["en"]
                guard let ctx = create() else { Issue.record("no core"); return }
                for (k, v) in c.options where k != "vo" {
                    let r = lib.setOption?(ctx, k, v) ?? 0
                    if r < 0 { rejected.append("\(k)=\(v) → \(r)") }
                }
                lib.terminateDestroy?(ctx)
            }
        }
        #expect(rejected.isEmpty, "libmpv rejected: \(Set(rejected).sorted())")
    }
}

@Suite("MPV picture and subtitle properties (opt-in)", .enabled(if: ProcessInfo.processInfo.environment["REDDY_LIBMPV"] != nil))
struct MPVPropertyTests {
    /// The names REDDY sets while playing must exist in the real libmpv, with values in the range REDDY sends.
    @Test func colourAndSubtitlePropertiesExist() {
        let lib = MPVLibrary.shared
        guard lib.isAvailable, let create = lib.create, let ctx = create() else { Issue.record("libmpv did not load"); return }
        defer { lib.terminateDestroy?(ctx) }
        for (k, v) in MPVConfiguration.isolationOptions + [("vo", "null"), ("ao", "null"), ("idle", "yes"), ("terminal", "no")] { _ = lib.setOption?(ctx, k, v) }
        guard lib.initialize?(ctx) == 0 else { Issue.record("mpv failed to initialise"); return }
        var rejected: [String] = []
        let values: [(String, String)] = [("brightness", "-100"), ("brightness", "100"), ("contrast", "50"), ("saturation", "-30"), ("gamma", "25"), ("hue", "-90"),
                                          ("sub-delay", "1.5"), ("audio-delay", "-0.3"), ("sub-border-size", "3"), ("sub-shadow-offset", "1"), ("sub-pos", "90"), ("sub-scale", "1.2"),
                                          ("sub-color", "#FFFFFF"), ("sub-back-color", "#80000000"), ("speed", "1.25"), ("volume", "70")]
        for (k, v) in values { let r = lib.setProperty?(ctx, k, v) ?? -1; if r < 0 { rejected.append("\(k)=\(v) → \(r)") } }
        #expect(rejected.isEmpty, "libmpv rejected: \(rejected)")
    }
}


@Suite("MPV built-in scripts stay off (opt-in)", .enabled(if: ProcessInfo.processInfo.environment["REDDY_LIBMPV"] != nil))
struct MPVScriptIsolationTests {
    /// Hardened Runtime kills a process that runs LuaJIT ("Invalid Page"). libmpv starts its own Lua scripts on its own, one switch
    /// per script, and a newer libmpv can add one. This reads the switches out of the real library and fails if any is left on.
    @Test func everyLoadSwitchInTheLibraryIsHandled() throws {
        let path = try #require(ProcessInfo.processInfo.environment["REDDY_LIBMPV"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let text = String(decoding: data, as: UTF8.self)
        let found = Set(text.matches(of: /load-[a-z]+(?:-[a-z]+)*/).map { String($0.output) })
        let off = Set(MPVConfiguration.isolationOptions.map(\.0))
        // Switches that do not start a script (they read files or playlists, not Lua)
        let harmless: Set<String> = ["load-unsafe-playlists", "load-config-file", "load-input-conf", "load-script", "load-auto-profiles", "load-scripts", "load-files"]
        let unhandled = found.subtracting(off).subtracting(harmless)
        #expect(unhandled.isEmpty, "libmpv has script switches REDDY doesn't turn off: \(unhandled.sorted())")
        #expect(found.contains("load-positioning"), "the check really read the library")
    }
}
