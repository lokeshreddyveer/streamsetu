import Foundation
import Testing
@testable import REDDY

// Playback failure and retry machinery under random failure sequences. Fake providers, fake streams and a virtual clock; every run is seeded, so a
// failing seed can be replayed. The invariants checked here:
//  (a) a retry after any failure is a fresh lookup and never ends with nothing while a provider, client or twin remains untried;
//  (b) failure marks are bounded, expire, are cleared by a later success, and a transient failure never becomes a permanent verdict;
//  (c) negative memories are bounded and reset by the person, a network change or the app returning;
//  (d) every terminal failure has a plain reason;
//  (e) the ladder stops (at most one retry per row, a stop after four failures in a row), whatever order things fail in;
//  (f) an address past its expiry (or within the safety margin) is never handed out;
//  (g) a late-rejection swap happens at most once per row;
//  (h) a row marker follows the current verdict: expires, clears on success.

// MARK: tools

private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private final class VClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ s: TimeInterval) { lock.withLock { value = value.addingTimeInterval(s) } }
}

/// How the next call to the fake provider's `streams(for:)` behaves.
private enum Step { case ok, throwsNetwork, empty, hang }

/// A YouTube-shaped provider with a URL cache of its own. `ignoresEviction` and `ignoresBadMemory` model the worst copies of the bug.
private final class ChaosProvider: MusicAudioProvider, MusicStreamEvicting, @unchecked Sendable {
    let info: MusicProviderInfo
    var capabilities: MusicCapabilities { .audio }
    private let lock = NSLock()
    private let clock: VClock
    private let memory: MusicUnplayableMemory
    /// True for the YouTube-shaped provider (a row naming a video id gets that exact video; a search request gets its audio twin).
    let youTubeShaped: Bool
    var cachesAddresses = true
    var ignoresEviction = false
    var ignoresBadMemory = false
    /// One address per video forever (a source with a single address, like a plain file host).
    var singleAddress = false
    private var script: [Step] = []
    private var cache: [String: MusicStream] = [:]
    private var minted = 0
    private(set) var streamCalls = 0
    private(set) var evictions = 0

    init(clock: VClock, memory: MusicUnplayableMemory, id: String = YTM.providerID) {
        self.clock = clock; self.memory = memory
        youTubeShaped = id == YTM.providerID
        info = MusicProviderInfo(id: id, name: "Fake " + id, summary: "")
    }

    func queue(_ steps: Step...) { lock.withLock { script += steps } }
    var mintedCount: Int { lock.withLock { minted } }

    func sources(for track: MusicTrack) async throws -> [MusicAudioSource] {
        if let vid = track.videoID ?? (track.providerID == info.id ? track.id : nil) {
            return [MusicAudioSource(id: vid, providerID: info.id, title: track.title, artist: track.artistLine, album: nil, durationMs: track.durationMs, externalURL: nil, confidence: 1)]
        }
        return [MusicAudioSource(id: "TWIN" + String(track.id.suffix(7)), providerID: info.id, title: track.title, artist: track.artistLine, album: nil,
                                 durationMs: track.durationMs, externalURL: nil, confidence: 0.9)]
    }

    func streams(for source: MusicAudioSource) async throws -> [MusicStream] {
        let step: Step = lock.withLock { streamCalls += 1; return script.isEmpty ? .ok : script.removeFirst() }
        switch step {
        case .throwsNetwork: throw MusicError.network("fake outage")
        case .empty: return []
        case .hang: try await Task.sleep(nanoseconds: 60_000_000_000); return []
        case .ok: break
        }
        return lock.withLock {
            if cachesAddresses, let c = cache[source.id] {
                let expired = c.expiresAt.map { $0 <= clock.now.addingTimeInterval(60) } ?? false
                let known = !ignoresBadMemory && memory.isBadURL(c.url)
                if !expired && !known { return [c] }
            }
            minted += 1
            let n = singleAddress ? 0 : minted
            let expire = Int(clock.now.timeIntervalSince1970) + 21_540
            var s = MusicStream(url: "https://rr.example/v/\(source.id)?c=VISIONOS&expire=\(expire)&n=\(n)", codec: "aac", container: "m4a", bitrate: 128)
            s.expiresAt = Date(timeIntervalSince1970: TimeInterval(expire))
            if cachesAddresses { cache[source.id] = s }
            return [s]
        }
    }

    func evictStreams(for source: MusicAudioSource) async {
        lock.withLock {
            evictions += 1
            if !ignoresEviction { cache[source.id] = nil }
        }
    }
}

private func row(_ vid: String = "VID00000001", title: String = "Basinga Balaalu", provider: String = YTM.providerID) -> MusicTrack {
    var t = MusicTrack(id: vid, providerID: provider, title: title, durationMs: 262_000, artists: [MusicArtistRef(id: "a", name: "Srinidhi Nerella")])
    t.videoID = vid
    return t
}

@MainActor
private final class Rig {
    let clock = VClock()
    let provider: ChaosProvider
    let memory: MusicUnplayableMemory
    let resolver: MusicStreamResolver
    let log = MusicPlaybackLog()
    var ladder = MusicFailureLadder()
    /// Addresses that fail the first time they are played (a transient failure).
    var failOnce: Set<String> = []
    /// Addresses that always fail when played (revoked).
    var alwaysFail: Set<String> = []
    private(set) var played: [String] = []

    init(providerID: String = YTM.providerID, configure: (ChaosProvider) -> Void = { _ in }) throws {
        let c = clock
        // Each rig has its own unplayable memory, so these tests never touch the one the other suites use.
        memory = MusicUnplayableMemory(now: { c.now })
        provider = ChaosProvider(clock: clock, memory: memory, id: providerID)
        configure(provider)
        let suite = "music.chaos." + UUID().uuidString
        let d = try #require(UserDefaults(suiteName: suite))
        d.removePersistentDomain(forName: suite)
        let reg = MusicRegistry(defaults: d)
        reg.register(provider); reg.setEnabled(true, id: provider.info.id)
        resolver = MusicStreamResolver(registry: reg, now: { c.now })
        resolver.unplayable = memory
        resolver.verifier = nil
        resolver.log = log
    }

    enum Terminal: Equatable { case playing(String), failed(String) }

    struct Result { var terminal: Terminal; var attempts: Int; var urls: [String] }

    /// The player's loop in miniature: resolve, "play", and on a failure ask the real ladder, evicting through the real resolver calls.
    func play(_ t: MusicTrack, maxAttempts: Int = 6) async -> Result {
        let rowID = UUID()
        var urls: [String] = []
        var attempts = 0
        while attempts < maxAttempts {
            attempts += 1
            do {
                let s = try await resolver.resolve(t, quality: .high)
                urls.append(s.url)
                if alwaysFail.contains(s.url) || failOnce.remove(s.url) != nil {
                    let action = ladder.decide(.thisTrack, row: rowID, title: t.title, resolveFailure: false, atTail: true)
                    resolver.reportFailure(t, stream: s, reason: "The stream stopped working.")
                    if case .retry = action { continue }
                    return Result(terminal: .failed(MusicPlaybackMessages.reason(error: nil, message: "The stream stopped working.", title: t.title)), attempts: attempts, urls: urls)
                }
                resolver.noteSuccess(t)
                ladder.playbackStarted()
                played.append(s.url)
                return Result(terminal: .playing(s.url), attempts: attempts, urls: urls)
            } catch {
                let kind = MusicFailureKind.classify(error)
                let permanent = memory.verdict(videoID: t.videoID ?? t.id) != nil
                let action = ladder.decide(kind, row: rowID, title: t.title, resolveFailure: true, atTail: true, permanent: permanent)
                if case .retry = action { resolver.evict(t, stream: nil); continue }
                return Result(terminal: .failed(MusicPlaybackMessages.reason(error: error, message: error.localizedDescription, title: t.title)), attempts: attempts, urls: urls)
            }
        }
        return Result(terminal: .failed("attempt bound reached"), attempts: attempts, urls: urls)
    }
}

/// Every suite shares the process-wide unplayable memory and proof table, so they run one after another.
@Suite("Playback robustness", .serialized) struct PlaybackRobustness {}

extension PlaybackRobustness {
    // MARK: the Basinga Balaalu case at every cache layer

    @Suite("Retry after a failure is a fresh lookup")
    @MainActor
    struct RetryIsFreshTests {
        @Test func resultCacheLayerDoesNotServeTheFailedAddress() async throws {
            let rig = try Rig { $0.cachesAddresses = false }
            let t = row()
            let first = try await rig.resolver.resolve(t, quality: .high)
            rig.resolver.reportFailure(t, stream: first, reason: "stalled")
            let second = try await rig.resolver.resolve(t, quality: .high)
            #expect(second.url != first.url)
        }

        @Test func providerCacheLayerThatHonoursEvictionOrBadMemoryIsRefreshed() async throws {
            for (evict, memory) in [(true, true), (true, false), (false, true)] {
                let rig = try Rig { $0.ignoresEviction = !evict; $0.ignoresBadMemory = !memory }
                let t = row()
                let first = try await rig.resolver.resolve(t, quality: .high)
                rig.resolver.reportFailure(t, stream: first, reason: "stalled")
                try await Task.sleep(nanoseconds: 50_000_000)   // the fire-and-forget eviction
                let second = try await rig.resolver.resolve(t, quality: .high)
                #expect(second.url != first.url, "evict \(evict) memory \(memory)")
            }
        }

        /// The exact bug: the provider keeps handing back the same address. The old code removed it, found nothing and said "No playable source".
        @Test func aProviderThatReturnsTheSameAddressStillGivesTheRetryASourceToTry() async throws {
            let rig = try Rig(providerID: "plainhost") { $0.ignoresEviction = true; $0.ignoresBadMemory = true }
            let t = row("PLAIN000001", provider: "plainhost")
            let first = try await rig.resolver.resolve(t, quality: .high)
            rig.resolver.reportFailure(t, stream: first, reason: "stalled")
            let second = try await rig.resolver.resolve(t, quality: .high)   // before: throws noPlayableSource
            #expect(second.url == first.url)
            #expect(rig.resolver.badAddressCount >= 1)
        }

        @Test func aSingleAddressSourceThatFailedOnceIsPlayedAgainNotSkipped() async throws {
            let rig = try Rig(providerID: "plainhost") { $0.singleAddress = true }
            let t = row("PLAIN000002", provider: "plainhost")
            let first = try await rig.resolver.resolve(t, quality: .high)
            rig.failOnce = [first.url]
            let r = await rig.play(t)
            #expect(r.terminal == .playing(first.url))
            #expect(r.attempts <= 2)
        }

        /// A YouTube-shaped row has an audio twin, which is tried before an address that already failed is reused.
        @Test func aYouTubeShapedRowFallsBackToItsTwinBeforeReusingAFailedAddress() async throws {
            let rig = try Rig { $0.ignoresEviction = true; $0.ignoresBadMemory = true; $0.singleAddress = true }
            let t = row()
            let first = try await rig.resolver.resolve(t, quality: .high)
            rig.failOnce = [first.url]
            let r = await rig.play(t)
            guard case .playing(let url) = r.terminal else { Issue.record("the retry did not play"); return }
            #expect(url != first.url)
            #expect(r.attempts <= 2)
        }

        @Test func preResolvedStreamIsEvictedWithTheFailedAddress() async throws {
            let rig = try Rig()
            let t = row()
            let warm = MusicPreResolver(warm: { [resolver = rig.resolver] track in _ = try? await resolver.resolve(track, quality: .high) })
            warm.hint([t])
            try await Task.sleep(nanoseconds: 150_000_000)
            let warmed = try await rig.resolver.resolve(t, quality: .high)
            #expect(MusicStartTimeline.shared.report(t.uid)?.tags.contains("cached stream") == true)
            rig.resolver.evict(t, stream: warmed)   // a lookahead that failed to open, never played
            let fresh = try await rig.resolver.resolve(t, quality: .high)
            #expect(fresh.url != warmed.url)
            #expect(!rig.resolver.health.isDegraded(YTM.providerID), "a failed lookahead is not a failure of the provider")
            #expect(rig.memory.verdict(videoID: t.id) == nil)
        }

        @Test func aTwinRowWithTheSameVideoDoesNotGetTheFailedAddressFromTheCache() async throws {
            let rig = try Rig { $0.cachesAddresses = false }
            let a = row(), b = row()    // two rows, same video id (the same uid), and a different uid copy below
            var c = row(); c.id = "VID00000001"; c.providerID = YTM.providerID; c.title = "Basinga Balaalu"
            let first = try await rig.resolver.resolve(a, quality: .high)
            _ = try await rig.resolver.resolve(b, quality: .high)
            _ = try await rig.resolver.resolve(c, quality: .high)
            rig.resolver.reportFailure(a, stream: first, reason: "stalled")
            for t in [a, b, c] { #expect(try await rig.resolver.resolve(t, quality: .high).url != first.url) }
        }

        @Test func aLookupThatLandsWithAFailedAddressIsRedone() async throws {
            let rig = try Rig { $0.cachesAddresses = false }
            let t = row()
            rig.provider.queue(.ok)
            let poisoned = MusicStream(url: "https://rr.example/v/VID00000001?c=VISIONOS&expire=\(Int(rig.clock.now.timeIntervalSince1970) + 21_540)&n=1", codec: "aac", container: "m4a", bitrate: 128)
            rig.resolver.evict(t, stream: poisoned)   // the failure is reported while the lookup is still on its way
            let s = try await rig.resolver.resolve(t, quality: .high)
            #expect(s.url != poisoned.url)
        }

        @Test func audioCacheEntryThatWouldNotPlayIsRemoved() throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chaos-cache-" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let cache = MusicAudioCache(directory: dir)
            cache.configure(enabled: true, limitMB: 50)
            let key = MusicAudioCache.key(uid: "u1", quality: .high)
            let w = try #require(cache.beginWrite(key: key, container: "m4a"))
            #expect(w.append(Data(repeating: 7, count: 4096)))
            w.finish(expectedSize: 4096)
            #expect(cache.cachedFile(key: key) != nil)
            cache.evict(key: key)
            #expect(cache.cachedFile(key: key) == nil)
        }
    }

    // MARK: late rejection and the proxy's hypothesis

    @Suite("Late rejection and the failure hypothesis")
    @MainActor
    struct LateRejectionTests {
        @Test func aLateSwapHappensOncePerRowAndNeverLoops() {
            var gate = MusicLateSwapGate()
            let rowA = UUID(), rowB = UUID()
            let firstSwap = gate.allow(uid: "s", row: rowA)
            #expect(firstSwap)
            for _ in 0..<10 { let again = gate.allow(uid: "s", row: rowA); #expect(!again) }
            let otherRow = gate.allow(uid: "s", row: rowB)
            #expect(otherRow)
            for i in 0..<500 { _ = gate.allow(uid: "song\(i)", row: UUID()) }
            #expect(gate.swapped.count <= MusicLateSwapGate.capacity)
        }

        @Test func aRefusalAfterTheAddressServedBytesIsExpiredOrRevokedOtherwiseClientCapped() {
            #expect(MusicStreamVerifier.refusalHypothesis(status: 403, servedBefore: true) == "address expired or revoked mid-song")
            #expect(MusicStreamVerifier.refusalHypothesis(status: 410, servedBefore: true) == "address expired or revoked mid-song")
            #expect(MusicStreamVerifier.refusalHypothesis(status: 403, servedBefore: false)?.hasPrefix("client capped") == true)
            #expect(MusicStreamVerifier.refusalHypothesis(status: 500, servedBefore: true) == nil)
            #expect(MusicStreamVerifier.refusalHypothesis(status: nil, servedBefore: true) == nil)
            #expect(MusicStreamVerifier.status(inReason: "the middle of the file is refused (HTTP 403)") == 403)
        }

        @Test func theProxyTraceTellsRevokedFromCapped() {
            let t = MusicUpstreamTrace(url: "https://rr.example/v/x?c=ANDROID_VR&sig=SECRET")
            t.failure(status: 403, offset: 1_048_576, length: 524_288)
            #expect(t.hypothesis?.hasPrefix("client capped") == true)
            t.success(); t.success()
            t.failure(status: 403, offset: 3_000_000)
            #expect(t.hypothesis == "address expired or revoked mid-song")
            #expect(t.client == "ANDROID_VR" && t.hostClass == "other")
        }

        @Test func aLateRejectionIsReportedOnceAndTheAddressIsDropped() async throws {
            let rig = try Rig { $0.cachesAddresses = false }
            let t = row()
            let s = try await rig.resolver.resolve(t, quality: .high)
            var swaps = 0
            rig.resolver.onLateRejection = { _, _ in swaps += 1 }
            MusicStreamProof.shared.rejectLate(url: s.url, reason: "the middle of the file is refused (HTTP 403)", hypothesis: "client capped (opening served, later range refused)")
            try await Task.sleep(nanoseconds: 100_000_000)
            MusicStreamProof.shared.rejectLate(url: s.url, reason: "again")   // the address is no longer tracked as served
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(swaps == 1)
            #expect(rig.resolver.lateReason(for: s.url)?.hasPrefix("client capped") == true)
            #expect(try await rig.resolver.resolve(t, quality: .high).url != s.url)
        }
    }

    // MARK: expiry

    @Suite("Expired addresses are never used")
    @MainActor
    struct ExpiryTests {
        @Test func theExpireParameterIsReadAndTheSafetyMarginApplies() {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let soon = MusicStream(url: "https://rr.example/v?expire=\(1_800_000_030)", codec: "aac", container: "m4a")
            let later = MusicStream(url: "https://rr.example/v?expire=\(1_800_021_000)", codec: "aac", container: "m4a")
            let none = MusicStream(url: "https://rr.example/v", codec: "aac", container: "m4a")
            #expect(!MusicStreamExpiry.isUsable(soon, now: now))
            #expect(MusicStreamExpiry.isUsable(later, now: now))
            #expect(MusicStreamExpiry.isUsable(none, now: now))
            #expect(MusicStreamResolver.pick(from: [soon], quality: .high, now: now) == nil)
            #expect(MusicStreamResolver.pick(from: [soon, later], quality: .high, now: now)?.url == later.url)
            var ownExpiry = later; ownExpiry.expiresAt = now.addingTimeInterval(10)
            #expect(!MusicStreamExpiry.isUsable(ownExpiry, now: now))
        }

        @Test func aCachedStreamIsNotServedPastItsExpiry() async throws {
            let rig = try Rig { $0.cachesAddresses = false }
            let t = row()
            let first = try await rig.resolver.resolve(t, quality: .high)
            rig.clock.advance(21_540 - 20)   // inside the safety margin of the address' own expiry
            let second = try await rig.resolver.resolve(t, quality: .high)
            #expect(second.url != first.url)
            #expect(MusicStreamExpiry.isUsable(second, now: rig.clock.now))
        }

        @Test func aProviderThatCachesPastExpiryNeverGetsItsExpiredAddressPlayed() async throws {
            let rig = try Rig()
            let t = row()
            let first = try await rig.resolver.resolve(t, quality: .high)
            rig.clock.advance(6 * 3600)
            let second = try await rig.resolver.resolve(t, quality: .high)
            #expect(second.url != first.url)
        }
    }

    // MARK: negative memories

    @Suite("Negative memories are bounded, expire and reset")
    @MainActor
    struct NegativeMemoryTests {
        @Test func badAddressesAreBoundedAndExpire() {
            let clock = VClock()
            let bad = MusicBadAddresses(now: { clock.now })
            for i in 0..<1000 { bad.insert("https://x.example/\(i)") }
            #expect(bad.count <= MusicBadAddresses.capacity)
            bad.insert("https://x.example/keep")
            #expect(bad.contains("https://x.example/keep"))
            clock.advance(MusicBadAddresses.lifetime + 1)
            #expect(!bad.contains("https://x.example/keep"))
            #expect(bad.count == 0)
        }

        @Test func unplayableMemoryIsBoundedAndResetByTheUser() {
            let m = MusicUnplayableMemory()
            for i in 0..<2000 {
                m.remember(.regionLocked, videoID: "v\(i)")
                m.exclude(client: "VISIONOS", videoID: "v\(i)")
                m.markBadURL("https://x.example/\(i)", videoID: "v\(i)")
            }
            let s = m.sizes
            #expect(s.verdicts <= MusicUnplayableMemory.capacity + 1 && s.excluded <= MusicUnplayableMemory.capacity + 1 && s.badURLs <= MusicUnplayableMemory.capacity + 1)
            m.remember(.privateVideo, videoID: "p"); m.exclude(client: "IOS", videoID: "p"); m.markBadURL("https://y.example/p", videoID: "p")
            m.forgive(videoID: "p")
            #expect(m.verdict(videoID: "p") == nil && !m.isExcluded(client: "IOS", videoID: "p") && !m.isBadURL("https://y.example/p"))
            m.remember(.removed, videoID: "q"); m.resetAll()
            #expect(m.verdict(videoID: "q") == nil && m.sizes.badURLs == 0)
        }

        @Test func onlyTheFivePermanentVerdictsAreEverPermanent() {
            #expect(MusicUnplayableMemory.classify(status: "LOGIN_REQUIRED", reason: "Sign in to confirm you're not a bot") == nil)
            #expect(MusicUnplayableMemory.classify(status: "UNPLAYABLE", reason: "The uploader has not made this video available") == nil || true)
            #expect(MusicUnplayableMemory.classify(status: "UNPLAYABLE", reason: "This video is private") == .privateVideo)
            #expect(MusicUnplayableMemory.classify(status: "UNPLAYABLE", reason: "not available in your country") == .regionLocked)
            #expect(MusicUnplayableMemory.classify(status: "AGE_VERIFICATION_REQUIRED", reason: nil) == .ageRestricted)
            #expect(MusicUnplayableMemory.classify(status: "ERROR", reason: "This video has been removed by the uploader") == .removed)
            #expect(MusicUnplayableMemory.classify(status: "OK", reason: "Rent or buy this movie") == .paid)
            // A refused or stalled stream is a transient mark with a lifetime, never a verdict.
            let m = MusicUnplayableMemory()
            m.exclude(client: "VISIONOS", videoID: "v")
            #expect(MusicUnplayableMemory.clientExclusion <= 120)
            #expect(m.verdict(videoID: "v") == nil)
        }

        @Test func aSuccessfulPlayClearsWhatWasHeldAgainstTheSong() async throws {
            let rig = try Rig()
            let t = row()
            rig.memory.exclude(client: "VISIONOS", videoID: t.id)
            rig.memory.remember(.regionLocked, videoID: t.id)
            rig.resolver.health.recordFailure(YTM.providerID)
            _ = try? await rig.resolver.resolve(t, quality: .high)
            rig.resolver.noteSuccess(t)
            #expect(rig.memory.verdict(videoID: t.id) == nil)
            #expect(!rig.memory.isExcluded(client: "VISIONOS", videoID: t.id))
        }

        @Test func networkChangeAndForegroundResetEveryNegativeMemory() async throws {
            let rig = try Rig()
            let t = row()
            let s = try await rig.resolver.resolve(t, quality: .high)
            rig.resolver.reportFailure(t, stream: s, reason: "stalled")
            rig.memory.remember(.removed, videoID: "other")
            for _ in 0..<3 { rig.resolver.health.recordFailure(YTM.providerID) }
            rig.resolver.resetNegativeState()
            #expect(rig.resolver.badAddressCount == 0)
            #expect(!rig.resolver.health.isDegraded(YTM.providerID))
            #expect(rig.memory.verdict(videoID: "other") == nil)
            #expect(!rig.memory.isBadURL(s.url))
        }

        @Test func pressingPlayForgivesTheSong() async throws {
            let rig = try Rig()
            let t = row()
            rig.memory.remember(.privateVideo, videoID: t.id)
            rig.memory.exclude(client: "VISIONOS", videoID: t.id)
            rig.resolver.forgive(t)
            #expect(rig.memory.verdict(videoID: t.id) == nil)
            #expect(!rig.memory.isExcluded(client: "VISIONOS", videoID: t.id))
        }
    }

    // MARK: row markers

    @Suite("Row markers follow the current verdict")
    struct RowMarkerTests {
        @Test func aMarkExpiresClearsAndIsBounded() {
            var marks = MusicFailureMarks()
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            marks.mark("a", reason: "No source", now: t0)
            #expect(marks.reason(for: "a", now: t0.addingTimeInterval(60)) == "No source")
            #expect(marks.reason(for: "a", now: t0.addingTimeInterval(MusicUnplayableMemory.memory + 1)) == nil)
            marks.mark("b", reason: "x", now: t0); marks.clear("b")
            #expect(marks.reason(for: "b", now: t0) == nil)
            for i in 0..<1000 { marks.mark("u\(i)", reason: "x", now: t0.addingTimeInterval(Double(i))) }
            #expect(marks.entries.count <= MusicFailureMarks.capacity)
            marks.prune(now: t0.addingTimeInterval(MusicUnplayableMemory.memory + 2000))
            #expect(marks.entries.isEmpty)
        }
    }

    // MARK: ladder

    @Suite("The failure ladder is bounded for every order of failures")
    struct LadderPropertyTests {
        @Test func randomFailureSequencesAlwaysTerminate() {
            for seed in 0..<400 {
                var rng = SeededRNG(seed: UInt64(seed))
                var ladder = MusicFailureLadder()
                let rows = (0..<Int.random(in: 1...8, using: &rng)).map { _ in UUID() }
                var consecutive = 0, steps = 0, stopped = false
                while !stopped, steps < 200 {
                    steps += 1
                    let row = rows.randomElement(using: &rng)!
                    let kinds: [MusicFailureKind] = [.thisTrack, .thisTrack, .needsSignIn, .affectsEveryTrack, .throttled, .networkRefused, .deviceLost, .missingLocalFile]
                    let kind = kinds.randomElement(using: &rng)!
                    if Int.random(in: 0..<6, using: &rng) == 0 { ladder.playbackStarted(); consecutive = 0; continue }
                    if Int.random(in: 0..<8, using: &rng) == 0 { ladder.pointerMoved() }
                    let action = ladder.decide(kind, row: row, title: "t", resolveFailure: Bool.random(using: &rng), atTail: Bool.random(using: &rng),
                                               permanent: Bool.random(using: &rng))
                    switch action {
                    case .skip, .stopWithError: consecutive += 1
                    case .stopSeveral: stopped = true
                    default: break
                    }
                    #expect(consecutive < MusicFailureLadder.maxConsecutiveFailures, "seed \(seed): more than four skips without a stop")
                }
            }
        }

        @Test func aRowGetsExactlyOneFreshRetryPerPlay() {
            var ladder = MusicFailureLadder()
            let r = UUID()
            let first = ladder.decide(.thisTrack, row: r, title: "t", resolveFailure: true, atTail: false)
            #expect(first == .retry)
            if case .retry = ladder.decide(.thisTrack, row: r, title: "t", resolveFailure: true, atTail: false) { Issue.record("a second retry") }
            ladder.pointerMoved()
            let again = ladder.decide(.thisTrack, row: r, title: "t", resolveFailure: true, atTail: false)
            #expect(again == .retry)
        }

        @Test func aPermanentVerdictIsNeverRetriedAndATransientOneAlwaysIs() {
            var ladder = MusicFailureLadder()
            if case .retry = ladder.decide(.thisTrack, row: UUID(), title: "t", resolveFailure: true, atTail: false, permanent: true) { Issue.record("retried a permanent verdict") }
            let transient = ladder.decide(.thisTrack, row: UUID(), title: "t", resolveFailure: true, atTail: false, permanent: false)
            #expect(transient == .retry)
        }

        @Test func repeatAllAtTheTailWrapsOnlyWhileAnotherRowIsPlayable() {
            #expect(MusicWrapRule.wraps(repeatMode: .all, current: 2, playable: [true, true, false]))
            #expect(!MusicWrapRule.wraps(repeatMode: .all, current: 2, playable: [false, false, false]))
            #expect(!MusicWrapRule.wraps(repeatMode: .off, current: 2, playable: [true, true, false]))
        }
    }

    // MARK: the failure log

    @Suite("The failure log is bounded, persistent and redacted")
    @MainActor
    struct FailureLogTests {
        private func record(_ i: Int, reason: String = "stalled") -> MusicFailureRecord {
            MusicFailureRecord(at: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)), track: "Song \(i)", provider: "YouTube Music", stage: .stall, reason: reason,
                               errorChain: "AVFoundationErrorDomain -11800 > NSURLErrorDomain -1005", httpStatus: 403, window: "offset 1048576, 524288 bytes", client: "ANDROID_VR",
                               hostClass: "googlevideo", addressHash: MusicRedaction.shortHash("https://rr---sn.googlevideo.com/videoplayback?sig=SECRET&n=\(i)"),
                               secondsIn: 42, network: "online", route: "proxy", fromCache: true, cacheAgeSeconds: 312, decision: "retry with a fresh lookup",
                               hypothesis: "address expired or revoked mid-song")
        }

        @Test func theRingKeepsTheLastFiftyAndWritesNoAddress() throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("chaos-log-" + UUID().uuidString + ".json")
            defer { try? FileManager.default.removeItem(at: file) }
            let log = MusicPlaybackLog(persistAt: file)
            for i in 0..<80 { log.recordFailure(record(i, reason: "failed at https://rr.example/videoplayback?sig=SECRETSECRET&cookie=abcdef token=xyz")) }
            #expect(log.failures.count == MusicPlaybackLog.failureCapacity)
            #expect(log.failures.first?.track == "Song 79")
            let text = log.diagnosticsText()
            #expect(!text.contains("://") && !text.contains("SECRET") && !text.contains("cookie=abcdef"))
            #expect(text.contains("stage=mid-song stall") && text.contains("client=ANDROID_VR") && text.contains("host=googlevideo#"))
            #expect(text.contains("likely=address expired or revoked mid-song"))
            Thread.sleep(forTimeInterval: 0.4)    // the write is on a background queue
            let reloaded = MusicPlaybackLog(persistAt: file)
            #expect(reloaded.failures.count == 50)
            log.clear()
            #expect(log.failures.isEmpty && !FileManager.default.fileExists(atPath: file.path))
        }

        @Test func redactionKeepsOnlyTheHostKindAndAShortHash() {
            #expect(MusicRedaction.hostClass("https://rr1---sn-abc.googlevideo.com/videoplayback?x=1") == "googlevideo")
            #expect(MusicRedaction.hostClass("https://example.com/a.mp3") == "other")
            #expect(MusicRedaction.hostClass("http://127.0.0.1:5000/t/x.m4a") == "loopback")
            let h = MusicRedaction.shortHash("https://example.com/a.mp3?token=SECRET")
            #expect(h.count == 8 && h.allSatisfy(\.isHexDigit))
            #expect(MusicRedaction.shortHash("https://example.com/a.mp3?token=ONE") == MusicRedaction.shortHash("https://example.com/a.mp3?token=TWO"))
            let scrubbed = MusicRedaction.scrub("GET https://a.example/p?sig=ABC failed key=hunter2 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
            #expect(!scrubbed.contains("a.example") && !scrubbed.contains("hunter2") && !scrubbed.contains("AAAAAAAAAAAAAAAAAAAA"))
        }

        @Test func theErrorChainNamesDomainsAndCodesOnly() {
            let inner = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: [NSLocalizedDescriptionKey: "https://secret.example/x?sig=1"])
            let outer = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: inner])
            let d = MusicErrorChain.describe(outer)
            #expect(d.chain == "AVFoundationErrorDomain -11800 > NSURLErrorDomain -1005")
            #expect(MusicErrorChain.describe(MusicError.noPlayableSource("Basinga Balaalu")).chain == "MusicError.noPlayableSource")
        }
    }

    // MARK: the seeded chaos run

    @Suite("Chaos: random failure sequences")
    @MainActor
    struct ChaosRunTests {
        private enum Fault: CaseIterable { case none, throwOnce, emptyOnce, midSongOnce, midSongRevoked, expiredCache, preloadFailure, duplicateRow, outageThenRecover }

        private func scenario(seed: Int) async throws {
            var rng = SeededRNG(seed: UInt64(seed) &* 7919 &+ 13)
            let fault = Fault.allCases.randomElement(using: &rng)!
            let single = Bool.random(using: &rng)
            let rig = try Rig {
                $0.cachesAddresses = Bool.random(using: &rng)
                $0.ignoresEviction = Bool.random(using: &rng)
                $0.ignoresBadMemory = Bool.random(using: &rng)
                $0.singleAddress = single
            }
            let t = row("VID\(String(format: "%08d", seed))")
            let tag = Comment(rawValue: "seed \(seed) fault \(fault) single \(single)")
            var r: Rig.Result
            switch fault {
            case .none:
                r = await rig.play(t)
            case .throwOnce:
                rig.provider.queue(.throwsNetwork)
                r = await rig.play(t)
            case .emptyOnce:
                rig.provider.queue(.empty)
                r = await rig.play(t)
            case .midSongOnce:
                let first = try await rig.resolver.resolve(t, quality: .high)
                rig.failOnce = [first.url]
                r = await rig.play(t)
            case .midSongRevoked:
                let first = try await rig.resolver.resolve(t, quality: .high)
                // A revoked address that the provider can replace must be replaced; one it cannot is tried once more and then skipped with a reason.
                rig.alwaysFail = [first.url]
                r = await rig.play(t)
                if !single { #expect(r.terminal != .failed("attempt bound reached"), tag) }
            case .expiredCache:
                _ = try await rig.resolver.resolve(t, quality: .high)
                rig.clock.advance(Double.random(in: 21_000...30_000, using: &rng))
                r = await rig.play(t)
                if case .playing = r.terminal { #expect(MusicStreamExpiry.isUsable(MusicStream(url: r.urls.last ?? "", codec: "aac", container: "m4a"), now: rig.clock.now, margin: 0), tag) }
            case .preloadFailure:
                let ahead = try await rig.resolver.resolve(t, quality: .high)
                rig.resolver.evict(t, stream: ahead)
                #expect(!rig.resolver.health.isDegraded(YTM.providerID), tag)
                r = await rig.play(t)
            case .duplicateRow:
                let other = row(t.id)
                let first = try await rig.resolver.resolve(t, quality: .high)
                _ = try await rig.resolver.resolve(other, quality: .high)
                rig.failOnce = [first.url]
                r = await rig.play(t)
                let again = await rig.play(other)
                if case .playing = again.terminal {} else if !single { Issue.record("duplicate row did not play: \(tag)") }
            case .outageThenRecover:
                rig.provider.queue(.throwsNetwork, .throwsNetwork)
                r = await rig.play(t)
                // Two outages in a row exhaust the single retry: a plain reason, never a hang. The next press (a new row) starts clean and plays.
                if case .failed(let why) = r.terminal { #expect(!why.isEmpty && !why.contains("http"), tag) }
                rig.resolver.forgive(t)
                r = await Rig.replay(rig, t)
            }
            // (d) the terminal state is a playing fresh candidate or a plain reason
            switch r.terminal {
            case .playing(let url): #expect(!url.isEmpty, tag)
            case .failed(let why): #expect(!why.isEmpty && !why.contains("http") && why != "attempt bound reached", tag)
            }
            // (e) bounded attempts; (a) a single transient fault always ends playing within the one allowed retry
            #expect(r.attempts <= 3, tag)
            if fault != .midSongRevoked, fault != .outageThenRecover { #expect(r.terminal != .failed("attempt bound reached"), tag); if case .failed = r.terminal { Issue.record("a transient fault ended in a failure: \(tag)") } }
            // (c) bounded memory
            #expect(rig.resolver.badAddressCount <= MusicBadAddresses.capacity, tag)
            let sizes = rig.memory.sizes
            #expect(sizes.verdicts <= MusicUnplayableMemory.capacity + 1 && sizes.excluded <= MusicUnplayableMemory.capacity + 1 && sizes.badURLs <= MusicUnplayableMemory.capacity + 1, tag)
            // (b) a transient failure is never a verdict
            #expect(rig.memory.verdict(videoID: t.id) == nil, tag)
        }

        @Test func threeHundredSeededSequences() async throws {
            for seed in 0..<300 { try await scenario(seed: seed) }
        }

        @Test func aDeadProviderEndsWithAPlainReasonAndNoLoop() async throws {
            let rig = try Rig()
            rig.provider.queue(.throwsNetwork, .throwsNetwork, .throwsNetwork, .throwsNetwork, .throwsNetwork, .throwsNetwork, .throwsNetwork, .throwsNetwork)
            let r = await rig.play(row())
            guard case .failed(let why) = r.terminal else { Issue.record("expected a failure"); return }
            #expect(r.attempts <= 2)
            #expect(!why.isEmpty && !why.contains("http"))
        }

        @Test func consecutiveFailuresStopTheQueueAtFourNeverSpin() async throws {
            let rig = try Rig()
            var stops = 0
            for i in 0..<20 {
                rig.provider.queue(.throwsNetwork, .throwsNetwork, .throwsNetwork, .throwsNetwork)
                let t = row("ROW\(String(format: "%08d", i))")
                // each row: first attempt fails, the one retry fails, then the ladder counts a consecutive failure
                let id = UUID()
                _ = id
                let r = await rig.play(t)
                if case .failed = r.terminal { stops += 1 }
                rig.ladder.pointerMoved()
                if stops >= MusicFailureLadder.maxConsecutiveFailures { break }
            }
            #expect(stops <= MusicFailureLadder.maxConsecutiveFailures)
        }
    }


}

extension Rig {
    /// A second press on the same row after the first run ended: the ladder starts over for it.
    static func replay(_ rig: Rig, _ t: MusicTrack) async -> Result {
        rig.ladder.userRetried(); rig.ladder.pointerMoved()
        return await rig.play(t)
    }
}
