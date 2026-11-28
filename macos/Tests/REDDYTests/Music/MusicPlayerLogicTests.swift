import Testing
import Foundation
@testable import REDDY

private func track(_ n: Int, title: String? = nil, artist: String = "Artist", durationMs: Int64 = 200_000) -> MusicTrack {
    MusicTrack(id: "t\(n)", providerID: "p", title: title ?? "Song \(n)", durationMs: durationMs, artists: [MusicArtistRef(id: "a", name: artist)])
}

private func tracks(_ n: Int) -> [MusicTrack] { (0..<n).map { track($0) } }

// MARK: resolver

private actor Calls {
    var sources = 0, streams = 0
    func source() { sources += 1 }
    func stream() { streams += 1 }
}

private struct FakeAudio: MusicAudioProvider {
    var info: MusicProviderInfo
    var capabilities: MusicCapabilities { .audio }
    var candidates: [MusicAudioSource]
    var fail = false
    var calls = Calls()
    var streamsByID: [String: [MusicStream]] = [:]

    func sources(for track: MusicTrack) async throws -> [MusicAudioSource] {
        await calls.source()
        if fail { throw MusicError.network("down") }
        return candidates
    }
    func streams(for source: MusicAudioSource) async throws -> [MusicStream] {
        await calls.stream()
        return streamsByID[source.id] ?? []
    }
}

private func audio(_ id: String) -> MusicProviderInfo { MusicProviderInfo(id: id, name: id, summary: "") }
private func stream(_ url: String, kbps: Int?, lossless: Bool = false, proto: MusicStreamProtocol = .progressive) -> MusicStream {
    MusicStream(url: url, codec: "aac", container: "m4a", proto: proto, bitrate: kbps, sampleRate: lossless ? 44_100 : nil)
}
private func candidate(_ id: String, _ title: String, artist: String = "Artist", ms: Int64 = 200_000, confidence: Float = 0.8) -> MusicAudioSource {
    MusicAudioSource(id: id, providerID: "x", title: title, artist: artist, album: nil, durationMs: ms, externalURL: nil, confidence: confidence)
}

@MainActor
private func makeRegistry(_ providers: [FakeAudio]) throws -> MusicRegistry {
    let suite = "music.test." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    let r = MusicRegistry(defaults: defaults)
    for p in providers { r.register(p); r.setEnabled(true, id: p.info.id) }
    return r
}

@Suite("MusicStreamResolver")
@MainActor
struct MusicResolverTests {
    @Test func pickRespectsQualityCeilings() {
        let s = [stream("https://a/48", kbps: 48), stream("https://a/96", kbps: 96), stream("https://a/128", kbps: 128), stream("https://a/320", kbps: 320),
                 stream("https://a/flac", kbps: nil, lossless: true)]
        #expect(MusicStreamResolver.pick(from: s, quality: .low)?.url == "https://a/96")
        #expect(MusicStreamResolver.pick(from: s, quality: .medium)?.url == "https://a/128")
        #expect(MusicStreamResolver.pick(from: s, quality: .high)?.url == "https://a/320")
        #expect(MusicStreamResolver.pick(from: s, quality: .lossless)?.url == "https://a/flac")
    }

    @Test func pickFallsBackToLightestAndSkipsDash() {
        let s = [stream("https://a/256", kbps: 256), stream("https://a/dash", kbps: 64, proto: .dash)]
        #expect(MusicStreamResolver.pick(from: s, quality: .low)?.url == "https://a/256")
        #expect(MusicStreamResolver.pick(from: [stream("https://a/dash", kbps: 64, proto: .dash)], quality: .high) == nil)
    }

    @Test func pickIgnoresExpiredStreams() {
        var old = stream("https://a/old", kbps: 128)
        old.expiresAt = Date(timeIntervalSinceNow: -10)
        #expect(MusicStreamResolver.pick(from: [old], quality: .high) == nil)
    }

    @Test func exactMatchOutscoresWrongSong() {
        let t = track(1, title: "Blinding Lights", artist: "The Weeknd")
        let good = MusicStreamResolver.score(track: t, candidate: candidate("g", "Blinding Lights", artist: "The Weeknd"))
        let bad = MusicStreamResolver.score(track: t, candidate: candidate("b", "Completely Different Tune", artist: "Someone Else", ms: 90_000, confidence: 0.2))
        #expect(good > bad)
        #expect(good >= MusicStreamResolver.minimumScore)
        #expect(bad < MusicStreamResolver.minimumScore)
    }

    @Test func directStreamsSkipProviders() async throws {
        let p = FakeAudio(info: audio("a"), candidates: [])
        let resolver = MusicStreamResolver(registry: try makeRegistry([p]))
        var t = track(1)
        t.directStreams = [stream("https://direct/128", kbps: 128)]
        let s = try await resolver.resolve(t, quality: .high)
        #expect(s.url == "https://direct/128")
        #expect(await p.calls.sources == 0)
    }

    @Test func bestCandidateWinsAndResultIsCached() async throws {
        let t = track(1, title: "Blinding Lights", artist: "The Weeknd")
        var p = FakeAudio(info: audio("a"), candidates: [
            candidate("wrong", "Other Song Entirely", artist: "Nobody", ms: 60_000, confidence: 0.4),
            candidate("right", "Blinding Lights", artist: "The Weeknd"),
        ])
        p.streamsByID = ["right": [stream("https://right/128", kbps: 128)], "wrong": [stream("https://wrong/128", kbps: 128)]]
        let resolver = MusicStreamResolver(registry: try makeRegistry([p]))
        let first = try await resolver.resolve(t, quality: .high)
        let second = try await resolver.resolve(t, quality: .high)
        #expect(first.url == "https://right/128" && second.url == first.url)
        #expect(await p.calls.sources == 1)
        resolver.invalidate(t)
        _ = try await resolver.resolve(t, quality: .high)
        #expect(await p.calls.sources == 2)
    }

    @Test func fallsBackToNextProviderOnFailure() async throws {
        let t = track(1, title: "Blinding Lights", artist: "The Weeknd")
        let broken = FakeAudio(info: audio("a"), candidates: [], fail: true)
        var good = FakeAudio(info: audio("b"), candidates: [candidate("ok", "Blinding Lights", artist: "The Weeknd")])
        good.streamsByID = ["ok": [stream("https://ok/160", kbps: 160)]]
        let resolver = MusicStreamResolver(registry: try makeRegistry([broken, good]))
        let s = try await resolver.resolve(t, quality: .medium)
        #expect(s.url == "https://ok/160")
        #expect(await broken.calls.sources == 1)
    }

    @Test func tooWeakMatchesAreRejected() async throws {
        let t = track(1, title: "Blinding Lights", artist: "The Weeknd")
        var p = FakeAudio(info: audio("a"), candidates: [candidate("x", "Zzz Unrelated", artist: "Nobody", ms: 30_000, confidence: 0.1)])
        p.streamsByID = ["x": [stream("https://x/128", kbps: 128)]]
        let resolver = MusicStreamResolver(registry: try makeRegistry([p]))
        await #expect(throws: MusicError.noPlayableSource(t.title)) { try await resolver.resolve(t, quality: .high) }
        #expect(await p.calls.streams == 0)
    }

    @Test func noProvidersIsAClearError() async throws {
        let resolver = MusicStreamResolver(registry: try makeRegistry([]))
        let t = track(1)
        await #expect(throws: MusicError.noPlayableSource(t.title)) { try await resolver.resolve(t, quality: .high) }
    }
}

// MARK: scrobble rule, lyrics, downloads, segments

@Suite("Music playback helpers")
struct MusicPlaybackHelperTests {
    @Test func scrobbleThresholds() {
        #expect(MusicScrobbler.shouldScrobble(playedMs: 100_000, durationMs: 200_000))      // half
        #expect(!MusicScrobbler.shouldScrobble(playedMs: 99_000, durationMs: 200_000))
        #expect(MusicScrobbler.shouldScrobble(playedMs: 240_000, durationMs: 900_000))      // four minute cap
        #expect(!MusicScrobbler.shouldScrobble(playedMs: 239_000, durationMs: 900_000))
        #expect(!MusicScrobbler.shouldScrobble(playedMs: 29_000, durationMs: 40_000))       // never under 30 s
        #expect(MusicScrobbler.shouldScrobble(playedMs: 30_000, durationMs: 50_000))
        #expect(!MusicScrobbler.shouldScrobble(playedMs: 20_000, durationMs: 25_000))
    }

    @Test func lyricLineLookup() {
        let lines = [MusicLyricLine(timeMs: 1_000, text: "a"), MusicLyricLine(timeMs: 5_000, text: "b"), MusicLyricLine(timeMs: 9_000, text: "c")]
        #expect(MusicLyricsService.lineIndex(in: lines, at: 0) == nil)
        #expect(MusicLyricsService.lineIndex(in: lines, at: 1_000) == 0)
        #expect(MusicLyricsService.lineIndex(in: lines, at: 4_999) == 0)
        #expect(MusicLyricsService.lineIndex(in: lines, at: 5_000) == 1)
        #expect(MusicLyricsService.lineIndex(in: lines, at: 99_000) == 2)
        #expect(MusicLyricsService.lineIndex(in: [], at: 5) == nil)
    }

    @Test func downloadFileNames() {
        #expect(MusicDownloads.fileName(for: track(1, title: "Song", artist: "Artist"), ext: "m4a") == "Artist - Song.m4a")
        #expect(MusicDownloads.fileName(for: track(1, title: "AC/DC: Back In Black?", artist: "AC/DC"), ext: "MP3") == "AC DC - AC DC Back In Black.mp3")
        #expect(MusicDownloads.fileName(for: track(1, title: "...", artist: ""), ext: "") == "Track.m4a")
        let long = String(repeating: "x", count: 300)
        #expect(MusicDownloads.fileName(for: track(1, title: long), ext: "m4a").count <= 200)
        #expect(!MusicDownloads.sanitize("a\nb\tc|d").contains("|"))
    }

    @Test func downloadExtensionFromStream() {
        #expect(MusicDownloads.fileExtension(for: MusicStream(url: "https://a/x", codec: "opus", container: "webm")) == "webm")
        #expect(MusicDownloads.fileExtension(for: MusicStream(url: "https://a/x.mp3", codec: "?", container: "?")) == "mp3")
        #expect(MusicDownloads.fileExtension(for: MusicStream(url: "https://a/x", codec: "aac", container: "?")) == "m4a")
    }

    @Test func segmentSkipperHelpers() {
        #expect(MusicSegmentSkipper.videoID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=3") == "dQw4w9WgXcQ")
        #expect(MusicSegmentSkipper.videoID(from: "https://youtu.be/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(MusicSegmentSkipper.videoID(from: "https://music.youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(MusicSegmentSkipper.videoID(from: "https://example.com/watch?v=dQw4w9WgXcQ") == nil)
        #expect(MusicSegmentSkipper.videoID(from: nil) == nil)
        let prefix = MusicSegmentSkipper.hashPrefix("dQw4w9WgXcQ")
        #expect(prefix.count == 4 && prefix.allSatisfy { $0.isHexDigit })
        let json = #"[{"videoID":"other","segments":[{"segment":[1,2],"category":"intro"}]},{"videoID":"abc","segments":[{"segment":[10,20.5],"category":"sponsor","actionType":"skip"},{"segment":[0,3],"category":"intro","actionType":"mute"},{"segment":[5,5],"category":"intro"}]}]"#
        let parsed = MusicSegmentSkipper.parse(Data(json.utf8), videoID: "abc")
        #expect(parsed == [MusicSkipSegment(start: 10, end: 20.5, category: "sponsor")])
    }
}
