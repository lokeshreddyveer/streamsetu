import Testing
import Foundation
@testable import REDDY

private func wanted(_ title: String, artist: String = "The Weeknd", ms: Int64 = 200_000, album: String? = nil, explicit: Bool = false,
                    video: Bool? = nil, provider: String = "spotify") -> MusicTrack {
    MusicTrack(id: "w", providerID: provider, title: title, durationMs: ms, artists: artist.isEmpty ? [] : [MusicArtistRef(id: "a", name: artist)],
               album: album.map { MusicAlbumRef(id: "al", title: $0) }, explicit: explicit, isVideo: video)
}

private func cand(_ title: String, artist: String? = "The Weeknd", ms: Int64? = 200_000, album: String? = nil) -> MusicAudioSource {
    MusicAudioSource(id: UUID().uuidString, providerID: "yt", title: title, artist: artist, album: album, durationMs: ms, externalURL: nil, confidence: 0.8)
}

private func verdict(_ w: MusicTrack, _ c: MusicAudioSource) -> MusicCandidateRules.Verdict { MusicCandidateRules.evaluate(track: w, candidate: c) }

@Suite("Candidate acceptance rules")
struct CandidateRuleTests {
    @Test func versionVetoWorksBothWays() {
        #expect(verdict(wanted("Blinding Lights"), cand("Blinding Lights (Live)")) == .rejected(.version))
        #expect(verdict(wanted("Blinding Lights (Live)"), cand("Blinding Lights")) == .rejected(.version))
        #expect(verdict(wanted("Blinding Lights"), cand("Blinding Lights - Remix")) == .rejected(.version))
        #expect(verdict(wanted("Blinding Lights (Remix)"), cand("Blinding Lights")) == .rejected(.version))
        #expect(verdict(wanted("Blinding Lights"), cand("Blinding Lights (Instrumental)")) == .rejected(.version))
        #expect(verdict(wanted("Blinding Lights"), cand("Blinding Lights (Sped Up)")) == .rejected(.version))
        #expect(verdict(wanted("Blinding Lights"), cand("Blinding Lights (slowed + reverb)")) == .rejected(.version))
        #expect(verdict(wanted("Blinding Lights"), cand("Blinding Lights (8D Audio)")) == .rejected(.version))
        #expect(verdict(wanted("Blinding Lights"), cand("Blinding Lights (Acoustic)")) == .rejected(.version))
        #expect(verdict(wanted("Blinding Lights"), cand("Blinding Lights (Lofi)")) == .rejected(.version))
        #expect(verdict(wanted("Blinding Lights"), cand("Blinding Lights Karaoke")) == .rejected(.version))
        #expect(verdict(wanted("Blinding Lights"), cand("Blinding Lights (Cover)")) == .rejected(.version))
        #expect(verdict(wanted("Blinding Lights"), cand("Blinding Lights カラオケ")) == .rejected(.version))
    }

    @Test func sameVersionAndNeutralWordsAreAccepted() {
        #expect(verdict(wanted("Blinding Lights (Live)"), cand("Blinding Lights - Live")).isAccepted)
        #expect(verdict(wanted("Blinding Lights"), cand("Blinding Lights (Album Version)")).isAccepted)
        #expect(verdict(wanted("Blinding Lights"), cand("Blinding Lights (Official Audio)")).isAccepted)
        #expect(verdict(wanted("Blinding Lights"), cand("Blinding Lights - Remastered 2020")).isAccepted)
        #expect(verdict(wanted("Blinding Lights"), cand("Blinding Lights (Radio Edit)")).isAccepted)
        #expect(verdict(wanted("Live Forever"), cand("Live Forever")).isAccepted)
    }

    @Test func albumNameCarriesAVersion() {
        #expect(verdict(wanted("Song"), cand("Song", album: "Greatest Hits (Instrumental)")) == .rejected(.version))
        #expect(verdict(wanted("Song", album: "Hits (Instrumental)"), cand("Song", album: "Hits (Instrumental)")).isAccepted)
    }

    @Test func languageTaggedVariantsAreDifferentRecordings() {
        #expect(verdict(wanted("Kaavaalaa (Tamil)", artist: "Anirudh"), cand("Kaavaalaa (Hindi Version)", artist: "Anirudh")) == .rejected(.version))
        #expect(verdict(wanted("Kaavaalaa (Tamil)", artist: "Anirudh"), cand("Kaavaalaa [Tamil]", artist: "Anirudh")).isAccepted)
    }

    @Test func artistMustBeShared() {
        #expect(verdict(wanted("Blinding Lights"), cand("Blinding Lights", artist: "Some Cover Band", ms: 215_000)) == .rejected(.artist))
        #expect(verdict(wanted("Blinding Lights"), cand("Blinding Lights", artist: "The Weeknd - Topic")).isAccepted)
        #expect(verdict(wanted("Blinding Lights"), cand("Blinding Lights", artist: "TheWeekndVEVO")) == .rejected(.artist) || verdict(wanted("Blinding Lights"), cand("Blinding Lights", artist: "TheWeekndVEVO")).isAccepted)
        #expect(verdict(wanted("Blinding Lights", artist: "Daft Punk, The Weeknd"), cand("Blinding Lights", artist: "The Weeknd")).isAccepted)
        // Artist named in the title of a label upload.
        #expect(verdict(wanted("Blinding Lights"), cand("The Weeknd - Blinding Lights", artist: "XO Records")).isAccepted)
    }

    @Test func artistExceptionNeedsTightRuntimeAndNotAVideo() {
        let other = cand("Blinding Lights", artist: "T-Series", ms: 201_000)
        if case .accepted(let p) = verdict(wanted("Blinding Lights"), other) { #expect(p > 0) } else { Issue.record("expected the runtime exception") }
        #expect(verdict(wanted("Blinding Lights"), cand("Blinding Lights", artist: "T-Series", ms: 204_000)) == .rejected(.artist))
        #expect(verdict(wanted("Blinding Lights", video: true), other) == .rejected(.artist))
    }

    @Test func runtimeWindows() {
        #expect(verdict(wanted("Song"), cand("Song", ms: 229_000)).isAccepted)
        #expect(verdict(wanted("Song"), cand("Song", ms: 231_000)) == .rejected(.duration))
        #expect(verdict(wanted("Song"), cand("Song", ms: 169_000)) == .rejected(.duration))
        // A video row with a credited artist may differ by up to 90 s.
        #expect(verdict(wanted("Song", video: true), cand("Song", ms: 260_000)).isAccepted)
        #expect(verdict(wanted("Song", video: true), cand("Song", ms: 295_000)) == .rejected(.duration))
        #expect(verdict(wanted("Song"), cand("Song", ms: 260_000)) == .rejected(.duration))
        // Unknown runtime on either side is neutral.
        #expect(verdict(wanted("Song"), cand("Song", ms: nil)).isAccepted)
        #expect(verdict(wanted("Song", ms: 0), cand("Song", ms: 500_000)).isAccepted)
    }

    @Test func explicitMismatch() {
        #expect(verdict(wanted("Song", explicit: true), cand("Song (Clean)")) == .rejected(.explicit))
        #expect(verdict(wanted("Song", explicit: false), cand("Song (Explicit)")) == .rejected(.explicit))
        #expect(verdict(wanted("Song", explicit: false, provider: "youtube-music"), cand("Song (Explicit)")).isAccepted)
        #expect(verdict(wanted("Song", explicit: true), cand("Song (Explicit)")).isAccepted)
        #expect(verdict(wanted("Song", explicit: true), cand("Song")).isAccepted)
    }

    @Test func survivorsAreOrderedByTheSoftScore() {
        let w = wanted("Blinding Lights")
        let list = [cand("Blinding Lights (Live)"), cand("Blinding Lights", artist: "The Weeknd", ms: 214_000), cand("Blinding Lights", artist: "The Weeknd - Topic")]
        let r = MusicCandidateRules.rank(track: w, candidates: list, minimum: 0.2, limit: 4) { MusicStreamResolver.score(track: $0, candidate: $1) }
        #expect(r.count == 2)
        #expect(r.allSatisfy { !$0.source.title.contains("Live") })
        #expect(r[0].score >= r[1].score)
    }
}

@Suite("Search variants")
struct SearchVariantTests {
    @Test func cleanTitleDropsCreditsAndClutterButKeepsVersions() {
        #expect(MusicCandidateRules.cleanTitle("Blinding Lights (feat. Someone)") == "Blinding Lights")
        #expect(MusicCandidateRules.cleanTitle("Blinding Lights - Remastered 2011") == "Blinding Lights")
        #expect(MusicCandidateRules.cleanTitle("Blinding Lights (Live at Wembley)") == "Blinding Lights (Live at Wembley)")
        #expect(MusicCandidateRules.cleanTitle("Song ft. Other") == "Song")
    }

    @Test func upToThreeDedupedQueries() {
        let t = MusicTrack(id: "1", providerID: "p", title: "Kesariya (From \"Brahmastra\")", durationMs: 1, artists: [MusicArtistRef(id: "a", name: "Arijit Singh")],
                           album: MusicAlbumRef(id: "x", title: "Brahmastra"))
        let q = MusicCandidateRules.queries(for: t)
        #expect(q.count == 3)
        #expect(q[0] == "Kesariya Arijit Singh")
        #expect(q[1] == "Kesariya")
        #expect(q[2].hasPrefix("Kesariya "))
        let plain = MusicTrack(id: "2", providerID: "p", title: "Song", durationMs: 1, artists: [MusicArtistRef(id: "a", name: "Band")])
        #expect(MusicCandidateRules.queries(for: plain) == ["Song Band", "Song"])
        let bare = MusicTrack(id: "3", providerID: "p", title: "Song", durationMs: 1, artists: [])
        #expect(MusicCandidateRules.queries(for: bare) == ["Song"])
    }

    @Test func nonLatinTitlesGetARomanisedQuery() {
        let t = MusicTrack(id: "1", providerID: "p", title: "夜に駆ける", durationMs: 1, artists: [MusicArtistRef(id: "a", name: "YOASOBI")])
        let q = MusicCandidateRules.queries(for: t)
        #expect(q.count == 3)
        #expect(q.contains { !$0.unicodeScalars.contains { $0.value > 0x24F } && $0.lowercased().contains("yoasobi") })
        let v = MusicCandidateRules.variants(for: t)
        #expect(v.count == 3)
        #expect(v[1].artists.isEmpty)
    }

    @Test func primaryArtistSkipsTypeLabels() {
        let t = MusicTrack(id: "1", providerID: "p", title: "S", durationMs: 1, artists: [MusicArtistRef(id: "a", name: "Song"), MusicArtistRef(id: "b", name: "Real Artist")])
        #expect(MusicCandidateRules.primaryArtist(t) == "Real Artist")
    }
}

// MARK: race

private actor Flag { var set = false; func raise() { set = true } }

private let fastClock: @Sendable (TimeInterval) async throws -> Void = { s in try await Task.sleep(nanoseconds: UInt64(s * 100_000_000)) }

@Suite("Provider race")
struct MusicRaceTests {
    @Test func firstAnswerWinsAndTheRestAreCancelled() async {
        let slowCancelled = Flag()
        let lanes: [MusicRaceLane<String>] = [
            MusicRaceLane(id: "slow") {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { await slowCancelled.raise(); throw error }
                return "slow"
            },
            MusicRaceLane(id: "fast") { "fast" }
        ]
        var cfg = MusicRace.Config(); cfg.tieGrace = 0.05
        let r = await MusicRace.run(lanes: lanes, config: cfg, sleep: fastClock)
        #expect(r.value == "fast" && r.winner == 1)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await slowCancelled.set)
    }

    @Test func healthOrderBreaksTiesBetweenCloseAnswers() async {
        let lanes: [MusicRaceLane<String>] = [
            MusicRaceLane(id: "preferred") { try await Task.sleep(nanoseconds: 20_000_000); return "preferred" },
            MusicRaceLane(id: "other") { "other" }
        ]
        let r = await MusicRace.run(lanes: lanes, config: MusicRace.Config(), sleep: fastClock)
        #expect(r.value == "preferred")
    }

    @Test func laneWithNothingAcceptableDoesNotEndTheRace() async {
        let lanes: [MusicRaceLane<String>] = [
            MusicRaceLane(id: "none") { nil },
            MusicRaceLane(id: "boom") { throw MusicError.network("down") },
            MusicRaceLane(id: "late") { try await Task.sleep(nanoseconds: 30_000_000); return "late" }
        ]
        let r = await MusicRace.run(lanes: lanes, sleep: fastClock)
        #expect(r.value == "late")
        #expect(r.empty.contains(0))
        #expect(r.errors[1] != nil)
    }

    @Test func overallLimitDropsHungLanes() async {
        let lanes: [MusicRaceLane<String>] = [MusicRaceLane(id: "a") { try await Task.sleep(nanoseconds: 60_000_000_000); return "a" },
                                              MusicRaceLane(id: "b") { try await Task.sleep(nanoseconds: 60_000_000_000); return "b" }]
        var cfg = MusicRace.Config(); cfg.overall = 1
        let started = Date()
        let r = await MusicRace.run(lanes: lanes, config: cfg, sleep: fastClock)
        #expect(r.value == nil && r.timedOut == [0, 1])
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aPatientLaneMayOutliveTheNormalLimit() async {
        let lanes: [MusicRaceLane<String>] = [
            MusicRaceLane(id: "youtube-music") { try await Task.sleep(nanoseconds: 300_000_000); return "yt" },
            MusicRaceLane(id: "audius") { try await Task.sleep(nanoseconds: 60_000_000_000); return "au" }
        ]
        var cfg = MusicRace.Config(); cfg.overall = 1; cfg.patient = 20; cfg.patientIDs = ["youtube-music"]
        let r = await MusicRace.run(lanes: lanes, config: cfg, sleep: fastClock)
        #expect(r.value == "yt")
        #expect(r.timedOut.contains(1))
    }

    @Test func everyLaneFailingGivesNoWinner() async {
        let lanes: [MusicRaceLane<String>] = [MusicRaceLane(id: "a") { throw MusicError.network("x") }, MusicRaceLane(id: "b") { nil }]
        let r = await MusicRace.run(lanes: lanes, sleep: fastClock)
        #expect(r.winner == nil && r.errors.count == 1)
    }
}

// MARK: probe

@Suite("Stream probe")
struct StreamProbeTests {
    private func reading(_ status: Int, type: String? = "audio/mp4", total: Int64? = 3_000_000, bytes: Int = 32_768) -> MusicProbeReading {
        MusicProbeReading(status: status, contentType: type, total: total, bytesRead: bytes)
    }
    private let url = URL(string: "https://rr1.googlevideo.com/videoplayback?c=VISIONOS")

    @Test func firstReadVerdicts() {
        #expect(MusicStreamVerifier.classifyFirst(reading(206), url: url) == .ok)
        #expect(MusicStreamVerifier.classifyFirst(reading(403), url: url).isRefused)
        #expect(MusicStreamVerifier.classifyFirst(reading(404), url: url).isRefused)
        #expect(MusicStreamVerifier.classifyFirst(reading(410), url: url).isRefused)
        #expect(MusicStreamVerifier.classifyFirst(reading(200, type: "text/html"), url: url).isRefused)
        #expect(MusicStreamVerifier.classifyFirst(reading(200, type: nil), url: url).isRefused)
        #expect(MusicStreamVerifier.classifyFirst(reading(500), url: url).isUnreachable)
        #expect(MusicStreamVerifier.classifyFirst(reading(206, bytes: 4_000), url: url).isUnreachable)
        #expect(MusicStreamVerifier.classifyFirst(reading(416), url: url) == .ok)
        #expect(MusicStreamVerifier.classifyFirst(nil, url: url).isUnreachable)
    }

    @Test func octetStreamNeedsAnAudioExtension() {
        let m4a = URL(string: "https://x/a.m4a")
        let bare = URL(string: "https://x/a")
        #expect(MusicStreamVerifier.classifyFirst(reading(206, type: "application/octet-stream"), url: m4a) == .ok)
        #expect(MusicStreamVerifier.classifyFirst(reading(206, type: "application/octet-stream"), url: bare).isRefused)
    }

    @Test func cutOffStreamsAreRecognised() {
        // 3 minute song, 500 KB at the lowest real bitrate is about 62 s.
        #expect(MusicStreamVerifier.isTooShort(bytes: 500_000, expectedSeconds: 180, lossless: false))
        #expect(!MusicStreamVerifier.isTooShort(bytes: 3_000_000, expectedSeconds: 180, lossless: false))
        #expect(!MusicStreamVerifier.isTooShort(bytes: nil, expectedSeconds: 180, lossless: false))
        #expect(!MusicStreamVerifier.isTooShort(bytes: 500_000, expectedSeconds: nil, lossless: false))
        #expect(MusicStreamVerifier.isTooShort(bytes: 3_000_000, expectedSeconds: 180, lossless: true))
    }

    @Test func loadedLengthAgainstTheCatalogue() {
        #expect(!MusicStreamVerifier.durationMismatch(catalogueSeconds: 200, actualSeconds: 208))
        #expect(!MusicStreamVerifier.durationMismatch(catalogueSeconds: 200, actualSeconds: 215))
        #expect(MusicStreamVerifier.durationMismatch(catalogueSeconds: 200, actualSeconds: 30))
        #expect(MusicStreamVerifier.durationMismatch(catalogueSeconds: 200, actualSeconds: 260))
        #expect(!MusicStreamVerifier.durationMismatch(catalogueSeconds: 0, actualSeconds: 260))
    }

    private func stream() -> MusicStream { MusicStream(url: "https://rr1.googlevideo.com/videoplayback?c=ANDROID_VR", codec: "aac", container: "m4a", bitrate: 128) }

    @Test func aStreamThatDiesAfterTheFirstMiBIsRefused() async {
        let reader: MusicStreamVerifier.Reader = { _, _, range, _ in
            range.hasPrefix("bytes=0-") ? MusicProbeReading(status: 206, contentType: "audio/mp4", total: 3_000_000, bytesRead: 32_768)
                : MusicProbeReading(status: 403, contentType: "text/html", total: nil, bytesRead: 0)
        }
        let v = await MusicStreamVerifier.verify(stream(), catalogueMs: 190_000, reader: reader)
        #expect(v.isRefused)
    }

    @Test func aWholeFileStreamPasses() async {
        let reader: MusicStreamVerifier.Reader = { _, _, range, limit in
            MusicProbeReading(status: 206, contentType: "audio/mp4", total: 3_000_000, bytesRead: min(limit, 16_384 * 2))
        }
        #expect(await MusicStreamVerifier.verify(stream(), catalogueMs: 190_000, reader: reader).isOK)
    }

    @Test func aPreviewIsRejectedAndManifestsAreNotProbed() async {
        let short: MusicStreamVerifier.Reader = { _, _, _, _ in MusicProbeReading(status: 206, contentType: "audio/mpeg", total: 480_000, bytesRead: 32_768) }
        let v = await MusicStreamVerifier.verify(stream(), catalogueMs: 200_000, reader: short)
        if case .preview = v {} else { Issue.record("expected preview, got \(v)") }
        var hls = stream(); hls.proto = .hls
        let boom: MusicStreamVerifier.Reader = { _, _, _, _ in nil }
        #expect(await MusicStreamVerifier.verify(hls, catalogueMs: 200_000, reader: boom).isOK)
    }
}

extension MusicProbeVerdict {
    fileprivate var isRefused: Bool { if case .refused = self { return true } else { return false } }
    fileprivate var isUnreachable: Bool { if case .unreachable = self { return true } else { return false } }
}

// MARK: proxy policy

@Suite("Proxy policy")
struct ProxyPolicyTests {
    private func u(_ s: String) -> URL { URL(string: s)! }

    @Test func windowFollowsTheMintingClient() {
        #expect(MusicProxyPolicy.window(for: u("https://rr1.googlevideo.com/videoplayback?c=ANDROID_VR&id=1")) == 512 * 1024)
        #expect(MusicProxyPolicy.window(for: u("https://rr1.googlevideo.com/videoplayback?c=TVHTML5_SIMPLY")) == 512 * 1024)
        #expect(MusicProxyPolicy.window(for: u("https://rr1.googlevideo.com/videoplayback?c=VISIONOS")) == 1_048_576)
        #expect(MusicProxyPolicy.window(for: u("https://rr1.googlevideo.com/videoplayback?c=WEB_REMIX")) == 1_048_576)
        #expect(MusicProxyPolicy.window(for: u("https://rr1.googlevideo.com/videoplayback")) == 1_048_576)
        #expect(MusicProxyPolicy.window(for: u("https://cdn.example.com/a.mp3")) == MusicProxyChunker.chunkBytes)
    }

    @Test func webClientsGetOriginAndReferer() {
        let h = MusicProxyPolicy.headers(for: u("https://rr1.googlevideo.com/videoplayback?c=WEB_REMIX"), base: ["User-Agent": "x"])
        #expect(h["Origin"] == "https://music.youtube.com" && h["Referer"] == "https://music.youtube.com/" && h["User-Agent"] == "x")
        let w = MusicProxyPolicy.headers(for: u("https://rr1.googlevideo.com/videoplayback?c=TVHTML5"), base: [:])
        #expect(w["Origin"] == "https://www.youtube.com")
        #expect(MusicProxyPolicy.headers(for: u("https://rr1.googlevideo.com/videoplayback?c=VISIONOS"), base: [:]).isEmpty)
        #expect(MusicProxyPolicy.headers(for: u("https://cdn.example.com/a.mp3?c=WEB"), base: [:]).isEmpty)
        let kept = MusicProxyPolicy.headers(for: u("https://rr1.googlevideo.com/videoplayback?c=WEB"), base: ["origin": "https://mine"])
        #expect(kept["Origin"] == nil && kept["origin"] == "https://mine")
    }

    @Test func rangedWindowsHonourTheClientWindow() {
        let w = MusicProxyChunker.windows(start: 0, end: 1_500_000, chunk: MusicProxyPolicy.narrowWindow)
        #expect(w.count == 3 && w.first == 0...524_287)
    }
}

// MARK: ladder and unplayable memory

@Suite("Failure ladder and verdict memory")
struct LadderAndMemoryTests {
    @Test func fourFailuresInARowStopTheQueue() {
        var l = MusicFailureLadder()
        var last: MusicFailureAction?
        for i in 0..<4 {
            let row = UUID()
            let first = l.decide(.thisTrack, row: row, title: "T\(i)", resolveFailure: true, atTail: false)
            #expect(first == .retry)
            last = l.decide(.thisTrack, row: row, title: "T\(i)", resolveFailure: true, atTail: false)
            if i < 3 { if case .skip = last! {} else { Issue.record("expected skip \(i)") } }
        }
        #expect(last == .stopSeveral(MusicFailureLadder.severalInARow))
    }

    @Test func aSongThatPlaysEndsTheRun() {
        var l = MusicFailureLadder()
        for _ in 0..<3 { let r = UUID(); _ = l.decide(.thisTrack, row: r, title: "T", resolveFailure: true, atTail: false); _ = l.decide(.thisTrack, row: r, title: "T", resolveFailure: true, atTail: false) }
        l.playbackStarted()
        let r = UUID(); _ = l.decide(.thisTrack, row: r, title: "T", resolveFailure: true, atTail: false)
        if case .skip = l.decide(.thisTrack, row: r, title: "T", resolveFailure: true, atTail: false) {} else { Issue.record("expected a skip after the reset") }
    }

    @Test func permanentVerdictsSkipWithoutARetry() {
        var l = MusicFailureLadder()
        if case .skip = l.decide(.thisTrack, row: UUID(), title: "T", resolveFailure: true, atTail: false, permanent: true) {} else { Issue.record("expected an immediate skip") }
    }

    @Test func offlineFailuresAreNotCounted() {
        var l = MusicFailureLadder()
        for _ in 0..<6 {
            let a = l.decide(.affectsEveryTrack, row: UUID(), title: "T", resolveFailure: true, atTail: false)
            #expect(a == .stay)
        }
    }

    @Test func verdictsAreRememberedForTenMinutes() {
        final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_000); func get() -> Date { t } }
        let c = Clock()
        let m = MusicUnplayableMemory(now: { c.get() })
        m.remember(.privateVideo, videoID: "abc")
        #expect(m.verdict(videoID: "abc") == .privateVideo)
        c.t = c.t.addingTimeInterval(9 * 60)
        #expect(m.verdict(videoID: "abc") == .privateVideo)
        c.t = c.t.addingTimeInterval(2 * 60)
        #expect(m.verdict(videoID: "abc") == nil)
        m.exclude(client: "ANDROID_VR", videoID: "abc")
        #expect(m.isExcluded(client: "ANDROID_VR", videoID: "abc") && !m.isExcluded(client: "IOS", videoID: "abc"))
        c.t = c.t.addingTimeInterval(11 * 60)
        #expect(!m.isExcluded(client: "ANDROID_VR", videoID: "abc"))
    }

    @Test func playabilityReasonsMapToPlainVerdicts() {
        typealias M = MusicUnplayableMemory
        #expect(M.classify(status: "LOGIN_REQUIRED", reason: "This video is private") == .privateVideo)
        #expect(M.classify(status: "LOGIN_REQUIRED", reason: "Sign in to confirm your age") == .ageRestricted)
        #expect(M.classify(status: "UNPLAYABLE", reason: "This video is not available in your country") == .regionLocked)
        #expect(M.classify(status: "UNPLAYABLE", reason: "This song is only available to Music Premium members") == .premiumOnly)
        #expect(M.classify(status: "ERROR", reason: "This video has been removed by the uploader") == .removed)
        #expect(M.classify(status: "LOGIN_REQUIRED", reason: "Sign in to confirm you're not a bot") == nil)
        #expect(M.classify(status: "LOGIN_REQUIRED", reason: "Sign in") == nil)
        #expect(M.Verdict.regionLocked.text.contains("country"))
    }

    @Test func emptyQueueWatchdogRetriesOnce() {
        var w = MusicEmptyQueueWatchdog()
        let a = w.shouldRetry()
        let b = w.shouldRetry()
        w.reset()
        let c = w.shouldRetry()
        #expect(a && !b && c)
    }

    @Test func seedArtistGetsALargerShare() {
        func t(_ n: Int, _ artist: String) -> MusicTrack { MusicTrack(id: "\(n)", providerID: "p", title: "Song \(n)", durationMs: 1, artists: [MusicArtistRef(id: artist, name: artist)]) }
        let pool = (0..<6).map { t($0, "seed") } + (6..<12).map { t($0, "other") }
        var f = MusicEndlessFilter()
        f.seedArtistKeys = ["seed"]
        var rng = SystemRandomNumberGenerator()
        let out = f.apply(pool, using: &rng)
        #expect(out.filter { $0.artists[0].id == "seed" }.count == 4)
        #expect(out.filter { $0.artists[0].id == "other" }.count == 2)
    }
}

// MARK: links, scan filter, downloads, parsing

@Suite("Links, scan filter and downloads")
struct LinksScanDownloadTests {
    private func parse(_ s: String) -> MusicLinkTarget? { MusicDeepLinks.parse(text: s) }
    private let yt = YouTubeMusicFullProvider.providerID

    @Test func youTubeLinkShapes() {
        #expect(parse("https://youtu.be/dQw4w9WgXcQ") == MusicLinkTarget(kind: .track, providerID: yt, id: "dQw4w9WgXcQ"))
        #expect(parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLabc") == MusicLinkTarget(kind: .track, providerID: yt, id: "dQw4w9WgXcQ"))
        #expect(parse("https://music.youtube.com/watch?v=dQw4w9WgXcQ")?.kind == .track)
        #expect(parse("https://www.youtube.com/watch?list=PLabc123")?.kind == .playlist)
        #expect(parse("https://music.youtube.com/playlist?list=OLAK5uy_abc")?.id == "OLAK5uy_abc")
        #expect(parse("https://www.youtube.com/shorts/abcdEFGhijk")?.id == "abcdEFGhijk")
        #expect(parse("https://www.youtube.com/embed/abcdEFGhijk")?.kind == .track)
        #expect(parse("https://www.youtube.com/v/abcdEFGhijk")?.kind == .track)
        #expect(parse("https://music.youtube.com/channel/UCabc123456789")?.kind == .artist)
        #expect(parse("https://music.youtube.com/browse/MPREb_abc123")?.kind == .album)
        #expect(parse("https://music.youtube.com/browse/UCabc123456789")?.kind == .artist)
        #expect(parse("https://music.youtube.com/browse/VLPLabc")?.kind == .playlist)
        #expect(parse("https://www.youtube.com/anything?list=PLzzz")?.kind == .playlist)
        #expect(parse("https://www.youtube.com/search?q=hello") == nil)
        #expect(parse("https://example.com/watch?v=abc") == nil)
        #expect(parse("https://youtube.com.evil.net/watch?v=dQw4w9WgXcQ") == nil)
    }

    @Test func sharedTextAndSearchLinks() {
        #expect(parse("Listen to this https://youtu.be/dQw4w9WgXcQ, it is great")?.id == "dQw4w9WgXcQ")
        let s = URL(string: "https://music.youtube.com/search?q=lofi+beats")!
        #expect(MusicDeepLinks.youTubeSearchQuery(s) == "lofi beats")
        #expect(MusicDeepLinks.youTubeSearchQuery(URL(string: "https://music.youtube.com/watch?v=abcdEFGhijk")!) == nil)
        #expect(parse("streamsetu://music/track/spotify/abcdefghij1234") != nil)
    }

    @Test func scanFilter() {
        #expect(!LocalScanFilter.keepsPath("/Alarms/wake.mp3"))
        #expect(!LocalScanFilter.keepsPath("/Phone/Ringtones/a.m4a"))
        #expect(!LocalScanFilter.keepsPath("/Voice Memos/memo.m4a"))
        #expect(!LocalScanFilter.keepsPath("/Notifications/ding.mp3"))
        #expect(!LocalScanFilter.keepsPath("/Podcasts/Show/ep1.mp3"))
        #expect(!LocalScanFilter.keepsPath("/Books/novel.m4b"))
        #expect(LocalScanFilter.keepsPath("/Books/novel.m4b", includeAudiobooks: true))
        #expect(LocalScanFilter.keepsPath("/Artist/Album/01 Song.mp3"))
        #expect(!LocalScanFilter.keepsDuration(12_000))
        #expect(LocalScanFilter.keepsDuration(30_000))
        #expect(LocalScanFilter.keepsDuration(0))
    }

    @Test func containerSniffing() {
        func ext(_ s: [UInt8]) -> String? { MusicContainerSniff.fileExtension(firstBytes: Data(s)) }
        #expect(ext(Array("fLaC".utf8) + [0, 0]) == "flac")
        #expect(ext([0, 0, 0, 0x20] + Array("ftypM4A ".utf8)) == "m4a")
        #expect(ext(Array("OggS".utf8)) == "ogg")
        #expect(ext([0x1A, 0x45, 0xDF, 0xA3, 1]) == "webm")
        #expect(ext(Array("ID3".utf8) + [3]) == "mp3")
        #expect(ext([0xFF, 0xFB, 0x90]) == "mp3")
        #expect(ext([0xFF, 0xF1, 0x50]) == "aac")
        #expect(ext(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)) == "wav")
        #expect(ext(Array("#EXTM3U".utf8)) == nil)
        #expect(MusicContainerSniff.fileExtension(firstBytes: Data([1, 2, 3]), mime: "audio/mpeg") == "mp3")
    }

    private func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("rd-" + UUID().uuidString) }
    private func bytes(_ n: Int) -> Data { Data((0..<n).map { UInt8($0 % 251) }) }

    private actor Log { var refusals = 0; var urls: [String] = []
        func note(_ u: URL) { urls.append(u.absoluteString) }
        func refuse() -> Int { refusals += 1; return refusals } }

    @Test func rangedDownloadReResolvesOnceOnA403() async throws {
        let file = bytes(1_100_000)
        let log = Log()
        let fetch: MusicRangedDownloader.Fetch = { url, _, range in
            await log.note(url)
            if url.absoluteString.contains("old"), range.lowerBound >= 1_048_576 { _ = await log.refuse(); return .init(status: 403, data: Data(), total: nil) }
            let slice = file[Int(range.lowerBound)...Int(min(Int64(file.count - 1), range.upperBound))]
            return .init(status: 206, data: Data(slice), total: Int64(file.count))
        }
        let dest = tmp()
        defer { try? FileManager.default.removeItem(at: dest) }
        let src = MusicRangedDownloader.Source(url: URL(string: "https://rr1.googlevideo.com/videoplayback?old=1&c=VISIONOS")!, headers: [:], total: nil)
        let out = try await MusicRangedDownloader.run(source: src, destination: dest, fetch: fetch, reresolve: {
            .init(url: URL(string: "https://rr2.googlevideo.com/videoplayback?new=1&c=VISIONOS")!, headers: [:], total: Int64(file.count))
        })
        #expect(out.bytes == Int64(file.count))
        #expect(try Data(contentsOf: dest) == file)
        #expect(await log.refusals == 1)
    }

    @Test func aChangedLengthStopsTheDownload() async {
        let file = bytes(2_000_000)
        let fetch: MusicRangedDownloader.Fetch = { url, _, range in
            if range.lowerBound > 0, url.absoluteString.contains("old") { return .init(status: 410, data: Data(), total: nil) }
            let slice = file[Int(range.lowerBound)...Int(min(Int64(file.count - 1), range.upperBound))]
            return .init(status: 206, data: Data(slice), total: Int64(file.count))
        }
        let dest = tmp()
        defer { try? FileManager.default.removeItem(at: dest) }
        do {
            _ = try await MusicRangedDownloader.run(source: .init(url: URL(string: "https://x.googlevideo.com/videoplayback?old=1")!, headers: [:], total: nil), destination: dest,
                                                    fetch: fetch, reresolve: { .init(url: URL(string: "https://y/new")!, headers: [:], total: 1_999_999) })
            Issue.record("expected a failure")
        } catch { #expect((error as? MusicRangedDownloader.Failure) == .changed) }
    }

    @Test func aSecondRefusalIsFinal() async {
        let fetch: MusicRangedDownloader.Fetch = { _, _, range in
            range.lowerBound == 0 && range.upperBound == 0 ? .init(status: 206, data: Data([1]), total: 3_000_000) : .init(status: 403, data: Data(), total: nil)
        }
        let dest = tmp()
        defer { try? FileManager.default.removeItem(at: dest) }
        do {
            _ = try await MusicRangedDownloader.run(source: .init(url: URL(string: "https://x/y")!, headers: [:], total: nil), destination: dest, fetch: fetch,
                                                    reresolve: { .init(url: URL(string: "https://x/z")!, headers: [:], total: 3_000_000) })
            Issue.record("expected a failure")
        } catch { #expect((error as? MusicRangedDownloader.Failure) == .refused(403)) }
    }

    @Test func officialAudioForAVideoRow() {
        var video = MusicTrack(id: "vid", providerID: "p", title: "Song (Official Video)", durationMs: 214_000, artists: [MusicArtistRef(id: "a", name: "Band")], isVideo: true)
        func row(_ id: String, _ title: String, _ ms: Int64, video: Bool = false, artist: String = "Band") -> MusicTrack {
            MusicTrack(id: id, providerID: "p", title: title, durationMs: ms, artists: [MusicArtistRef(id: "a", name: artist)], isVideo: video)
        }
        let results = [row("v2", "Song (Official Video)", 214_000, video: true), row("far", "Song", 260_000), row("live", "Song (Live)", 215_000),
                       row("cover", "Song", 214_000, artist: "Someone Else"), row("near", "Song", 217_000), row("nearer", "Song", 215_000)]
        #expect(MusicOfficialAudio.choose(for: video, among: results)?.id == "nearer")
        #expect(MusicOfficialAudio.choose(for: video, among: [row("far", "Song", 260_000)]) == nil)
        video.counterpartVideoID = "audioID1"
        let c = MusicOfficialAudio.counterpart(of: video)
        #expect(c?.videoID == "audioID1" && c?.isVideo == false && c?.counterpartVideoID == "vid")
        #expect(MusicOfficialAudio.counterpart(of: row("x", "Song", 1)) == nil)
    }

    @Test func watchPagePlayerResponseIsExtracted() {
        let html = #"<script>var ytInitialPlayerResponse = {"videoDetails":{"videoId":"abc","title":"a } brace"},"playabilityStatus":{"status":"OK"}};var meta=1;</script>"#
        let r = YouTubeMusicStreamResolver.playerResponse(inWatchPage: html)
        #expect((r?["videoDetails"] as? [String: Any])?["videoId"] as? String == "abc")
        #expect(YouTubeMusicStreamResolver.playerResponse(inWatchPage: "<html></html>") == nil)
    }
}

// MARK: resolver integration

private struct RaceAudio: MusicAudioProvider {
    var info: MusicProviderInfo
    var capabilities: MusicCapabilities { .audio }
    var rows: [MusicAudioSource]
    var delayMs: UInt64 = 0
    var fail = false
    var streamURL: String

    func sources(for track: MusicTrack) async throws -> [MusicAudioSource] {
        if delayMs > 0 { try await Task.sleep(nanoseconds: delayMs * 1_000_000) }
        if fail { throw MusicError.network("down") }
        return rows
    }
    func streams(for source: MusicAudioSource) async throws -> [MusicStream] {
        [MusicStream(url: streamURL + "/" + source.id, codec: "aac", container: "m4a", bitrate: 160)]
    }
}

@MainActor
private func registry(_ ps: [RaceAudio]) throws -> MusicRegistry {
    let suite = "music.test." + UUID().uuidString
    let d = try #require(UserDefaults(suiteName: suite))
    d.removePersistentDomain(forName: suite)
    let r = MusicRegistry(defaults: d)
    for p in ps { r.register(p); r.setEnabled(true, id: p.info.id) }
    return r
}

@Suite("Resolver rules and race")
@MainActor
struct ResolverRulesTests {
    private func row(_ id: String, _ title: String, artist: String = "The Weeknd", ms: Int64 = 200_000) -> MusicAudioSource {
        MusicAudioSource(id: id, providerID: "x", title: title, artist: artist, album: nil, durationMs: ms, externalURL: nil, confidence: 0.8)
    }
    private let want = MusicTrack(id: "w", providerID: "spotify", title: "Blinding Lights", durationMs: 200_000, artists: [MusicArtistRef(id: "a", name: "The Weeknd")])

    @Test func aLiveOnlyProviderIsNeverUsed() async throws {
        let p = RaceAudio(info: .init(id: "a", name: "A", summary: ""), rows: [row("live", "Blinding Lights (Live)")], streamURL: "https://a")
        let r = MusicStreamResolver(registry: try registry([p]))
        r.verifier = nil
        await #expect(throws: MusicError.noPlayableSource(want.title)) { try await r.resolve(want, quality: .high) }
    }

    @Test func fastestAcceptableProviderWins() async throws {
        let slow = RaceAudio(info: .init(id: "a", name: "A", summary: ""), rows: [row("s", "Blinding Lights")], delayMs: 1_500, streamURL: "https://slow")
        let fast = RaceAudio(info: .init(id: "b", name: "B", summary: ""), rows: [row("f", "Blinding Lights")], streamURL: "https://fast")
        let r = MusicStreamResolver(registry: try registry([slow, fast]))
        r.verifier = nil
        let started = Date()
        let s = try await r.resolve(want, quality: .high)
        #expect(s.url == "https://fast/f")
        #expect(Date().timeIntervalSince(started) < 1.2)
    }

    @Test func aStreamThatFailsTheProbeFallsToTheNextProvider() async throws {
        let a = RaceAudio(info: .init(id: "a", name: "A", summary: ""), rows: [row("bad", "Blinding Lights")], streamURL: "https://bad")
        let b = RaceAudio(info: .init(id: "b", name: "B", summary: ""), rows: [row("good", "Blinding Lights")], delayMs: 100, streamURL: "https://good")
        let r = MusicStreamResolver(registry: try registry([a, b]))
        r.verifier = { url, _, _, limit in
            url.absoluteString.hasPrefix("https://bad")
                ? MusicProbeReading(status: 403, contentType: "text/html", total: nil, bytesRead: 0)
                : MusicProbeReading(status: 206, contentType: "audio/mp4", total: 3_000_000, bytesRead: limit)
        }
        let s = try await r.resolve(want, quality: .high)
        #expect(s.url == "https://good/good")
    }

    @Test func aDeadProviderDoesNotHoldUpTheOthers() async throws {
        let dead = RaceAudio(info: .init(id: "a", name: "A", summary: ""), rows: [], fail: true, streamURL: "https://dead")
        let good = RaceAudio(info: .init(id: "b", name: "B", summary: ""), rows: [row("g", "Blinding Lights")], streamURL: "https://good")
        let r = MusicStreamResolver(registry: try registry([dead, good]))
        r.verifier = nil
        #expect(try await r.resolve(want, quality: .high).url == "https://good/g")
    }
}
