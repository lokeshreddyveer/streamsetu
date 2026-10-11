import Foundation
import CoreGraphics
import MediaPlayer

/// Developer self-test, run from the packaged app so it exercises exactly what ships (signing, Hardened Runtime, bundled libmpv):
///
///     STREAMSETU_SELFTEST_MEDIA=/path/video.mp4 StreamSetu.app/Contents/MacOS/StreamSetu
///
/// It plays the file through the real engines, uses the controls that touch libmpv's and AVPlayer's internals, checks the
/// threading rules of the system callbacks, and exits 0 only if every step passed. No window is opened. `Scripts/smoke-test-app.sh`
/// runs it against a freshly generated video and is part of `Scripts/verify-release.sh`.
enum SelfTest {
    static var requested: String? {
        let env = ProcessInfo.processInfo.environment
        return env["STREAMSETU_SELFTEST_MEDIA"] ?? env["REDDY_SELFTEST_MEDIA"]
    }

    private struct Report {
        var lines: [String] = []
        var failed = false
        mutating func pass(_ s: String) { lines.append("  ok   \(s)") }
        mutating func fail(_ s: String) { lines.append("  FAIL \(s)"); failed = true }
        mutating func check(_ ok: Bool, _ s: String) { if ok { pass(s) } else { fail(s) } }
    }

    @MainActor static func run(_ path: String) {
        Task { @MainActor in
            var r = Report()
            let url = URL(fileURLWithPath: path)

            // 1. database opens and migrates to the newest schema
            do {
                let db = try DatabaseManager(path: FileManager.default.temporaryDirectory.appendingPathComponent("selftest-\(UUID().uuidString).sqlite").path)
                let v = try db.read { try $0.scalarInt("PRAGMA user_version") }
                r.check(v == DatabaseMigrator.latestVersion, "database migrated to v\(v)")
            } catch { r.fail("database: \(error)") }

            // 2. the system asks for Now Playing artwork on a background queue; that must not trap
            if let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
               let image = ctx.makeImage() {
                let ok = await artworkFromBackgroundQueue(image)
                r.check(ok, "Now Playing artwork from a background queue")
            }

            // 3. MPV (the engine that ships libmpv and the Lua restriction)
            if MPVPlayerEngine.isAvailable {
                let e = MPVPlayerEngine()
                e.configuration.liveRewind = true
                await exercise(e, url: url, live: true, &r)
            } else { r.lines.append("  skip MPV: libmpv is not available in this build") }

            // 4. AVPlayer
            await exercise(AVPlayerEngine(), url: url, live: false, &r)

            // 5. multi-view: four tiles must all be playing at the same time
            await multiView(url: url, &r)

            print("SELFTEST \(r.failed ? "FAIL" : "OK")")
            r.lines.forEach { print($0) }
            exit(r.failed ? 1 : 0)
        }
    }

    @MainActor private static func multiView(url: URL, _ r: inout Report) async {
        let source = UUID()
        let model = MultiViewModel(resolve: { c in PlaybackRequest(itemID: c.id, kind: .channel, sourceID: c.sourceID, title: c.name, url: url, isLive: false) })
        for i in 1...4 {
            let ch = Channel(id: "mv-\(i)", sourceID: source, providerID: "\(i)", name: "Tile \(i)", normalizedName: "tile \(i)", categoryID: nil, categoryName: nil,
                             logoURL: nil, epgID: nil, language: nil, country: nil, resolutionHint: nil, sortOrder: i, streamRef: "x", groupKey: nil)
            model.add(ch)
        }
        let end = Date().addingTimeInterval(20)
        while Date() < end, !model.tiles.allSatisfy({ $0.engine.state == .playing && $0.engine.position > 0.5 }) { try? await Task.sleep(nanoseconds: 100_000_000) }
        for t in model.tiles { r.check(t.engine.state == .playing && t.engine.position > 0.5, "multi-view: \(t.channel.name) plays (state \(t.engine.state), \(String(format: "%.1f", t.engine.position)) s)") }
        r.check(model.tiles.filter { !$0.engine.player.isMuted }.count == 1, "multi-view: exactly one tile has sound")
        // moving the sound between tiles must not disturb any stream
        for i in [1, 2, 3, 0] { model.selectTile(at: i); try? await Task.sleep(nanoseconds: 400_000_000) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        for t in model.tiles { r.check(t.engine.state == .playing && t.failure == nil, "multi-view: \(t.channel.name) still playing after moving the sound") }
        model.removeAll()
    }

    private struct ArtworkBox: @unchecked Sendable { let item: MPMediaItemArtwork }

    private static func artworkFromBackgroundQueue(_ image: CGImage) async -> Bool {
        let box = ArtworkBox(item: NowPlayingService.makeArtwork(image))
        return await withCheckedContinuation { c in
            DispatchQueue.global().async { c.resume(returning: box.item.image(at: CGSize(width: 4, height: 4)) != nil) }
        }
    }

    @MainActor private static func exercise(_ engine: any PlaybackEngine, url: URL, live: Bool, _ r: inout Report) async {
        let name = engine.kind.rawValue
        let req = PlaybackRequest(itemID: "selftest-\(name)", kind: live ? .channel : .movie, sourceID: UUID(), title: "Self-test", url: url, isLive: live)
        do { try await engine.load(req) } catch { r.fail("\(name): load threw \(error)"); return }
        let end = Date().addingTimeInterval(15)
        while Date() < end, !(engine.state == .playing && engine.position > 0.8) {
            if case .failed(let e) = engine.state { r.fail("\(name): failed \(e.kind) \(e.detail ?? "")"); return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        r.check(engine.state == .playing && engine.position > 0.8, "\(name): plays (position \(String(format: "%.1f", engine.position)) s)")
        // controls that reach into the engine
        engine.setVolume(0.5); engine.setMuted(true); engine.setRate(1.25); engine.setRate(1)
        engine.setAudioDelay(0.1); engine.setSubtitleDelay(0.2)
        engine.setPicture(PictureAdjustments(brightness: 10, contrast: -5, saturation: 20, gamma: 0, hue: 0))
        engine.applySubtitleStyle(SubtitleStyle())
        _ = engine.availableAudioTracks(); _ = engine.availableSubtitleTracks()
        r.pass("\(name): controls accepted")
        if engine.kind == .mpv {
            r.check(engine.liveBufferEnd != nil, "\(name): live buffer readable")
            r.check(engine.screenshot() != nil, "\(name): screenshot")
        }
        engine.pause()
        try? await Task.sleep(nanoseconds: 300_000_000)
        try? await engine.play()
        try? await engine.seek(to: 1.0)
        try? await Task.sleep(nanoseconds: 700_000_000)
        r.check(engine.position >= 0.5 || engine.state == .ended, "\(name): pause, play and seek (position \(String(format: "%.1f", engine.position)) s)")
        engine.stop()
        r.pass("\(name): stops")
    }
}
