import Foundation
import AVFoundation

// Muted end-to-end playback matrix for the Music module. See Scripts/music-playback-matrix.sh for how to run it.
// Every step uses the app's own code: the provider structs, MusicRegistry, MusicStreamResolver (+ MusicSourceChain hook, health, playback log),
// MusicStreamProxy and the same direct-or-proxy decision MusicPlayer.makeLoaded makes. The AVPlayer is created muted at volume 0.

// MARK: configuration

struct Query { let label: String; let text: String }
let allQueries = [Query(label: "English", text: "Bohemian Rhapsody"), Query(label: "Tamil", text: "Kaavaalaa"),
                  Query(label: "Telugu", text: "Dakko Dakko Meka"), Query(label: "Hindi", text: "Tum Hi Ho")]

/// Public Spotify track pages, read signed out through the embed route. Override with MATRIX_SPOTIFY="label=trackID,..".
nonisolated(unsafe) var spotifyIDs: [String: String] = ["English": "7tFiyTwD0nx5a1eklYtX2J", "Tamil": "1cPDOeVdALLjj4erFPiuqW", "Telugu": "0z2hHT6puSqiw3p86El7Kp", "Hindi": "56zZ48jdyY2oDXHVnwg5Di"]

let env = ProcessInfo.processInfo.environment
let playSeconds = Double(env["MATRIX_PLAY_SECONDS"] ?? "") ?? 8
let seekTarget = Double(env["MATRIX_SEEK_TO"] ?? "") ?? 30
let onlyProviders = Set((env["MATRIX_PROVIDERS"] ?? "").split(separator: ",").map(String.init))
let onlyQueries = Set((env["MATRIX_QUERIES"] ?? "").split(separator: ",").map { $0.lowercased() })
let outPath = env["MATRIX_OUT"]
let localFolder = env["MATRIX_LOCAL_DIR"] ?? NSTemporaryDirectory() + "music-matrix-local-\(getpid())"

// MARK: results

struct Cell {
    var provider: String, query: String
    var search = "-", track = "-", resolve = "-", route = "-", ttr = "-", advance = "-", seek = "-", firstSound = "-", stages = "-", replay = "-"
    var result = "FAIL", failStep = "", error = ""
}

nonisolated(unsafe) var cells: [Cell] = []
func say(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func errText(_ e: Error) -> String {
    if let m = e as? MusicError { return "MusicError.\(m)" }
    let n = e as NSError
    var s = "\(n.domain)#\(n.code) \(n.localizedDescription)"
    if let u = n.userInfo[NSUnderlyingErrorKey] as? NSError { s += " <- \(u.domain)#\(u.code)" }
    return s
}

// MARK: registry

/// Mirrors MusicBuiltIns.register (which also needs the whole library and catalog runtime); keep the provider list in step with it.
@MainActor func registerBuiltIns(_ reg: MusicRegistry) {
    reg.register(AudiusProvider()); reg.register(JioSaavnProvider()); reg.register(ITunesProvider()); reg.register(SpotifyProvider())
    reg.register(YouTubeMusicProvider()); YouTubeMusicBuiltIns.register(into: reg)
    reg.register(PipedProvider()); reg.register(InvidiousProvider()); reg.register(LocalFilesProvider())
    reg.register(LRCLibProvider())
}

@MainActor func makeRegistry(enable: (String) -> Bool, localStore: LocalLibraryStore? = nil) -> MusicRegistry {
    let reg = MusicRegistry(defaults: UserDefaults(suiteName: "matrix.\(UUID().uuidString)")!)
    registerBuiltIns(reg)
    if let localStore { reg.register(LocalFilesProvider(store: localStore)) }
    for p in reg.all where enable(p.id) { reg.setEnabled(true, id: p.id, reason: .setup) }
    return reg
}

@MainActor func makeResolver(_ reg: MusicRegistry) -> (MusicStreamResolver, MusicPlaybackLog) {
    let r = MusicStreamResolver(registry: reg)
    let log = MusicPlaybackLog()
    r.log = log
    r.chain = MusicSourceChain(store: AddonStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("matrix-addons-\(UUID().uuidString)")), registry: reg)
    return (r, log)
}

// MARK: player (same decisions as MusicPlayer.makeLoaded)

struct PlayReport {
    var route = "direct", ttr = 0.0, advanced = 0.0, duration = 0.0, seek = "n/a", error: String?, failStep = ""
}

let sharedProxy = MusicStreamProxy()

/// `quick` stops right after the first sound (the repeat-play measurement); `key` is the track uid the start timeline is kept under.
@MainActor func play(_ stream: MusicStream, key: String? = nil, quick: Bool = false) async -> PlayReport {
    var rep = PlayReport()
    let timeline = MusicStartTimeline.shared
    guard let url = URL(string: stream.url) else { rep.error = "bad stream URL"; rep.failStep = "build-item"; return rep }
    if let source = await opusSource(for: stream) { return await playOpus(source, stream, key: key) }
    let bypass = MusicProxyChunker.shouldBypass(proto: stream.proto, url: url, userProxyActive: false)
    let asset: AVURLAsset
    if !bypass, !stream.headers.isEmpty || MusicProxyChunker.throttlesOpenRanges(url),
       let local = await sharedProxy.register(stream, url: url, cacheKey: nil, cache: nil, timelineKey: key) {
        rep.route = "proxy"
        asset = AVURLAsset(url: local)
    } else {
        var options: [String: Any] = [:]
        let directHeaders = MusicProxyPolicy.headers(for: url, base: stream.headers)
        if !directHeaders.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = directHeaders }
        if stream.proto == .hls { options["AVURLAssetOutOfBandMIMETypeKey"] = "application/x-mpegURL" }
        asset = AVURLAsset(url: url, options: options.isEmpty ? nil : options)
        rep.route = url.isFileURL ? "file" : "direct"
    }
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    player.volume = 0
    player.isMuted = true
    if env["MATRIX_FASTSTART"] != "0" { MusicFastStart.apply(item: item, player: player) }
    let t0 = Date()
    while item.status == .unknown, Date().timeIntervalSince(t0) < 25 { try? await Task.sleep(nanoseconds: 20_000_000) }
    rep.ttr = Date().timeIntervalSince(t0)
    if let key, item.status == .readyToPlay { timeline.mark(key, .itemReady) }
    guard item.status == .readyToPlay else {
        rep.failStep = item.status == .failed ? "item-failed" : "ready-timeout"
        rep.error = item.error.map(errText) ?? "not ready after 25 s"
        player.pause(); return rep
    }
    rep.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
    player.volume = 0; player.isMuted = true
    player.play()
    let p0 = player.currentTime().seconds
    let tp = Date()
    if let key {
        let ts = Date()
        while Date().timeIntervalSince(ts) < 10, !(player.rate > 0 && player.currentTime().seconds > p0 + 0.03) { try? await Task.sleep(nanoseconds: 10_000_000) }
        if player.rate > 0, player.currentTime().seconds > p0 + 0.03 { timeline.mark(key, .firstSound) }
    }
    if quick { rep.advanced = 1; player.pause(); return rep }
    while Date().timeIntervalSince(tp) < playSeconds {
        try? await Task.sleep(nanoseconds: 200_000_000)
        if item.status == .failed { rep.failStep = "playing-failed"; rep.error = item.error.map(errText); player.pause(); return rep }
    }
    let elapsed = Date().timeIntervalSince(tp)
    let moved = player.currentTime().seconds - p0
    rep.advanced = moved / max(elapsed, 0.1)
    if rep.advanced < 0.5 {
        rep.failStep = "no-advance"
        rep.error = "position advanced \(String(format: "%.2f", moved)) s in \(String(format: "%.1f", elapsed)) s (rate \(player.rate), timeControlStatus \(player.timeControlStatus.rawValue), waiting: \(player.reasonForWaitingToPlay?.rawValue ?? "-"))"
        player.pause(); return rep
    }
    if rep.duration > seekTarget + 10 {
        let ts = Date()
        let finished: Bool = await withCheckedContinuation { c in
            player.seek(to: CMTime(seconds: seekTarget, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { c.resume(returning: $0) }
        }
        var landed = false
        while Date().timeIntervalSince(ts) < 15 {
            if finished, player.currentTime().seconds >= seekTarget - 1 { landed = true; break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let a = player.currentTime().seconds
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let b = player.currentTime().seconds
        if landed, b - a > 1 { rep.seek = String(format: "ok %.1fs", Date().timeIntervalSince(ts)) }
        else {
            rep.seek = "FAIL"; rep.failStep = "seek"
            rep.error = item.error.map(errText) ?? "after seek position \(String(format: "%.1f", a)) -> \(String(format: "%.1f", b)) (finished=\(finished), landed=\(landed))"
        }
    } else { rep.seek = "skipped (duration \(Int(rep.duration)) s)" }
    player.pause()
    return rep
}

/// WebM and Ogg Opus go to the app's own Opus backend, as MusicPlayer.opusSource decides. Volume is 0 so nothing is audible.
@MainActor func opusSource(for stream: MusicStream) async -> MusicOpusByteSource? {
    guard MusicOpusRouting.isAvailable, stream.proto == .progressive, stream.hasVideo != true || MusicOpusRouting.declaresOpusContainer(stream),
          let source = MusicOpusRouting.source(for: stream) else { return nil }
    if MusicOpusRouting.declaresOpusContainer(stream) { return source }
    guard MusicOpusRouting.needsSniff(stream) else { return nil }
    let kind = await MusicOpusRouting.sniff(source)
    return kind == .webm || kind == .ogg ? source : nil
}

@MainActor func playOpus(_ source: MusicOpusByteSource, _ stream: MusicStream, key: String? = nil) async -> PlayReport {
    var rep = PlayReport(); rep.route = "opus-backend"
    let o = MusicOpusPlayback()
    var failure: String?
    o.onFailed = { _, why in failure = why }
    let t0 = Date()
    o.start(source: source, at: 0, volume: 0, gainDB: 0, playing: true, token: 1)
    o.setVolume(0)
    while o.position < 0.3, failure == nil, Date().timeIntervalSince(t0) < 25 { try? await Task.sleep(nanoseconds: 100_000_000) }
    rep.ttr = Date().timeIntervalSince(t0)
    if let f = failure { rep.failStep = "opus-failed"; rep.error = f; o.stop(); return rep }
    if o.position < 0.3 { rep.failStep = "ready-timeout"; rep.error = "opus backend produced no audio in 25 s"; o.stop(); return rep }
    if let key { MusicStartTimeline.shared.mark(key, .itemReady); MusicStartTimeline.shared.mark(key, .firstSound) }
    rep.duration = o.duration ?? 0
    let p0 = o.position, tp = Date()
    while Date().timeIntervalSince(tp) < playSeconds, failure == nil { try? await Task.sleep(nanoseconds: 200_000_000) }
    if let f = failure { rep.failStep = "opus-failed"; rep.error = f; o.stop(); return rep }
    let elapsed = Date().timeIntervalSince(tp)
    rep.advanced = (o.position - p0) / max(elapsed, 0.1)
    if rep.advanced < 0.5 { rep.failStep = "no-advance"; rep.error = "opus position advanced \(String(format: "%.2f", o.position - p0)) s in \(String(format: "%.1f", elapsed)) s"; o.stop(); return rep }
    if rep.duration > seekTarget + 10 {
        let ts = Date(); o.seek(to: seekTarget)
        var landed = false
        while Date().timeIntervalSince(ts) < 15 { if o.position >= seekTarget - 1 { landed = true; break }; try? await Task.sleep(nanoseconds: 200_000_000) }
        let a = o.position; try? await Task.sleep(nanoseconds: 2_000_000_000); let b = o.position
        if landed, b - a > 1 { rep.seek = String(format: "ok %.1fs", Date().timeIntervalSince(ts)) }
        else { rep.seek = "FAIL"; rep.failStep = "seek"; rep.error = failure ?? "after seek position \(String(format: "%.1f", a)) -> \(String(format: "%.1f", b))" }
    } else { rep.seek = "skipped (duration \(Int(rep.duration)) s)" }
    o.stop()
    return rep
}

// MARK: helpers

func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " } }

func pick(_ tracks: [MusicTrack], _ q: Query) -> MusicTrack? {
    let words = norm(q.text).split(separator: " ").map(String.init)
    let strong = tracks.first { t in let n = norm(t.title); return words.allSatisfy { n.contains($0) } }
    return strong ?? tracks.first
}

func describe(_ s: MusicStream) -> String {
    "\(s.container)/\(s.codec) \(s.bitrate.map { "\($0)k" } ?? (s.isLossless ? "lossless" : "?k")) \(s.proto.rawValue) host=\(URL(string: s.url)?.host ?? "file")"
}

@MainActor func runCell(provider: String, query q: Query, search: () async throws -> MusicTrack?, enableForResolve: @escaping (String) -> Bool,
                        localStore: LocalLibraryStore? = nil) async {
    var c = Cell(provider: provider, query: q.label)
    defer { cells.append(c); say("[\(c.result)] \(provider) / \(q.label): \(c.failStep) \(c.error)") }
    let track: MusicTrack?
    let ts = Date()
    do { track = try await search() } catch { c.search = "FAIL"; c.failStep = "search"; c.error = errText(error); return }
    guard let track else { c.search = "0 results"; c.failStep = "search"; c.error = "no track returned"; return }
    c.search = String(format: "ok %.1fs", Date().timeIntervalSince(ts))
    c.track = "\(track.title) - \(track.artists.map(\.name).joined(separator: ", ")) [\(track.providerID)]"
    let reg = makeRegistry(enable: enableForResolve, localStore: localStore)
    let (resolver, log) = makeResolver(reg)
    let tr = Date()
    let stream: MusicStream
    MusicStartTimeline.shared.begin(track.uid)
    do { stream = try await resolver.resolve(track, quality: .high) } catch {
        c.resolve = "FAIL"; c.failStep = "resolve"
        c.error = errText(error) + " | log: " + log.entries.map { "\($0.provider): \($0.reason)" }.joined(separator: "; ")
        return
    }
    let served = resolver.servedBy(track) ?? (track.directStreams != nil ? track.providerID : "provider-loop")
    c.resolve = String(format: "ok %.1fs by %@ %@", Date().timeIntervalSince(tr), served, describe(stream))
    let rep = await play(stream, key: track.uid)
    if let r = MusicStartTimeline.shared.report(track.uid) {
        c.firstSound = r.timeToFirstSound.map { String(format: "%.2fs", $0 / 1000) } ?? "-"
        c.stages = r.cumulative + (r.tags.isEmpty ? "" : " [" + r.tags.joined(separator: ",") + "]")
    }
    c.route = rep.route
    c.ttr = String(format: "%.1fs", rep.ttr)
    c.advance = rep.advanced > 0 ? String(format: "%.2fx", rep.advanced) : "-"
    c.seek = rep.seek
    if let e = rep.error { c.failStep = rep.failStep; c.error = e; c.result = "FAIL"; resolver.reportFailure(track, stream: stream, reason: e) }
    else {
        c.result = "PASS"
        // Pressing play on the same song again: the resolver's remembered stream is used, nothing is searched.
        if env["MATRIX_REPLAY"] != "0" {
            MusicStartTimeline.shared.begin(track.uid)
            if let again = try? await resolver.resolve(track, quality: .high) {
                let r2 = await play(again, key: track.uid, quick: true)
                if r2.error == nil, let rr = MusicStartTimeline.shared.report(track.uid), let t = rr.timeToFirstSound { c.replay = String(format: "%.2fs", t / 1000) }
            }
        }
    }
}

// MARK: local fixture

func makeSilentFile(_ dir: URL, title: String, artist: String) -> URL? {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("\(artist) - \(title).m4a")
    try? FileManager.default.removeItem(at: file)
    guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) else { return nil }
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000]
    guard let out = try? AVAudioFile(forWriting: file, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false),
          let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44100) else { return nil }
    buf.frameLength = 44100
    for _ in 0..<45 { do { try out.write(from: buf) } catch { return nil } }
    return file
}

// MARK: negative tests

struct DeadProvider: MusicAudioProvider {
    enum Mode: Sendable { case fail, hang, noMatch, deadStream }
    let pid: String, mode: Mode
    var info: MusicProviderInfo { MusicProviderInfo(id: pid, name: "Dead \(pid)", summary: "test", privacyNote: "") }
    var capabilities: MusicCapabilities { [.audio] }
    func sources(for track: MusicTrack) async throws -> [MusicAudioSource] {
        switch mode {
        case .fail: throw MusicError.network("connection refused (simulated)")
        case .hang: try await Task.sleep(nanoseconds: 120_000_000_000); return []
        case .noMatch: return []
        case .deadStream:
            return [MusicAudioSource(id: "dead", providerID: pid, title: track.title, artist: track.artists.first?.name, durationMs: track.durationMs, externalURL: nil, confidence: 1,
                                     streams: [MusicStream(url: "https://matrix-dead-host.invalid/a.mp3", codec: "mp3", container: "mp3", bitrate: 128)])]
        }
    }
    func streams(for source: MusicAudioSource) async throws -> [MusicStream] { source.streams ?? [] }
}

@MainActor func negativeTests() async {
    let track = MusicTrack(id: "neg", providerID: "itunes", title: "Bohemian Rhapsody", durationMs: 355_000, artists: [MusicArtistRef(id: "q", name: "Queen")])
    func run(_ name: String, _ build: (MusicRegistry) -> Void, expectOK: Bool, maxSeconds: Double, play doPlay: Bool = false, expectLog: Bool) async {
        var c = Cell(provider: "NEG: " + name, query: "Bohemian Rhapsody")
        defer { cells.append(c); say("[\(c.result)] \(c.provider): \(c.failStep) \(c.error)") }
        let reg = MusicRegistry(defaults: UserDefaults(suiteName: "matrix.\(UUID().uuidString)")!)
        build(reg)
        let (resolver, log) = makeResolver(reg)
        let t0 = Date()
        var ok = false; var err = ""; var stream: MusicStream?
        do { stream = try await resolver.resolve(track, quality: .high); ok = true } catch { err = errText(error) }
        let dt = Date().timeIntervalSince(t0)
        let logText = log.entries.map { "\($0.provider): \($0.reason)" }.joined(separator: "; ")
        c.resolve = (ok ? "ok" : "failed (\(err))") + String(format: " in %.1fs", dt)
        c.search = "n/a"; c.track = track.title
        c.error = "log=[\(logText)]"
        var good = (ok == expectOK) && dt <= maxSeconds && (!expectLog || !log.entries.isEmpty)
        if !good { c.failStep = "negative-expectation"; c.error += " expectedOK=\(expectOK) elapsed=\(String(format: "%.1f", dt)) (max \(maxSeconds))" }
        if good, doPlay, ok, let stream, !stream.url.contains("matrix-dead-host") {
            // The resolver's stream check already refused the dead address and chose a live one: still has to play.
            let r0 = await play(stream)
            c.route = r0.route; c.ttr = String(format: "%.1fs", r0.ttr); c.advance = String(format: "%.2fx", r0.advanced)
            c.error += " | dead address filtered before play (resolver verified streams); chosen \(describe(stream))"
            if let e = r0.error { good = false; c.failStep = "play-after-filter"; c.error += " " + e }
        } else if good, doPlay, ok, let stream {
            let rep = await play(stream)
            if rep.error != nil {
                resolver.reportFailure(track, stream: stream, reason: rep.error ?? "")
                c.error += " | first stream failed as expected (\(rep.failStep): \(rep.error ?? "")); "
                do {
                    let s2 = try await resolver.resolve(track, quality: .high)
                    c.resolve += " -> retry ok \(describe(s2))"
                    let r2 = await play(s2)
                    c.route = r2.route; c.ttr = String(format: "%.1fs", r2.ttr); c.advance = String(format: "%.2fx", r2.advanced)
                    if let e = r2.error { good = false; c.failStep = "retry-play"; c.error += e }
                } catch { good = false; c.failStep = "retry-resolve"; c.error += errText(error) }
            } else { good = false; c.failStep = "dead-stream-played"; c.error += " dead stream unexpectedly played" }
        }
        c.result = good ? "PASS" : "FAIL"
    }
    func withDead(_ mode: DeadProvider.Mode) -> (MusicRegistry) -> Void {
        { reg in
            reg.register(DeadProvider(pid: "dead", mode: mode)); reg.setEnabled(true, id: "dead", reason: .setup)
            reg.register(YouTubeMusicProvider()); reg.setEnabled(true, id: "youtube-music", reason: .setup)
            reg.register(PipedProvider()); reg.setEnabled(true, id: "piped", reason: .setup)
        }
    }
    await run("provider fails fast, next provider serves", withDead(.fail), expectOK: true, maxSeconds: 30, expectLog: false)
    await run("provider hangs, deadline then next provider serves", withDead(.hang), expectOK: true, maxSeconds: 40, expectLog: false)
    await run("first stream URL dead, retry picks another", withDead(.deadStream), expectOK: true, maxSeconds: 60, play: true, expectLog: false)
    await run("every provider dead -> error + log, no hang", { reg in
        reg.register(DeadProvider(pid: "d1", mode: .fail)); reg.setEnabled(true, id: "d1", reason: .setup)
        reg.register(DeadProvider(pid: "d2", mode: .hang)); reg.setEnabled(true, id: "d2", reason: .setup)
        reg.register(DeadProvider(pid: "d3", mode: .noMatch)); reg.setEnabled(true, id: "d3", reason: .setup)
    }, expectOK: false, maxSeconds: 20, expectLog: true)
}

// MARK: main

@main struct Matrix {
    @MainActor static func main() async {
        if let s = env["MATRIX_SPOTIFY"] { for p in s.split(separator: ",") { let kv = p.split(separator: "="); if kv.count == 2 { spotifyIDs[String(kv[0])] = String(kv[1]) } } }
        let queries = allQueries.filter { onlyQueries.isEmpty || onlyQueries.contains($0.label.lowercased()) || onlyQueries.contains($0.text.lowercased()) }
        func want(_ p: String) -> Bool { onlyProviders.isEmpty || onlyProviders.contains(p) }
        let allIDs: (String) -> Bool = { $0 != "local" }
        let itunes = ITunesProvider()
        sharedProxy.prepare()
        say("matrix: queries=\(queries.map(\.label)) play=\(playSeconds)s muted volume=0")

        func firstTrack(_ p: any MusicMetadataProvider, _ q: Query) async throws -> MusicTrack? {
            pick(try await p.searchTracks(q.text, page: nil).items, q)
        }
        /// The provider's own search when it has one, otherwise the Apple/iTunes search (audio-only providers have none).
        func via(_ provider: String, _ q: Query) async throws -> MusicTrack? {
            let reg = makeRegistry(enable: { _ in true })
            if let m = reg.metadataProvider(id: provider), m.capabilities.contains(.search) { return try await firstTrack(m, q) }
            return try await firstTrack(itunes, q)
        }

        for (id, name) in [("audius", "Audius (direct)"), ("jiosaavn", "JioSaavn track (metadata + direct)")] where want(id) {
            for q in queries { await runCell(provider: name, query: q, search: { try await via(id, q) }, enableForResolve: allIDs) }
        }
        if want("itunes") {
            for q in queries { await runCell(provider: "Apple/iTunes track (matched)", query: q, search: { try await firstTrack(itunes, q) }, enableForResolve: allIDs) }
        }
        for (id, name) in [("ytmusic", "YouTube Music full (ytmusic)"), ("youtube-music", "YouTube Music basic (youtube-music)"), ("piped", "Piped"), ("invidious", "Invidious")] where want(id) {
            for q in queries { await runCell(provider: name, query: q, search: { try await via(id, q) }, enableForResolve: { $0 == id }) }
        }
        if want("spotify") {
            for q in queries {
                await runCell(provider: "Spotify link (signed out, embed)", query: q, search: {
                    guard let tid = spotifyIDs[q.label] else { throw MusicError.unsupported("no Spotify track link configured for \(q.label) (set MATRIX_SPOTIFY)") }
                    guard let link = SpotifyLink.parse("https://open.spotify.com/track/\(tid)?si=matrix") else { throw MusicError.notFound }
                    return try await SpotifyEmbedClient().entity(link).singleTrack
                }, enableForResolve: allIDs)
            }
        }
        if want("local") {
            let dir = URL(fileURLWithPath: localFolder)
            for q in queries { _ = makeSilentFile(dir, title: q.text, artist: "Matrix Test") }
            let store = LocalLibraryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("matrix-local-store-\(UUID().uuidString)"))
            _ = await store.addFolder(dir)
            await store.scan()
            let lp = LocalFilesProvider(store: store)
            for q in queries {
                await runCell(provider: "Local files (silent m4a)", query: q, search: { try await lp.searchTracks(q.text, page: nil).items.first }, enableForResolve: { $0 == "local" }, localStore: store)
            }
            try? FileManager.default.removeItem(at: dir)
        }
        if want("addon") {
            for q in queries { cells.append(Cell(provider: "Addon / plugin sample", query: q.label, search: "n/a", result: "SKIP", failStep: "none installed", error: "no addon server is configured and the plugin sample is documentation only (SAMPLE-PLUGIN.md)")) }
        }
        if want("deezer") {
            for q in queries { cells.append(Cell(provider: "Deezer / discovery", query: q.label, search: "n/a", result: "SKIP", failStep: "not present", error: "no Deezer provider exists in the app")) }
        }
        if want("negative") { await negativeTests() }
        sharedProxy.stop()
        report()
    }
}

func report() {
    var md = "| Provider | Query | Search | Track | Resolve | Route | Ready | First sound | Replay | Stages (ms since press) | Real-time | Seek 30 s | Result | Failing step / error |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
    func e(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ") }
    for c in cells {
        md += "| \(e(c.provider)) | \(c.query) | \(e(c.search)) | \(e(c.track)) | \(e(c.resolve)) | \(c.route) | \(c.ttr) | \(c.firstSound) | \(c.replay) | \(e(c.stages)) | \(c.advance) | \(e(c.seek)) | \(c.result) | \(c.failStep.isEmpty ? "" : "**" + c.failStep + "**: ")\(e(c.error)) |\n"
    }
    let pass = cells.filter { $0.result == "PASS" }.count, fail = cells.filter { $0.result == "FAIL" }.count, skip = cells.filter { $0.result == "SKIP" }.count
    md += "\nPASS \(pass), FAIL \(fail), SKIP \(skip) of \(cells.count)\n"
    print(md)
    if let outPath { try? md.write(toFile: outPath, atomically: true, encoding: .utf8) }
}
