import Foundation
import Testing
@testable import REDDY

// Time to first sound: the stream cache, the split stream check, the read-ahead grid, the bounded pre-resolve and the trusted-pair skip.

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date = Date()) { value = start }
    var now: Date { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    func advance(_ s: TimeInterval) { lock.withLock { value = value.addingTimeInterval(s) } }
}

/// An audio provider that counts how often it was asked for streams.
private final class CountingAudio: MusicAudioProvider, @unchecked Sendable {
    let info: MusicProviderInfo
    var capabilities: MusicCapabilities { .audio }
    let host: String
    let expiresIn: TimeInterval?
    let clock: TestClock
    private let lock = NSLock()
    private var streamCalls = 0
    var calls: Int { lock.withLock { streamCalls } }

    init(id: String, host: String, expiresIn: TimeInterval? = nil, clock: TestClock) {
        info = MusicProviderInfo(id: id, name: id, summary: "")
        self.host = host; self.expiresIn = expiresIn; self.clock = clock
    }

    func sources(for track: MusicTrack) async throws -> [MusicAudioSource] {
        [MusicAudioSource(id: "r", providerID: info.id, title: track.title, artist: track.artists.first?.name, album: nil, durationMs: track.durationMs, externalURL: nil, confidence: 0.9)]
    }
    func streams(for source: MusicAudioSource) async throws -> [MusicStream] {
        lock.withLock { streamCalls += 1 }
        return [MusicStream(url: "https://\(host)/\(source.id)", codec: "aac", container: "m4a", bitrate: 160, expiresAt: expiresIn.map { clock.now.addingTimeInterval($0) })]
    }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    func release() { lock.withLock { open = true } }
    /// Waits until released, at most `limit` seconds (so a broken test cannot hang the run).
    func wait(limit: TimeInterval = 4) async {
        let end = Date().addingTimeInterval(limit)
        while !lock.withLock({ open }), Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var items: [String] = []
    func hit(_ s: String = "") { lock.withLock { n += 1; items.append(s) } }
    var count: Int { lock.withLock { n } }
    var all: [String] { lock.withLock { items } }
}

@MainActor
private func makeRegistry(_ ps: [CountingAudio]) throws -> MusicRegistry {
    let suite = "music.speed." + UUID().uuidString
    let d = try #require(UserDefaults(suiteName: suite))
    d.removePersistentDomain(forName: suite)
    let r = MusicRegistry(defaults: d)
    for p in ps { r.register(p); r.setEnabled(true, id: p.info.id) }
    return r
}

private func song(_ id: String = UUID().uuidString) -> MusicTrack {
    MusicTrack(id: id, providerID: "spotify", title: "Blinding Lights", durationMs: 200_000, artists: [MusicArtistRef(id: "a", name: "The Weeknd")])
}

@Suite("Start speed: stream cache")
@MainActor
struct StartSpeedCacheTests {
    @Test func aResolvedStreamIsServedFromMemoryUntilItExpires() async throws {
        let clock = TestClock()
        let p = CountingAudio(id: "a", host: "cache-\(UUID().uuidString).example", clock: clock)
        let r = MusicStreamResolver(registry: try makeRegistry([p]), now: { clock.now })
        r.verifier = nil
        let t = song()
        let first = try await r.resolve(t, quality: .high)
        let again = try await r.resolve(t, quality: .high)
        #expect(first == again)
        #expect(p.calls == 1)
        #expect(MusicStartTimeline.shared.report(t.uid)?.tags.contains("cached stream") == true)
        clock.advance(MusicStreamResolver.defaultLifetime + 60)
        _ = try await r.resolve(t, quality: .high)
        #expect(p.calls == 2)
    }

    @Test func aStreamWithItsOwnExpiryLivesAsLongAsThatExpiry() async throws {
        let clock = TestClock()
        let p = CountingAudio(id: "a", host: "expiry-\(UUID().uuidString).example", expiresIn: 5 * 3600, clock: clock)
        let r = MusicStreamResolver(registry: try makeRegistry([p]), now: { clock.now })
        r.verifier = nil
        let t = song()
        _ = try await r.resolve(t, quality: .high)
        clock.advance(4 * 3600)
        _ = try await r.resolve(t, quality: .high)
        #expect(p.calls == 1)
        clock.advance(3600)
        _ = try await r.resolve(t, quality: .high)
        #expect(p.calls == 2)
    }

    @Test func eachQualityHasItsOwnCacheEntry() async throws {
        let clock = TestClock()
        let p = CountingAudio(id: "a", host: "quality-\(UUID().uuidString).example", clock: clock)
        let r = MusicStreamResolver(registry: try makeRegistry([p]), now: { clock.now })
        r.verifier = nil
        let t = song()
        _ = try await r.resolve(t, quality: .high)
        _ = try await r.resolve(t, quality: .low)
        #expect(p.calls == 2)
    }
}

@Suite("Start speed: split stream check")
@MainActor
struct StartSpeedVerificationTests {
    private func reading(_ range: String, limit: Int, midStatus: Int = 206) -> MusicProbeReading {
        range.hasPrefix("bytes=0-")
            ? MusicProbeReading(status: 206, contentType: "audio/mp4", total: 3_000_000, bytesRead: limit)
            : MusicProbeReading(status: midStatus, contentType: "audio/mp4", total: 3_000_000, bytesRead: limit)
    }

    @Test func theMiddleAndTailAreReadAfterTheSongHasStarted() async throws {
        let clock = TestClock()
        let host = "late-\(UUID().uuidString).example"
        let p = CountingAudio(id: "late", host: host, clock: clock)
        let r = MusicStreamResolver(registry: try makeRegistry([p]), now: { clock.now })
        let gate = Gate()
        let deep = Counter()
        r.verifier = { _, _, range, limit in
            if range.hasPrefix("bytes=0-") { return MusicProbeReading(status: 206, contentType: "audio/mp4", total: 3_000_000, bytesRead: limit) }
            deep.hit(range)
            await gate.wait()
            return MusicProbeReading(status: 206, contentType: "audio/mp4", total: 3_000_000, bytesRead: limit)
        }
        let started = Date()
        let s = try await r.resolve(song(), quality: .high)
        #expect(s.url == "https://\(host)/r")
        // The resolve returned while both deep reads were still waiting on the gate.
        #expect(Date().timeIntervalSince(started) < 2)
        gate.release()
    }

    @Test func aFailingMiddleReadRejectsTheAddressAfterTheStart() async {
        let proof = MusicStreamProof(now: { Date() })
        let stream = MusicStream(url: "https://deep-\(UUID().uuidString).example/a", codec: "aac", container: "m4a", bitrate: 128)
        let rejected = Counter()
        proof.setLateRejectionHandler { url, reason in rejected.hit(url + "|" + reason) }
        let refused = Counter()
        proof.checkLater(stream, total: 3_000_000, pair: "p|h", reader: { _, _, _, limit in
            MusicProbeReading(status: 403, contentType: "text/html", total: 3_000_000, bytesRead: 0)
        }, onRefused: { refused.hit() }, run: { work in Task { await work() } })
        for _ in 0..<100 where rejected.count == 0 { try? await Task.sleep(nanoseconds: 20_000_000) }
        #expect(rejected.count == 1)
        #expect(rejected.all.first?.hasPrefix(stream.url) == true)
        #expect(refused.count == 1)
        #expect(!proof.isPassed(stream.url))
    }

    @Test func aPassingDeepReadMarksTheAddressProvenAndCountsForThePair() async {
        let proof = MusicStreamProof(now: { Date() })
        let stream = MusicStream(url: "https://ok-\(UUID().uuidString).example/a", codec: "aac", container: "m4a", bitrate: 128)
        proof.checkLater(stream, total: 3_000_000, pair: "p|h", reader: { _, _, _, limit in
            MusicProbeReading(status: 206, contentType: "audio/mp4", total: 3_000_000, bytesRead: limit)
        }, run: { work in Task { await work() } })
        for _ in 0..<100 where !proof.isPassed(stream.url) { try? await Task.sleep(nanoseconds: 20_000_000) }
        #expect(proof.isPassed(stream.url))
        #expect(!proof.isTrusted("p|h"))
    }

    @Test func theStartReadAloneDecidesWhetherPlaybackMayBegin() async {
        let stream = MusicStream(url: "https://start-\(UUID().uuidString).example/a", codec: "aac", container: "m4a", bitrate: 128)
        let proof = MusicStreamProof()
        let good = await MusicStreamVerifier.verifyStart(stream, catalogueMs: 200_000, reader: { _, _, range, limit in
            #expect(range.hasPrefix("bytes=0-"))
            return MusicProbeReading(status: 206, contentType: "audio/mp4", total: 3_000_000, bytesRead: limit)
        }, proof: proof)
        #expect(good.verdict == .ok)
        #expect(good.total == 3_000_000)
        #expect(proof.size(of: stream.url) == .init(total: 3_000_000, contentType: "audio/mp4"))
        let bad = await MusicStreamVerifier.verifyStart(stream, catalogueMs: 200_000, reader: { _, _, _, _ in
            MusicProbeReading(status: 200, contentType: "text/html", total: nil, bytesRead: 100)
        }, proof: proof)
        if case .refused = bad.verdict {} else { Issue.record("expected a refusal, got \(bad.verdict)") }
    }
}

@Suite("Start speed: trusted pairs")
@MainActor
struct StartSpeedTrustTests {
    @Test func aPairIsTrustedAfterCleanRecentPassesAndLosesItOnAFailure() {
        let clock = TestClock()
        let proof = MusicStreamProof(now: { clock.now })
        for _ in 0..<(MusicStreamProof.trustPasses - 1) { proof.recordPass("a|h") }
        #expect(!proof.isTrusted("a|h"))
        proof.recordPass("a|h")
        #expect(proof.isTrusted("a|h"))
        proof.recordFailure("a|h")
        #expect(!proof.isTrusted("a|h"))
    }

    @Test func trustFadesWhenThePassesAreOld() {
        let clock = TestClock()
        let proof = MusicStreamProof(now: { clock.now })
        for _ in 0..<MusicStreamProof.trustPasses { proof.recordPass("a|h") }
        #expect(proof.isTrusted("a|h"))
        clock.advance(MusicStreamProof.trustWindow + 1)
        #expect(!proof.isTrusted("a|h"))
    }

    @Test func provenAddressesAreForgottenAfterTheirMemoryAndTheStoreIsBounded() {
        let clock = TestClock()
        let proof = MusicStreamProof(now: { clock.now })
        proof.markPassed("https://x/1", size: .init(total: 10, contentType: nil))
        #expect(proof.isPassed("https://x/1"))
        clock.advance(MusicStreamProof.memory + 1)
        #expect(!proof.isPassed("https://x/1"))
        for i in 0..<(MusicStreamProof.capacity + 20) { proof.markPassed("https://x/n\(i)") }
        #expect(!proof.isPassed("https://x/n0"))
        #expect(proof.isPassed("https://x/n\(MusicStreamProof.capacity + 19)"))
    }

    @Test func pairKeysNameTheYouTubeClientOrTheHost() throws {
        let yt = try #require(URL(string: "https://rr1.googlevideo.com/videoplayback?c=ios&id=1"))
        #expect(MusicStreamProof.pairKey(provider: "ytm", url: yt) == "ytm|IOS")
        let other = try #require(URL(string: "https://Cdn.Example.com/a.mp3"))
        #expect(MusicStreamProof.pairKey(provider: "audius", url: other) == "audius|cdn.example.com")
    }

    @Test func aTrustedPairStartsWithoutWaitingForItsOpeningRead() async throws {
        let clock = TestClock()
        let host = "trusted-\(UUID().uuidString).example"
        let p = CountingAudio(id: "trust", host: host, clock: clock)
        let r = MusicStreamResolver(registry: try makeRegistry([p]), now: { clock.now })
        let pair = MusicStreamProof.pairKey(provider: "trust", url: URL(string: "https://\(host)/r"))
        for _ in 0..<MusicStreamProof.trustPasses { MusicStreamProof.shared.recordPass(pair) }
        let gate = Gate()
        let reads = Counter()
        r.verifier = { _, _, range, limit in
            reads.hit(range)
            await gate.wait()
            return MusicProbeReading(status: 206, contentType: "audio/mp4", total: 3_000_000, bytesRead: limit)
        }
        let started = Date()
        let s = try await r.resolve(song(), quality: .high)
        #expect(s.url == "https://\(host)/r")
        #expect(Date().timeIntervalSince(started) < 2)
        gate.release()
        for _ in 0..<100 where reads.count == 0 { try? await Task.sleep(nanoseconds: 20_000_000) }
        // The check still happens, afterwards.
        #expect(reads.count >= 1)
    }
}

@Suite("Start speed: first window and read-ahead")
struct StartSpeedReadAheadTests {
    @Test func theFirstBlockIsSmallAndTheBlocksCoverTheFileWithoutGaps() {
        let g = MusicBlockGrid(total: 5_736_965)
        #expect(g.range(of: 0) == 0...131_071)
        #expect(g.range(of: 1).lowerBound == 131_072)
        #expect(g.range(of: 1).count == 512 * 1024)
        var next: Int64 = 0
        for i in 0..<g.count {
            let r = g.range(of: i)
            #expect(r.lowerBound == next)
            next = r.upperBound + 1
        }
        #expect(next == g.total)
        #expect(g.index(of: 0) == 0)
        #expect(g.index(of: 131_071) == 0)
        #expect(g.index(of: 131_072) == 1)
        #expect(g.index(of: g.total - 1) == g.count - 1)
    }

    @Test func aSmallFileIsOneBlock() {
        let g = MusicBlockGrid(total: 1_000)
        #expect(g.count == 1)
        #expect(g.range(of: 0) == 0...999)
    }

    @Test func readAheadFetchesTheNextBlocksOnceAndServesRepeatsFromMemory() async {
        let g = MusicBlockGrid(total: 4_000_000)
        let fetched = Counter()
        let ra = MusicReadAhead(grid: g, depth: 2) { range in
            fetched.hit("\(range.lowerBound)")
            return Data(count: Int(range.upperBound - range.lowerBound + 1))
        }
        let a = await ra.block(0)
        #expect(a?.count == 131_072)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(fetched.count == 3) // block 0 plus two ahead
        _ = await ra.block(0)
        _ = await ra.block(1)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(fetched.count == 4) // block 3 joined; 0, 1 and 2 were not fetched again
        ra.stop()
    }

    @Test func aFailedBlockIsNotRemembered() async {
        let g = MusicBlockGrid(total: 300_000)
        let calls = Counter()
        let ra = MusicReadAhead(grid: g, depth: 0) { _ in calls.hit(); return calls.count == 1 ? nil : Data(count: 131_072) }
        #expect(await ra.block(0) == nil)
        #expect(await ra.block(0) != nil)
        #expect(calls.count == 2)
    }

    @Test func readAheadHoldsAtMostItsBlockBudget() async {
        let g = MusicBlockGrid(total: 40_000_000)
        let ra = MusicReadAhead(grid: g, depth: 1, maxBlocks: 6) { range in Data(count: 1) }
        for i in stride(from: 0, to: 40, by: 4) { _ = await ra.block(i) }
        #expect(ra.heldBlocks <= 6 + 1)
        ra.stop()
        #expect(await ra.block(1) == nil)
    }
}

@Suite("Start speed: bounded pre-resolve")
@MainActor
struct StartSpeedPreResolveTests {
    private func rows(_ n: Int) -> [MusicTrack] { (0..<n).map { song("pre-\($0)-\(UUID().uuidString)") } }

    @Test func aHintStartsAtMostTheLimitsAndNeverMoreThanTwoAtOnce() async {
        let gate = Gate()
        let warmed = Counter()
        let pr = MusicPreResolver(warm: { t in warmed.hit(t.uid); await gate.wait(limit: 2) })
        let started = pr.hint(rows(10))
        #expect(started.count == 2)
        #expect(pr.inflightCount == 2)
        #expect(pr.limits.perHint == 3)
        gate.release()
    }

    @Test func aNewerHintCancelsWhatTheOlderOneHasNotFinished() async {
        let cancelled = Counter()
        let pr = MusicPreResolver(warm: { t in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { cancelled.hit(t.uid) }
        })
        let first = rows(2)
        pr.hint(first)
        let second = rows(2)
        let started = pr.hint(second)
        #expect(started.count == 2)
        #expect(pr.inflightCount == 2)
        for _ in 0..<50 where cancelled.count < 2 { try? await Task.sleep(nanoseconds: 50_000_000) }
        #expect(Set(cancelled.all) == Set(first.map(\.uid)))
        pr.cancelAll()
        #expect(pr.inflightCount == 0)
    }

    @Test func aSongWarmedLatelyIsNotAskedAgain() async {
        let clock = TestClock()
        let pr = MusicPreResolver(now: { clock.now }, warm: { _ in })
        let r = rows(1)
        #expect(pr.hint(r).count == 1)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(pr.hint(r).isEmpty)
        clock.advance(pr.limits.recent + 1)
        #expect(pr.hint(r).count == 1)
    }

    @Test func nothingRunsOnAMeteredLinkAndRunningLookupsStop() async {
        let metered = LockedBox(false)
        let pr = MusicPreResolver(allowed: { !metered.value }, warm: { _ in try? await Task.sleep(nanoseconds: 2_000_000_000) })
        #expect(pr.hint(rows(1)).count == 1)
        metered.value = true
        #expect(pr.hint(rows(2)).isEmpty)
        #expect(pr.inflightCount == 0)
    }

    @Test func anAutomaticHintIsDroppedWhenMusicHasBeenIdleButAPersonsHintIsNot() async {
        let clock = TestClock()
        let pr = MusicPreResolver(now: { clock.now }, warm: { _ in })
        clock.advance(pr.limits.idle + 1)
        #expect(pr.isIdle)
        #expect(pr.hint(rows(1), background: true).isEmpty)
        #expect(pr.hint(rows(1)).count == 1)
        #expect(!pr.isIdle)
    }

    @Test func localFilesAreNotLookedUp() {
        let pr = MusicPreResolver(warm: { _ in })
        let local = MusicTrack(id: "l", providerID: "local", title: "T", durationMs: 1, artists: [], directStreams: [MusicStream(url: "file:///tmp/a.m4a", codec: "aac", container: "m4a")])
        #expect(pr.hint([local]).isEmpty)
    }
}

@Suite("Start speed: timeline and fast start")
struct StartSpeedTimelineTests {
    @Test func stagesAreMeasuredFromThePressAndTheFirstStampWins() {
        let t = LockedBox<UInt64>(1_000_000_000)
        let tl = MusicStartTimeline(clock: { t.value })
        tl.begin("k")
        t.value += 120_000_000; tl.mark("k", .searched)
        t.value += 300_000_000; tl.mark("k", .resolved)
        t.value += 50_000_000; tl.mark("k", .resolved)
        t.value += 400_000_000; tl.mark("k", .firstSound)
        tl.tag("k", "cached stream")
        let r = tl.report("k")
        #expect(r?.offsets[.searched] == 120)
        #expect(r?.offsets[.resolved] == 420)
        #expect(r?.timeToFirstSound == 870)
        #expect(r?.summary.contains("sound +450") == true)
        #expect(r?.summary.hasSuffix("(cached stream)") == true)
    }

    @Test func aPressStartsAFreshTimelineAndOldTracksAreForgotten() {
        let t = LockedBox<UInt64>(1)
        let tl = MusicStartTimeline(capacity: 2, clock: { t.value })
        tl.begin("a"); tl.begin("b"); tl.begin("c")
        #expect(tl.report("a") == nil)
        t.value += 5_000_000
        tl.mark("c", .itemReady)
        tl.begin("c")
        #expect(tl.report("c")?.offsets[.itemReady] == nil)
    }

    @Test func theStartSettingsAreLiftedAfterAFewSecondsOrOnAStall() {
        #expect(!MusicFastStart.shouldRelax(playedSeconds: 1, isWaiting: false))
        #expect(MusicFastStart.shouldRelax(playedSeconds: MusicFastStart.relaxAfter, isWaiting: false))
        #expect(MusicFastStart.shouldRelax(playedSeconds: 1, isWaiting: true))
        #expect(!MusicFastStart.shouldRelax(playedSeconds: 0.1, isWaiting: true))
    }
}
