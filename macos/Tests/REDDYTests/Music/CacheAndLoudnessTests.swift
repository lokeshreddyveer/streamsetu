import Testing
import Foundation
@testable import REDDY

@Suite struct MusicLRUIndexTests {
    private func index() -> MusicLRUIndex {
        var i = MusicLRUIndex()
        i.insert(name: "a.m4a", size: 100, at: Date(timeIntervalSince1970: 1))
        i.insert(name: "b.m4a", size: 100, at: Date(timeIntervalSince1970: 2))
        i.insert(name: "c.m4a", size: 100, at: Date(timeIntervalSince1970: 3))
        return i
    }

    @Test func evictsOldestFirstUntilUnderLimit() {
        #expect(index().evictionList(limit: 250, protectedStem: nil) == ["a.m4a"])
        #expect(index().evictionList(limit: 100, protectedStem: nil) == ["a.m4a", "b.m4a"])
        #expect(index().evictionList(limit: 300, protectedStem: nil).isEmpty)
    }

    @Test func touchChangesOrder() {
        var i = index()
        i.touch("a.m4a", at: Date(timeIntervalSince1970: 10))
        #expect(i.evictionList(limit: 250, protectedStem: nil) == ["b.m4a"])
    }

    @Test func neverEvictsTheProtectedFile() {
        #expect(index().evictionList(limit: 150, protectedStem: "a") == ["b.m4a", "c.m4a"])
        #expect(index().evictionList(limit: 0, protectedStem: "a") == ["b.m4a", "c.m4a"])
    }

    @Test func totalsFollowInsertAndRemove() {
        var i = index()
        #expect(i.totalBytes == 300)
        i.remove("b.m4a")
        #expect(i.totalBytes == 200 && i.count == 2)
    }
}

@Suite struct MusicAudioCacheDiskTests {
    private func temp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("music-cache-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func namingIsStableAndSafe() {
        let k = MusicAudioCache.key(uid: "x:1", quality: .high)
        #expect(MusicAudioCache.fileName(key: k, container: "m4a") == MusicAudioCache.fileName(key: k, container: "M4A"))
        #expect(MusicAudioCache.fileName(key: k, container: "../../etc") .hasSuffix(".etc") == true)
        #expect(MusicAudioCache.safeExtension("") == "audio")
        #expect(MusicAudioCache.key(uid: "x:1", quality: .low) != k)
    }

    @Test func disabledCacheStoresNothing() {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = MusicAudioCache(directory: dir)
        #expect(c.beginWrite(key: "k", container: "mp3") == nil)
    }

    @Test func completeWriteIsReadableAndAccounted() throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = MusicAudioCache(directory: dir)
        c.configure(enabled: true, limitMB: 50)
        let w = try #require(c.beginWrite(key: "k", container: "mp3"))
        #expect(c.beginWrite(key: "k", container: "mp3") == nil)
        w.append(Data(repeating: 1, count: 1000))
        w.finish(expectedSize: 1000)
        #expect(c.cachedFile(key: "k") != nil)
        #expect(c.usedBytes == 1000)
        // A second cache over the same folder rebuilds the same accounting.
        let again = MusicAudioCache(directory: dir)
        again.configure(enabled: true, limitMB: 50)
        #expect(again.usedBytes == 1000)
    }

    @Test func incompleteWriteIsDiscarded() throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = MusicAudioCache(directory: dir)
        c.configure(enabled: true, limitMB: 50)
        let w = try #require(c.beginWrite(key: "k", container: "mp3"))
        w.append(Data(repeating: 1, count: 10))
        w.finish(expectedSize: 999)
        #expect(c.cachedFile(key: "k") == nil)
        #expect(c.usedBytes == 0)
    }

    @Test func clearRemovesEverything() throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = MusicAudioCache(directory: dir)
        c.configure(enabled: true, limitMB: 50)
        let w = try #require(c.beginWrite(key: "k", container: "mp3"))
        w.append(Data(count: 5)); w.finish(expectedSize: 5)
        c.clear()
        #expect(c.usedBytes == 0 && c.cachedFile(key: "k") == nil)
    }
}

@Suite struct MusicProxyHTTPTests {
    @Test func parsesRequestAndRange() {
        let r = MusicProxyHTTP.parse("GET /tok/abc.mp3 HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=100-199")
        #expect(r == MusicProxyRequest(method: "GET", path: "/tok/abc.mp3", range: MusicByteRange(start: 100, end: 199)))
        #expect(MusicProxyHTTP.parseRange("bytes=5-") == MusicByteRange(start: 5, end: nil))
        #expect(MusicProxyHTTP.parseRange("bytes=-500") == MusicByteRange(start: 0, end: nil, suffix: 500))
        #expect(MusicProxyHTTP.parseRange("bytes=0-1,5-6") == MusicByteRange(start: 0, end: 1))
        #expect(MusicProxyHTTP.parseRange("bytes=9-3") == nil)
        #expect(MusicProxyHTTP.parse("garbage") == nil)
    }

    @Test func resolvesRangesAgainstTotal() {
        #expect(MusicProxyHTTP.resolve(nil, total: 1000)?.end == 999)
        let r = MusicProxyHTTP.resolve(MusicByteRange(start: 10, end: 5000), total: 1000)
        #expect(r?.start == 10 && r?.end == 999)
        #expect(MusicProxyHTTP.resolve(MusicByteRange(start: 1000, end: nil), total: 1000) == nil)
    }

    @Test func tokenMustMatchExactly() {
        #expect(MusicProxyHTTP.registrationID(path: "/tok/abc.mp3?x=1", token: "tok") == "abc")
        #expect(MusicProxyHTTP.registrationID(path: "/other/abc.mp3", token: "tok") == nil)
        #expect(MusicProxyHTTP.registrationID(path: "/tok/../abc.mp3", token: "tok") == nil)
        #expect(MusicProxyHTTP.registrationID(path: "/tok/", token: "tok") == nil)
    }

    @Test func parsesContentRange() {
        let c = MusicProxyHTTP.parseContentRange("bytes 100-199/1000")
        #expect(c?.start == 100 && c?.end == 199 && c?.total == 1000)
        #expect(MusicProxyHTTP.parseContentRange("bytes 0-1/*")?.total == nil)
        #expect(MusicProxyHTTP.parseContentRange("nonsense") == nil)
    }

    @Test func proxyIsIdleUntilUsed() {
        let p = MusicStreamProxy()
        #expect(p.isRunning == false)
        p.stop()
        #expect(p.isRunning == false)
    }
}

@Suite struct MusicLoudnessMathTests {
    @Test func gainIsClampedAndDeadZoned() {
        // Target -7 LUFS, clamp -24...+3, nothing under 0.05 dB.
        #expect(MusicLoudnessMath.gainDB(loudness: -7) == 0)
        #expect(MusicLoudnessMath.gainDB(loudness: -7.03) == 0)
        #expect(MusicLoudnessMath.gainDB(loudness: -9) == 2)
        #expect(MusicLoudnessMath.gainDB(loudness: -20) == 3)
        #expect(MusicLoudnessMath.gainDB(loudness: 40) == -24)
        #expect(MusicLoudnessMath.gainDB(loudness: .nan) == 0)
    }

    @Test func volumeFactorNeverExceedsOne() {
        for g in stride(from: -30.0, through: 30.0, by: 1.5) {
            let f = MusicLoudnessMath.volumeFactor(gainDB: g)
            #expect(f <= 1 && f > 0)
        }
        #expect(abs(MusicLoudnessMath.volumeFactor(gainDB: 3) - 1) < 0.001)
        #expect(MusicLoudnessMath.volumeFactor(gainDB: -12) < MusicLoudnessMath.baselineFactor)
    }

    @Test func parsesTags() {
        #expect(MusicLoudnessMath.parseReplayGain("-6.54 dB") == -6.54)
        #expect(MusicLoudnessMath.parseReplayGain("+3.2 DB") == 3.2)
        #expect(MusicLoudnessMath.parseReplayGain("loud") == nil)
        // 1000 means no change; 316 is about +5 dB; the larger of the two channel words is used.
        #expect(abs((MusicLoudnessMath.parseITunNorm("000003E8 000003E8 00000000") ?? 9)) < 0.001)
        let g = MusicLoudnessMath.parseITunNorm("0000013C 00000200 0 0")
        #expect(g != nil && abs(g! - (-10 * log10(512.0 / 1000))) < 0.001)
        #expect(MusicLoudnessMath.parseITunNorm("zz") == nil)
        #expect(MusicLoudnessMath.loudness(replayGainDB: -6) == -12)
    }
}

@Suite struct MusicLoudnessMeterTests {
    private func tone(amplitude: Float, seconds: Double = 5, rate: Double = 44_100) -> Double? {
        var meter = MusicLoudnessMeter(sampleRate: rate, channels: 2)
        let frames = Int(rate * seconds)
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = amplitude * Float(sin(2 * Double.pi * 1000 * Double(i) / rate))
            samples[i * 2] = v; samples[i * 2 + 1] = v
        }
        samples.withUnsafeBufferPointer { meter.add(interleaved: $0) }
        return meter.integratedLoudness
    }

    @Test func louderSignalMeasuresLouder() throws {
        let quiet = try #require(tone(amplitude: 0.05))
        let loud = try #require(tone(amplitude: 0.1))
        #expect(abs((loud - quiet) - 6.02) < 0.2)
    }

    @Test func silenceHasNoLoudness() {
        #expect(tone(amplitude: 0) == nil)
    }

    @Test func fullScaleStereoToneIsNearZeroLUFS() throws {
        let v = try #require(tone(amplitude: 1))
        #expect(abs(v - 0.0) < 1.5)
    }
}

@Suite struct MusicCacheSettingsTests {
    @Test func olderFilesDecodeWithDefaults() throws {
        let s = try JSONDecoder().decode(MusicSettings.self, from: Data("{\"normalizeVolume\":true}".utf8))
        #expect(s.cacheEnabled == false && s.cacheLimitMB == 500 && s.normalizeVolume)
    }

    @Test func limitIsClamped() throws {
        let s = try JSONDecoder().decode(MusicSettings.self, from: Data("{\"cacheLimitMB\":1}".utf8))
        #expect(s.cacheLimitMB == MusicSettings.minCacheMB)
    }
}
