import Foundation
import Testing
@testable import REDDY

private final class Hits: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    var count: Int { lock.withLock { n } }
    func hit(_ s: String = "") { lock.withLock { n += 1 } }
}
private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock(); private var d: Date
    init(_ d: Date) { self.d = d }
    var value: Date { get { lock.withLock { d } } set { lock.withLock { d = newValue } } }
}

/// A YouTube-shaped provider: a track that names a video id gets that exact video back; a search request gets the audio twin.
private struct YTShape: MusicAudioProvider {
    var info = MusicProviderInfo(id: YTM.providerID, name: "YouTube Music", summary: "")
    var capabilities: MusicCapabilities { .audio }
    var brokenIDs: Set<String> = []
    var exactTitle: String? = nil

    func sources(for track: MusicTrack) async throws -> [MusicAudioSource] {
        if let vid = track.videoID ?? (track.providerID == YTM.providerID ? track.id : nil) {
            return [MusicAudioSource(id: vid, providerID: YTM.providerID, title: exactTitle ?? track.title, artist: "Somebody Else", album: nil,
                                     durationMs: 999_000, externalURL: nil, confidence: 1)]
        }
        return [MusicAudioSource(id: "TWIN0000001", providerID: YTM.providerID, title: track.title, artist: track.artistLine, album: nil,
                                 durationMs: track.durationMs, externalURL: nil, confidence: 0.9)]
    }
    func streams(for source: MusicAudioSource) async throws -> [MusicStream] {
        if brokenIDs.contains(source.id) { throw MusicError.noPlayableSource(source.title) }
        return [MusicStream(url: "https://yt.example/" + source.id, codec: "aac", container: "m4a", bitrate: 128)]
    }
}

@MainActor
private func reg(_ p: YTShape) throws -> MusicRegistry {
    let suite = "music.test." + UUID().uuidString
    let d = try #require(UserDefaults(suiteName: suite))
    d.removePersistentDomain(forName: suite)
    let r = MusicRegistry(defaults: d)
    r.register(p); r.setEnabled(true, id: p.info.id)
    return r
}

private func chartRow(_ vid: String = "A_RV2H2F9jw", title: String = "Basinga Balaalu") -> MusicTrack {
    var t = MusicTrack(id: vid, providerID: YTM.providerID, title: title, durationMs: 262_000,
                       artists: [MusicArtistRef(id: "a", name: "Srinidhi Nerella"), MusicArtistRef(id: "b", name: "Kalyan Keys")])
    t.videoID = vid; t.isVideo = true
    return t
}

@Suite("Unplayable chart rows")
@MainActor
struct UnplayableChartTests {
    // MARK: classification

    @Test func playabilityTableSeparatesPermanentFromRetryable() {
        let rows: [(String, String, YouTubePlayability)] = [
            ("LOGIN_REQUIRED", "Sign in to confirm you’re not a bot", .botCheck),
            ("LOGIN_REQUIRED", "Sign in to confirm you're not a bot", .botCheck),
            ("UNPLAYABLE", "The page needs to be reloaded", .tokenRequired),
            ("LOGIN_REQUIRED", "This video is private", .unavailable(.privateVideo)),
            ("UNPLAYABLE", "This video is not available in your country", .unavailable(.regionLocked)),
            ("LOGIN_REQUIRED", "Sign in to confirm your age", .ageRestricted),
            ("AGE_VERIFICATION_REQUIRED", "", .ageRestricted),
            ("ERROR", "This video has been removed by the uploader", .unavailable(.removed)),
            ("LOGIN_REQUIRED", "Please sign in", .signInRequired),
        ]
        for (status, reason, expected) in rows { #expect(YouTubePlayability.from(status: status, reason: reason) == expected, "\(status) \(reason)") }
        #expect(YouTubePlayability.botCheck.verdict == nil)
        #expect(YouTubePlayability.tokenRequired.isRetryable)
        #expect(YouTubePlayability.ageRestricted.verdict == .ageRestricted)
    }

    @Test func aBotCheckIsNeverAPermanentVerdict() {
        #expect(MusicUnplayableMemory.classify(status: "LOGIN_REQUIRED", reason: "Sign in to confirm you’re not a bot") == nil)
        #expect(MusicUnplayableMemory.classify(status: "UNPLAYABLE", reason: "This video is not made for kids") == nil)
    }

    // MARK: direct id skips the acceptance rules

    @Test func anExactVideoIdIsNotVettedLikeASearchResult() async throws {
        // The catalogue says 4:22, the video is 16:39 and credits another channel: a search candidate would be refused on both counts.
        let t = chartRow()
        let candidate = MusicAudioSource(id: t.id, providerID: YTM.providerID, title: "Basinga Balaalu (Remix)", artist: "Somebody Else", durationMs: 999_000, confidence: 1)
        #expect(!MusicCandidateRules.evaluate(track: t, candidate: candidate).isAccepted)
        let p = YTShape(exactTitle: "Basinga Balaalu (Remix)")
        #expect(MusicStreamResolver.isExact(track: t, provider: p, sources: [candidate]))
        let r = MusicStreamResolver(registry: try reg(p)); r.verifier = nil
        let s = try await r.resolve(t, quality: .high)
        #expect(s.url == "https://yt.example/" + t.id)
    }

    @Test func aSearchResultOfAnotherProviderStillGoesThroughTheRules() {
        var t = chartRow(); t.providerID = "spotify"; t.videoID = nil
        let c = MusicAudioSource(id: "x", providerID: YTM.providerID, title: "Basinga Balaalu", artist: "Z", durationMs: 262_000, confidence: 1)
        #expect(!MusicStreamResolver.isExact(track: t, provider: YTShape(), sources: [c]))
    }

    // MARK: audio twin fallback

    @Test func whenTheExactVideoCannotPlayItsAudioTwinIsSearchedBeforeGivingUp() async throws {
        let t = chartRow("BROKEN00001")
        let p = YTShape(brokenIDs: ["BROKEN00001"])
        let r = MusicStreamResolver(registry: try reg(p)); r.verifier = nil
        let log = MusicPlaybackLog(); r.log = log
        let s = try await r.resolve(t, quality: .high)
        #expect(s.url == "https://yt.example/TWIN0000001")
        #expect(log.entries.contains { $0.reason == "Not available as audio. Trying another source." })
    }

    @Test func theExactVideoIsTriedFirstAndTheTwinOnlyAfterIt() async throws {
        let t = chartRow("GOODVIDEO01")
        let r = MusicStreamResolver(registry: try reg(YTShape())); r.verifier = nil
        #expect(try await r.resolve(t, quality: .high).url == "https://yt.example/GOODVIDEO01")
    }

    @Test func theSearchRequestDropsTheVideoIdAndIsOnlyForYouTubeRows() {
        let s = MusicStreamResolver.searchRequest(for: chartRow())
        #expect(s?.videoID == nil)
        #expect(s?.providerID != YTM.providerID)
        #expect(s?.title == "Basinga Balaalu")
        var other = chartRow(); other.providerID = "audius"
        #expect(MusicStreamResolver.searchRequest(for: other) == nil)
    }

    @Test func aFailedStreamIsNotServedAgainAndTheRetryFindsTheTwin() async throws {
        let t = chartRow("GOODVIDEO02")
        let r = MusicStreamResolver(registry: try reg(YTShape())); r.verifier = nil
        let first = try await r.resolve(t, quality: .high)
        r.reportFailure(t, stream: first, reason: "playback failed")
        r.invalidate(t)
        let second = try await r.resolve(t, quality: .high)   // before the fix: noPlayableSource("Basinga Balaalu")
        #expect(second.url != first.url)
        #expect(MusicUnplayableMemory.shared.isBadURL(first.url))
    }

    // MARK: transient refusals are not remembered

    @Test func aClientExclusionIsShortAndABadAddressIsRemembered() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let box = ClockBox(now)
        let m = MusicUnplayableMemory(now: { box.value })
        m.exclude(client: "VISIONOS", videoID: "v1")
        #expect(m.isExcluded(client: "VISIONOS", videoID: "v1"))
        now = now.addingTimeInterval(MusicUnplayableMemory.clientExclusion + 1); box.value = now
        #expect(!m.isExcluded(client: "VISIONOS", videoID: "v1"))
        #expect(MusicUnplayableMemory.clientExclusion < MusicUnplayableMemory.memory)
        m.markBadURL("https://x/y")
        #expect(m.isBadURL("https://x/y"))
        m.remember(.removed, videoID: "v1"); m.exclude(client: "IOS", videoID: "v1")
        m.forgive(videoID: "v1")
        #expect(m.verdict(videoID: "v1") == nil && !m.isExcluded(client: "IOS", videoID: "v1"))
    }

    // MARK: soft probe failures

    @Test func aSingleMiddleReadHiccupIsReadAgainOnce() async {
        let stream = MusicStream(url: "https://soft-\(UUID().uuidString).example/a", codec: "aac", container: "m4a", bitrate: 128)
        let calls = Hits()
        let v = await MusicStreamVerifier.verifyDeep(stream, total: 3_000_000, reader: { _, _, range, limit in
            if range.hasPrefix("bytes=1500000-") && calls.count == 0 { calls.hit(); return nil }
            return MusicProbeReading(status: 206, contentType: "audio/mp4", total: 3_000_000, bytesRead: limit)
        })
        #expect(v == .ok)
    }

    @Test func aRefusedMiddleReadIsNeverSoft() async {
        let stream = MusicStream(url: "https://hard.example/a", codec: "aac", container: "m4a", bitrate: 128)
        let v = await MusicStreamVerifier.verifyDeep(stream, total: 3_000_000, reader: { _, _, _, _ in
            MusicProbeReading(status: 403, contentType: "text/html", total: 3_000_000, bytesRead: 0)
        })
        if case .refused = v {} else { Issue.record("expected refused, got \(v)") }
    }

    @Test func aTrackWithAVideoIdKeepsPlayingWhenLaterReadsOnlyTimeOut() async {
        let proof = MusicStreamProof()
        let stream = MusicStream(url: "https://late-\(UUID().uuidString).example/a", codec: "aac", container: "m4a", bitrate: 128)
        let rejected = Hits()
        proof.setLateRejectionHandler { url, _ in rejected.hit(url) }
        proof.checkLater(stream, total: 3_000_000, pair: "p|h", reader: { _, _, _, _ in nil }, soft: true, run: { work in Task { await work() } })
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(rejected.count == 0)
    }

    // MARK: plain reasons

    @Test func theReasonIsPlainEnglishNotNoPlayableSource() {
        func why(_ detail: String) -> String { MusicPlaybackMessages.reason(error: MusicError.noPlayableSource(detail), message: "", title: "Song") }
        #expect(why("Song. " + MusicUnplayableMemory.Verdict.regionLocked.text) == "This song is not available in your country.")
        #expect(why("Song. " + MusicUnplayableMemory.Verdict.ageRestricted.text) == "This video is age-restricted.")
        #expect(why("Song") == "This song could not be played from any source right now.")
        #expect(MusicPlaybackMessages.skippedWithReason(title: "Song", reason: "This video is private.") == "Couldn't play Song: This video is private. Skipping to the next song.")
    }
}
