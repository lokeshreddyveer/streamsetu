import Testing
import AVFoundation
import Foundation
@testable import REDDY

// MARK: Helpers

private func track(_ id: String, seconds: Double = 200) -> REDDY.MusicTrack {
    REDDY.MusicTrack(id: id, providerID: "p", title: id, durationMs: Int64(seconds * 1000), artists: [])
}

private func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("karaoke-tests-" + UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// A small transform that behaves like the real ones, so tests stay quick.
private let smallConfig = MusicSTFTConfig(nFFT: 2048, hop: 512, dimF: 1024, dimT: 64, compensate: 1.0)

private func sine(_ hz: Double, frames: Int, rate: Double = 44_100, amplitude: Float = 0.5) -> [Float] {
    (0..<frames).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / rate)) }
}

private func rms(_ a: [Float]) -> Double {
    guard !a.isEmpty else { return 0 }
    return (a.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(a.count)).squareRoot()
}

/// Returns the spectrogram unchanged: the model slot with nothing in it.
private struct IdentityModel: MusicStemModel {
    var layout: MusicStemLayout
    func separate(_ tensor: [Float]) throws -> [Float] { tensor }
}

/// Collects what the engine emits and checks every frame arrives exactly once.
private final class Collector {
    var left: [Float]; var right: [Float]; var seen: [Int]
    init(_ n: Int) { left = [Float](repeating: 0, count: n); right = left; seen = [Int](repeating: 0, count: n) }
    func put(_ start: Int, _ l: [Float], _ r: [Float]) {
        for i in 0..<l.count { left[start + i] = l[i]; right[start + i] = r[i]; seen[start + i] += 1 }
    }
}

// MARK: STFT

@Suite struct MusicSTFTTests {
    @Test func tierConfigsMatchThePublishedValues() {
        let l = MusicKaraokeTier.light.config, b = MusicKaraokeTier.balanced.config, h = MusicKaraokeTier.best.config
        #expect(l.nFFT == 6144 && l.dimF == 2048 && l.compensate == 1.035)
        #expect(b.nFFT == 5120 && b.dimF == 2048 && b.compensate == 1.025)
        #expect(h.nFFT == 6144 && h.dimF == 3072 && h.compensate == 1.022)
        #expect(l.chunk == 261_120 && l.gen == 254_976 && l.step == 254_976 && l.tensorCount == 4 * 2048 * 256)
        #expect(b.gen == 256_000 && b.step == 256_000)
        #expect(MusicKaraokeTier.light.stem == .vocals && MusicKaraokeTier.balanced.stem == .instrumental)
        #expect(MusicKaraokeTier.from(key: "nonsense") == .light)
        #expect(MusicKaraokeTier.allCases.allSatisfy { $0.config.isValid })
    }

    @Test func roundTripReconstructsASine() throws {
        let stft = try #require(MusicSTFT(config: smallConfig))
        let x = sine(1000, frames: smallConfig.chunk)
        let spec = stft.forward(x)
        let y = stft.inverse(re: spec.re, im: spec.im)
        #expect(y.count == x.count)
        var worst: Float = 0
        for i in 0..<x.count { worst = max(worst, abs(x[i] - y[i])) }
        #expect(worst < 1e-3)
    }

    @Test func roundTripOnTheLightTierSizes() throws {
        let cfg = MusicKaraokeTier.light.config
        let stft = try #require(MusicSTFT(config: cfg))
        let x = sine(440, frames: cfg.chunk, amplitude: 0.8)
        let spec = stft.forward(x)
        let y = stft.inverse(re: spec.re, im: spec.im)
        var worst: Float = 0
        for i in 0..<x.count { worst = max(worst, abs(x[i] - y[i])) }
        #expect(worst < 1e-3)
    }

    @Test func tensorLayoutAndLowBinsForcedToZero() throws {
        let stft = try #require(MusicSTFT(config: smallConfig))
        let spec = stft.forward(sine(1000, frames: smallConfig.chunk))
        let t = stft.tensor(left: spec, right: spec)
        #expect(t.count == smallConfig.tensorCount)
        let frames = smallConfig.dimT
        // Bins 0...2 of the left real plane are zero, and a mid bin carries the tone.
        #expect((0..<(3 * frames)).allSatisfy { t[$0] == 0 })
        let bin = Int((1000.0 / 44_100.0 * Double(smallConfig.nFFT)).rounded())
        #expect(abs(t[bin * frames + frames / 2]) > 1)
        // Right real plane is the second stereo plane: index (2 * dimF + f) * dimT + t.
        #expect(t[(2 * smallConfig.dimF + bin) * frames + frames / 2] == t[bin * frames + frames / 2])
        // spectra(from:) puts the rows back and leaves the rest zero.
        let back = stft.spectra(from: t)
        #expect(back.left.re.count == smallConfig.bins * frames)
        #expect(back.left.re[smallConfig.dimF * frames] == 0)
    }

    @Test func reflectionDoesNotRepeatTheEdge() {
        let p = MusicSTFT.reflectPadded([1, 2, 3, 4, 5], by: 2)
        #expect(p == [3, 2, 1, 2, 3, 4, 5, 4, 3])
    }

    @Test func unsupportedSizesAreRejected() {
        #expect(MusicSTFTConfig.isSupportedFFTSize(6144) && MusicSTFTConfig.isSupportedFFTSize(5120))
        #expect(!MusicSTFTConfig.isSupportedFFTSize(7000))
        #expect(MusicSTFT(config: MusicSTFTConfig(nFFT: 7000, hop: 512, dimF: 100, dimT: 64, compensate: 1)) == nil)
    }
}

// MARK: Chunks and the whole engine

@Suite struct MusicChunkPlanTests {
    @Test func chunkListCoversTheSongWithOneWindowOfOverlap() {
        let cfg = MusicKaraokeTier.light.config
        let length = 44_100 * 30
        let plan = MusicChunkPlan(config: cfg, length: length)
        #expect(plan.pad == cfg.gen + cfg.trim - (length % cfg.gen))
        #expect(plan.mixtureLength == cfg.trim + length + plan.pad)
        #expect(plan.chunks.first?.lowerBound == 0)
        #expect(plan.chunks.last?.upperBound == plan.mixtureLength)
        #expect(plan.chunks.allSatisfy { $0.count <= cfg.chunk })
        for (a, b) in zip(plan.chunks, plan.chunks.dropFirst()) {
            #expect(b.lowerBound - a.lowerBound == cfg.step)
            #expect(a.upperBound - b.lowerBound == cfg.nFFT)   // overlap is exactly one FFT window
        }
        // The song itself sits inside the chunk list with no gap.
        var covered = 0
        for p in cfg.trim..<(cfg.trim + length) where p % 997 == 0 { if plan.chunks.contains(where: { $0.contains(p) }) { covered += 1 } }
        #expect(covered == (cfg.trim..<(cfg.trim + length)).filter { $0 % 997 == 0 }.count)
    }

    @Test func orderStartsWhereYouAreAndWraps() {
        let plan = MusicChunkPlan(config: MusicKaraokeTier.light.config, length: 44_100 * 60)
        #expect(plan.order(startingAt: 0).first == 0)
        let o = plan.order(startingAt: 44_100 * 30)
        let first = o[0]
        #expect(first > 0)
        #expect(plan.chunks[first].contains(44_100 * 30 + plan.config.trim))
        #expect(Array(o.dropFirst(o.count - first)) == Array(0..<first))
        #expect(Set(o).count == plan.chunks.count)
    }

    @Test func blendWindowIsHannAndSingleSampleIsOne() {
        #expect(MusicChunkPlan.blendWindow(1) == [1])
        let w = MusicChunkPlan.blendWindow(5)
        #expect(w[0] == 0 && w[4] < 1e-6 && abs(w[2] - 1) < 1e-6)
    }

    @Test func identityModelKeepsATone() throws {
        let frames = 44_100 * 2
        let tone = sine(440, frames: frames)
        let src = MusicArrayPCMSource(left: tone, right: tone)
        let out = Collector(frames)
        var reports = 0
        try MusicSeparationEngine.run(source: src, model: IdentityModel(layout: MusicStemLayout(stft: smallConfig, stem: .instrumental)),
                                      progress: { _, _ in reports += 1 }, emit: out.put)
        #expect(out.seen.allSatisfy { $0 == 1 })
        #expect(reports == MusicChunkPlan(config: smallConfig, length: frames).chunks.count)
        let err = zip(out.left, tone).map { $0 - $1 }
        #expect(rms(err) < 0.01)
    }

    @Test func vocalsStemSubtractsFromTheMixture() throws {
        let frames = 44_100
        let tone = sine(440, frames: frames)
        let out = Collector(frames)
        try MusicSeparationEngine.run(source: MusicArrayPCMSource(left: tone, right: tone),
                                      model: IdentityModel(layout: MusicStemLayout(stft: smallConfig, stem: .vocals)), emit: out.put)
        // The identity "vocals" are the whole song, so nothing is left.
        #expect(out.seen.allSatisfy { $0 == 1 })
        #expect(rms(out.left) < 0.01)
    }

    @Test func startingMidSongStillEmitsEverythingOnce() throws {
        let frames = 44_100 * 3
        let tone = sine(300, frames: frames)
        let out = Collector(frames)
        var firstEmit: Range<Int>?
        try MusicSeparationEngine.run(source: MusicArrayPCMSource(left: tone, right: tone),
                                      model: IdentityModel(layout: MusicStemLayout(stft: smallConfig, stem: .instrumental)),
                                      startingAt: 44_100 * 2) { s, l, r in
            if firstEmit == nil { firstEmit = s..<(s + l.count) }
            out.put(s, l, r)
        }
        #expect(out.seen.allSatisfy { $0 == 1 })
        #expect(firstEmit?.contains(44_100 * 2) == true)   // the first thing written holds the playhead, not frame 0
    }

    @Test func cancellationStops() {
        let frames = 44_100
        let tone = sine(300, frames: frames)
        #expect(throws: MusicKaraokeFailure.cancelled) {
            try MusicSeparationEngine.run(source: MusicArrayPCMSource(left: tone, right: tone),
                                          model: IdentityModel(layout: MusicStemLayout(stft: smallConfig, stem: .instrumental)),
                                          isCancelled: { true }, emit: { _, _, _ in })
        }
    }
}

// MARK: The 15-minute rule

@Suite struct MusicKaraokeLimitTests {
    @Test func knownDurationOverTheCapIsNeverQueued() {
        #expect(MusicKaraokeLimits.isQueueable(durationMs: 900_000))
        #expect(!MusicKaraokeLimits.isQueueable(durationMs: 900_001))
        #expect(MusicKaraokeLimits.isQueueable(durationMs: 0))   // unknown duration: decided after decoding
    }

    @Test func decodedLengthCheck() {
        #expect(!MusicKaraokeLimits.decodedTooLong(frames: 44_100 * 900, sampleRate: 44_100))
        #expect(MusicKaraokeLimits.decodedTooLong(frames: 44_100 * 900 + 1, sampleRate: 44_100))
        #expect(MusicKaraokeLimits.decodeStopSeconds == MusicKaraokeLimits.maxTrackSeconds + 5)
    }

    @Test func incompleteDownloadCheck() {
        #expect(MusicKaraokeLimits.looksIncomplete(decodedSeconds: 100, expectedSeconds: 200))
        #expect(!MusicKaraokeLimits.looksIncomplete(decodedSeconds: 195, expectedSeconds: 200))   // within 90 percent
        #expect(!MusicKaraokeLimits.looksIncomplete(decodedSeconds: 5, expectedSeconds: 15))      // short songs are not checked
        #expect(!MusicKaraokeLimits.looksIncomplete(decodedSeconds: 175, expectedSeconds: 190))   // short by less than 5 s is impossible above 90 percent, still fine
    }

    @Test func prefetchSkipsLongSongsAndTakesTheNextTwo() {
        let plan = MusicKaraokeScheduler.wanted(current: track("c"), upcoming: [track("long", seconds: 1000), track("n1"), track("n2"), track("n3")])
        #expect(plan.wanted.map(\.id) == ["c", "n1", "n2"])
        #expect(plan.tooLong.map(\.id) == ["long"])
        let longNow = MusicKaraokeScheduler.wanted(current: track("big", seconds: 1200), upcoming: [track("n1")])
        #expect(longNow.wanted.map(\.id) == ["n1"] && longNow.tooLong.map(\.id) == ["big"])
    }

    @Test func separatorRefusesALongSongWithoutDoingWork() async {
        let cache = MusicKaraokeCache(directory: tempDir())
        let sep = MusicKaraokeSeparator(fetcher: NoFetch(), cache: cache, loadModel: { throw MusicKaraokeFailure.noModel })
        await #expect(throws: MusicKaraokeFailure.tooLong) {
            _ = try await sep.run(MusicKaraokeJobRequest(track: track("x", seconds: 1000), startingAt: 0, modelStem: "m"), onGrowing: { _ in }, progress: { _ in })
        }
    }

    @Test func retryLadder() {
        #expect(MusicKaraokeScheduler.retryDelay(afterFailures: 1) == 5)
        #expect(MusicKaraokeScheduler.retryDelay(afterFailures: 2) == 15)
        #expect(MusicKaraokeScheduler.retryDelay(afterFailures: 3) == 30)
        #expect(MusicKaraokeScheduler.retryDelay(afterFailures: 4) == 60)
        #expect(MusicKaraokeScheduler.retryDelay(afterFailures: 5) == nil)
        #expect(MusicKaraokeFailure.tooLong.isRetryable == false)
    }

    @Test func cacheLimitIsClamped() {
        #expect(MusicKaraokeLimits.clampCacheLimitMB(10) == 512)
        #expect(MusicKaraokeLimits.clampCacheLimitMB(50_000) == 20_480)
        #expect(MusicKaraokeLimits.clampCacheLimitMB(2_048) == 2_048)
    }
}

private struct NoFetch: MusicKaraokeAudioFetching {
    func localAudio(for track: REDDY.MusicTrack, into directory: URL, isCancelled: @Sendable () -> Bool) async throws -> (url: URL, isTemporary: Bool) {
        throw MusicKaraokeFailure.failed
    }
}

// MARK: Cache

@Suite struct MusicKaraokeCacheTests {
    @Test func namingIsStableAndCollisionFree() {
        #expect(MusicKaraokeNaming.fnv1a("") == 0xcbf29ce484222325)
        #expect(MusicKaraokeNaming.fnv1a("a") == 0xaf63dc4c8601ec8c)
        let a = MusicKaraokeNaming.sanitised("a/b"), b = MusicKaraokeNaming.sanitised("a_b")
        #expect(a != b)
        #expect(a.hasPrefix("a_b-") && b.hasPrefix("a_b-"))
        let long = MusicKaraokeNaming.sanitised(String(repeating: "x", count: 150))
        #expect(long.count == 16 + 1 + 8)
        #expect(MusicKaraokeNaming.sanitised("").count == 16 + 1 + 8)
    }

    @Test func leastRecentlyUsedGoesFirstAndProtectedStay() {
        func e(_ n: String, _ t: Double) -> MusicKaraokeCache.Entry {
            MusicKaraokeCache.Entry(url: URL(fileURLWithPath: "/c/\(n).flac"), size: 100, modified: Date(timeIntervalSince1970: t))
        }
        let all = [e("c", 3), e("a", 1), e("b", 2)]
        #expect(MusicKaraokeCache.evictionPlan(entries: all, limitBytes: 250, protected: []).map { $0.lastPathComponent } == ["a.flac"])
        #expect(MusicKaraokeCache.evictionPlan(entries: all, limitBytes: 100, protected: []).map { $0.lastPathComponent } == ["a.flac", "b.flac"])
        #expect(MusicKaraokeCache.evictionPlan(entries: all, limitBytes: 100, protected: [all[1].url]).map { $0.lastPathComponent } == ["b.flac", "c.flac"])
        #expect(MusicKaraokeCache.evictionPlan(entries: all, limitBytes: 1_000, protected: []).isEmpty)
    }

    @Test func lookupTouchesAndZeroByteFilesMiss() throws {
        let cache = MusicKaraokeCache(directory: tempDir())
        let stem = cache.stem(modelStem: "m", trackID: "t1")
        let file = stem.appendingPathExtension("flac")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        #expect(cache.lookup(modelStem: "m", trackID: "t1") == nil)
        try Data(repeating: 1, count: 64).write(to: file)
        let old = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        #expect(cache.lookup(modelStem: "m", trackID: "t1") == file)
        let modified = try #require(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        #expect(modified > old)
        #expect(cache.lookup(modelStem: "other", trackID: "t1") == nil)   // a different model never hits
    }

    @Test func pinnedFilesSurviveClear() throws {
        let cache = MusicKaraokeCache(directory: tempDir())
        let a = cache.stem(modelStem: "m", trackID: "a").appendingPathExtension("flac")
        let b = cache.stem(modelStem: "m", trackID: "b").appendingPathExtension("flac")
        try Data(repeating: 1, count: 10).write(to: a); try Data(repeating: 1, count: 10).write(to: b)
        cache.pin(a)
        #expect(cache.isPinned(a))
        #expect(cache.clear() == 1)
        #expect(FileManager.default.fileExists(atPath: a.path) && !FileManager.default.fileExists(atPath: b.path))
        cache.unpin(a)
        #expect(!cache.isPinned(a))
        #expect(cache.clear() == 1)
        #expect(cache.usedBytes == 0)
    }

    @Test func crashLeftoversAreRemovedAtStart() throws {
        let dir = tempDir()
        let c1 = MusicKaraokeCache(directory: dir)
        let leftover = c1.tempDirectory.appendingPathComponent("half.wav")
        try Data(repeating: 1, count: 10).write(to: leftover)
        try Data(repeating: 1, count: 10).write(to: dir.appendingPathComponent("x.flac.tmp"))
        _ = MusicKaraokeCache(directory: dir)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("x.flac.tmp").path))
    }

    @Test func coverageMergesAndMeasuresAhead() {
        var c = MusicFrameCoverage()
        c.insert(100..<200); c.insert(300..<400); c.insert(200..<300)
        #expect(c.ranges == [100..<400])
        #expect(c.contiguous(from: 150) == 250)
        #expect(c.contiguous(from: 50) == 0)
        c.insert(0..<100)
        #expect(c.isComplete(of: 400))
        #expect(!c.isComplete(of: 500))
    }

    @Test func growingFileTracksWrittenAudioAndRate() throws {
        let dir = tempDir()
        let g = try MusicGrowingInstrumental(url: dir.appendingPathComponent("g.wav"), totalFrames: 44_100 * 4)
        let t0 = Date(timeIntervalSince1970: 1_000)
        try g.write(startFrame: 44_100, left: [Float](repeating: 0.5, count: 44_100), right: [Float](repeating: -0.5, count: 44_100), now: t0)
        try g.write(startFrame: 88_200, left: [Float](repeating: 0.5, count: 44_100), right: [Float](repeating: -0.5, count: 44_100), now: t0.addingTimeInterval(0.5))
        #expect(g.readyAhead(of: 1) == 2)
        #expect(g.readyAhead(of: 0.5) == 0)
        // One second produced in the half second after the first write: twice real time. Before half a second passes, no rate is claimed.
        #expect(g.productionRate(now: t0.addingTimeInterval(0.2)) == 0)
        #expect(abs(g.productionRate(now: t0.addingTimeInterval(0.5)) - 2) < 0.001)
        let back = try #require(g.read(frames: 44_100..<44_102))
        #expect(back == [0.5, -0.5, 0.5, -0.5])
        #expect(g.read(frames: 0..<10) == nil)
        #expect(!g.isComplete)
    }
}

// MARK: Integrity

@Suite struct MusicKaraokeIntegrityTests {
    @Test func sha256KnownVectors() {
        #expect(MusicKaraokeIntegrity.sha256Hex(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(MusicKaraokeIntegrity.sha256Hex(of: Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func verifyChecksSizeThenHash() throws {
        let f = tempDir().appendingPathComponent("m.bin")
        try Data("abc".utf8).write(to: f)
        let good = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try MusicKaraokeIntegrity.verify(file: f, size: 3, sha256: good)
        try MusicKaraokeIntegrity.verify(file: f, size: 3, sha256: good.uppercased())
        #expect(throws: MusicKaraokeIntegrityError.sizeMismatch) { try MusicKaraokeIntegrity.verify(file: f, size: 4, sha256: good) }
        #expect(throws: MusicKaraokeIntegrityError.hashMismatch) { try MusicKaraokeIntegrity.verify(file: f, size: 3, sha256: String(repeating: "0", count: 64)) }
        #expect(throws: MusicKaraokeIntegrityError.unreadable) { try MusicKaraokeIntegrity.verify(file: f.appendingPathExtension("x"), size: 3, sha256: good) }
    }

    @Test @MainActor func catalogIsEmptyAndNothingDownloadsWithoutAYes() async {
        #expect(MusicKaraokeModelCatalog.entries.isEmpty)
        let entry = MusicKaraokeModelEntry(id: "m", name: "M", tier: .light, sizeBytes: 3,
                                           sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                                           licenseName: "L", licenseText: "text", url: URL(string: "https://example.invalid/m.mlmodel")!)
        let dl = FakeDownloader(payload: Data("abc".utf8))
        let mgr = MusicKaraokeModelManager(directory: tempDir(), catalog: [entry], downloader: dl, compile: { src, dst in
            try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: src, to: dst.appendingPathComponent("model"))
        })
        #expect(mgr.disclosure(for: entry).license.contains("text"))
        mgr.download(entry, userAgreed: false)
        #expect(!mgr.isDownloading && dl.calls == 0)
        mgr.download(entry, userAgreed: true)
        while mgr.isDownloading { try? await Task.sleep(nanoseconds: 2_000_000) }
        #expect(dl.calls == 1)
        #expect(mgr.isInstalled("m"))
        #expect(mgr.delete("m"))
        #expect(!mgr.isInstalled("m"))
    }

    @Test @MainActor func aCorruptDownloadIsRejectedAndDeleted() async {
        let entry = MusicKaraokeModelEntry(id: "bad", name: "Bad", tier: .light, sizeBytes: 3,
                                           sha256: String(repeating: "0", count: 64), licenseName: "L", licenseText: "t",
                                           url: URL(string: "https://example.invalid/b.mlmodel")!)
        let dir = tempDir()
        let mgr = MusicKaraokeModelManager(directory: dir, catalog: [entry], downloader: FakeDownloader(payload: Data("abc".utf8)), compile: { _, _ in })
        mgr.download(entry, userAgreed: true)
        while mgr.isDownloading { try? await Task.sleep(nanoseconds: 2_000_000) }
        #expect(!mgr.isInstalled("bad"))
        if case .failed = mgr.state {} else { Issue.record("expected a failed state") }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("bad.part").path))
    }
}

private final class FakeDownloader: MusicKaraokeFileDownloading, @unchecked Sendable {
    let payload: Data
    private let lock = NSLock()
    private var n = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return n }
    init(payload: Data) { self.payload = payload }
    func download(from url: URL, to destination: URL, progress: @Sendable (Int64, Int64) -> Void) async throws {
        lock.withLock { n += 1 }
        try payload.write(to: destination)
        progress(Int64(payload.count), Int64(payload.count))
    }
}

// MARK: Swap decision

@Suite struct MusicKaraokeSwapTests {
    private let url = URL(fileURLWithPath: "/tmp/inst.wav")
    private func streaming(ahead: Double, rate: Double) -> MusicKaraokeProgress {
        MusicKaraokeProgress(phase: .streaming, fileURL: url, fraction: 0.3, readyAhead: ahead, productionRate: rate)
    }

    @Test func swapsOnlyWithFiveSecondsAheadAndRateOfOnePointTwo() {
        let now = Date(timeIntervalSince1970: 5_000)
        #expect(MusicKaraokeSwapPolicy.decide(playing: .original, progress: streaming(ahead: 4.9, rate: 3), now: now) == .stay)
        #expect(MusicKaraokeSwapPolicy.decide(playing: .original, progress: streaming(ahead: 8, rate: 1.19), now: now) == .stay)
        let d = MusicKaraokeSwapPolicy.decide(playing: .original, progress: streaming(ahead: 5, rate: 1.2), now: now)
        #expect(d == .swapToInstrumental(url: url, finished: false, crossfade: MusicKaraokeSwapPolicy.crossfade))
        #expect(MusicKaraokeSwapPolicy.crossfade >= 0.05 && MusicKaraokeSwapPolicy.crossfade <= 0.1)
    }

    @Test func aFinishedFileSwapsAtOnce() {
        let done = MusicKaraokeProgress(phase: .ready, fileURL: url, fraction: 1, readyAhead: .infinity, productionRate: .infinity, isComplete: true)
        #expect(MusicKaraokeSwapPolicy.decide(playing: .original, progress: done) == .swapToInstrumental(url: url, finished: true, crossfade: MusicKaraokeSwapPolicy.crossfade))
        #expect(MusicKaraokeSwapPolicy.decide(playing: .instrumentalStream, progress: done) == .swapToInstrumental(url: url, finished: true, crossfade: MusicKaraokeSwapPolicy.crossfade))
        #expect(MusicKaraokeSwapPolicy.decide(playing: .instrumentalFile, progress: done) == .stay)
    }

    @Test func fallsBackWhenThePlayheadOutrunsTheWork() {
        let d = MusicKaraokeSwapPolicy.decide(playing: .instrumentalStream, progress: streaming(ahead: 0.3, rate: 2))
        #expect(d == .fallBackToOriginal(crossfade: MusicKaraokeSwapPolicy.crossfade))
        #expect(MusicKaraokeSwapPolicy.decide(playing: .instrumentalStream, progress: streaming(ahead: 3, rate: 2)) == .stay)
    }

    @Test func fallsBackWhenTheJobDiesOrKaraokeTurnsOff() {
        let dead = MusicKaraokeProgress(phase: .failed(.failed), fileURL: url, readyAhead: 1)
        #expect(MusicKaraokeSwapPolicy.decide(playing: .instrumentalStream, progress: dead) == .fallBackToOriginal(crossfade: MusicKaraokeSwapPolicy.crossfade))
        #expect(MusicKaraokeSwapPolicy.decide(playing: .instrumentalStream, progress: .off) == .fallBackToOriginal(crossfade: MusicKaraokeSwapPolicy.crossfade))
        #expect(MusicKaraokeSwapPolicy.decide(playing: .instrumentalFile, progress: .off) == .fallBackToOriginal(crossfade: MusicKaraokeSwapPolicy.crossfade))
    }

    @Test func cooldownAfterAFallBackUsesTheInjectedClock() {
        let t = Date(timeIntervalSince1970: 9_000)
        let ready = streaming(ahead: 10, rate: 2)
        #expect(MusicKaraokeSwapPolicy.decide(playing: .original, progress: ready, lastFallBack: t, now: t.addingTimeInterval(1)) == .stay)
        #expect(MusicKaraokeSwapPolicy.decide(playing: .original, progress: ready, lastFallBack: t, now: t.addingTimeInterval(2.5)) != .stay)
    }

    @Test func nothingHappensWithoutAModel() {
        #expect(MusicKaraokeSwapPolicy.decide(playing: .original, progress: .notSetUp) == .stay)
        #expect(MusicKaraokeStatusText.line(.notSetUp) == "Not set up")
    }

    @MainActor @Test func centreWithoutAModelDoesNothing() async {
        let defaults = UserDefaults(suiteName: "karaoke-tests-" + UUID().uuidString) ?? .standard
        let c = MusicKaraokeCenter(models: MusicKaraokeModelManager(directory: tempDir(), catalog: []),
                                   cache: MusicKaraokeCache(directory: tempDir()), defaults: defaults)
        c.setEnabled(true)
        #expect(!c.isEnabled && !c.isSetUp && c.statusText == "Not set up")
        let p = await c.instrumentalURL(for: track("a"), startingAt: 0)
        #expect(p == .notSetUp)
    }
}

// MARK: Job queue

private actor ScriptedWorker: MusicKaraokeWorking {
    var order: [String] = []
    var failFirst: Int
    var blockForever = false
    private var attempts: [String: Int] = [:]
    private let dir: URL
    init(failFirst: Int = 0, blockForever: Bool = false) { self.failFirst = failFirst; self.blockForever = blockForever; dir = tempDir() }

    func run(_ job: MusicKaraokeJobRequest, onGrowing: @escaping @Sendable (MusicGrowingInstrumental) -> Void, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        order.append(job.track.id)
        attempts[job.track.id, default: 0] += 1
        if blockForever {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        if attempts[job.track.id]! <= failFirst { throw MusicKaraokeFailure.failed }
        progress(1)
        let u = dir.appendingPathComponent(job.track.id + ".flac")
        try Data([1]).write(to: u)
        return u
    }
    var ran: [String] { order }
    var count: Int { order.count }
}

/// Returns at once and remembers what it was asked to wait for.
private final class InstantClock: MusicKaraokeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var sleeps: [Double] = []
    func now() -> Date { Date() }
    func sleep(seconds: Double) async throws {
        lock.withLock { sleeps.append(seconds) }
        await Task.yield()
    }
    var recorded: [Double] { lock.lock(); defer { lock.unlock() }; return sleeps }
}

@Suite @MainActor struct MusicKaraokeJobsTests {
    private func jobs(_ worker: MusicKaraokeWorking, clock: MusicKaraokeClock) -> MusicKaraokeJobs {
        MusicKaraokeJobs(worker: worker, cache: MusicKaraokeCache(directory: tempDir()), clock: clock, modelStem: { "m" })
    }

    @Test func prefetchesTheCurrentTrackAndTheNextTwoInOrder() async {
        let worker = ScriptedWorker()
        let q = jobs(worker, clock: InstantClock())
        q.setEnabled(true)
        q.updateWanted(current: track("c"), upcoming: [track("n1"), track("n2"), track("n3")])
        await q.waitUntilIdle()
        #expect(await worker.ran == ["c", "n1", "n2"])
        for id in ["c", "n1", "n2"] { if case .ready? = q.states["p:" + id] {} else { Issue.record("\(id) not ready") } }
        #expect(q.states["p:n3"] == nil)
    }

    @Test func nothingRunsWhileOff() async {
        let worker = ScriptedWorker()
        let q = jobs(worker, clock: InstantClock())
        q.updateWanted(current: track("c"), upcoming: [track("n1")])
        await Task.yield()
        #expect(await worker.count == 0)
    }

    @Test func failedSongBacksOffFiveFifteenThirtySixtyThenStops() async {
        let worker = ScriptedWorker(failFirst: 99)
        let clock = InstantClock()
        let q = jobs(worker, clock: clock)
        q.setEnabled(true)
        q.updateWanted(current: track("c"), upcoming: [])
        await q.waitUntilIdle()
        #expect(clock.recorded == [5, 15, 30, 60])
        #expect(await worker.count == 5)
        #expect(q.states["p:c"] == .exhausted(.failed))
        // Pressing "Try again" starts over.
        q.retryNow(track("c"))
        await q.waitUntilIdle()
        #expect(await worker.count == 10)
    }

    @Test func aSongThatRecoversBecomesReady() async {
        let worker = ScriptedWorker(failFirst: 2)
        let clock = InstantClock()
        let q = jobs(worker, clock: clock)
        q.setEnabled(true)
        q.updateWanted(current: track("c"), upcoming: [])
        await q.waitUntilIdle()
        #expect(clock.recorded == [5, 15])
        if case .ready? = q.states["p:c"] {} else { Issue.record("expected ready") }
    }

    @Test func skippingCancelsTheRunningJobAfterTheGrace() async {
        let worker = ScriptedWorker(blockForever: true)
        let clock = InstantClock()
        let q = jobs(worker, clock: clock)
        q.setEnabled(true)
        q.updateWanted(current: track("a"), upcoming: [])
        while await worker.count == 0 { await Task.yield() }
        #expect(q.runningUID == "p:a")
        q.updateWanted(current: track("b"), upcoming: [])
        while q.runningUID == "p:a" { await Task.yield() }
        #expect(clock.recorded.contains(MusicKaraokeScheduler.cancelGraceSeconds))
        #expect(q.states["p:a"] == nil)
        q.cancelAll()
        await q.waitUntilIdle()
    }

    @Test func overLongSongIsMarkedAndNeverRun() async {
        let worker = ScriptedWorker()
        let q = jobs(worker, clock: InstantClock())
        q.setEnabled(true)
        q.updateWanted(current: track("big", seconds: 1500), upcoming: [])
        await q.waitUntilIdle()
        #expect(q.states["p:big"] == .tooLong)
        #expect(await worker.count == 0)
    }
}

// MARK: End to end

@Suite struct MusicKaraokePipelineTests {
    /// A generated two second tone goes through decode, chunking, the stand-in model, blending and the cache file.
    @Test func toneThroughTheWholePipeline() async throws {
        let dir = tempDir()
        let rate = 44_100.0, frames = 88_200
        let tone = sine(440, frames: frames, rate: rate, amplitude: 0.4)
        let src = dir.appendingPathComponent("tone.wav")
        do {
            let fmt = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false))
            let file = try AVAudioFile(forWriting: src, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                                                   AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true])
            let buf = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)))
            buf.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames { buf.floatChannelData?[0][i] = tone[i]; buf.floatChannelData?[1][i] = tone[i] }
            try file.write(from: buf)
        }
        struct LocalFetch: MusicKaraokeAudioFetching {
            let url: URL
            func localAudio(for track: REDDY.MusicTrack, into directory: URL, isCancelled: @Sendable () -> Bool) async throws -> (url: URL, isTemporary: Bool) { (url, false) }
        }
        let cache = MusicKaraokeCache(directory: dir.appendingPathComponent("cache"))
        let model = IdentityModel(layout: MusicStemLayout(stft: smallConfig, stem: .instrumental))
        let sep = MusicKaraokeSeparator(fetcher: LocalFetch(url: src), cache: cache, loadModel: { model })
        var sawGrowing = false
        let sawGrowingFlag = LockedBool()
        let out = try await sep.run(MusicKaraokeJobRequest(track: track("tone", seconds: 2), startingAt: 0, modelStem: "fake"),
                                    onGrowing: { _ in sawGrowingFlag.set() }, progress: { _ in })
        sawGrowing = sawGrowingFlag.value
        #expect(sawGrowing)
        #expect(cache.lookup(modelStem: "fake", trackID: "p:tone") == out)
        #expect(["flac", "caf"].contains(out.pathExtension))
        let read = try AVAudioFile(forReading: out)
        #expect(read.length == AVAudioFramePosition(frames))
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: read.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
        try read.read(into: buf)
        let l = Array(UnsafeBufferPointer(start: buf.floatChannelData?[0], count: frames))
        let err = zip(l, tone).map { $0 - $1 }
        #expect(rms(err) < 0.02)       // 16-bit rounding plus the transform, far below the tone's own level
        #expect(rms(l) > 0.2)
        // A second request is a cache hit and does no work.
        let again = try await sep.run(MusicKaraokeJobRequest(track: track("tone", seconds: 2), startingAt: 0, modelStem: "fake"), onGrowing: { _ in }, progress: { _ in })
        #expect(again == out)
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
}
