import Testing
import Foundation
@testable import REDDY

// MARK: synthetic MPEG-TS

enum TS {
    static func packet(pid: Int, pusi: Bool, cc: Int = 0, payload: [UInt8], rai: Bool = false) -> Data {
        var p: [UInt8] = [0x47, UInt8((pusi ? 0x40 : 0) | (pid >> 8)), UInt8(pid & 0xFF)]
        if rai || payload.count < 184 {
            // adaptation field fills the remainder (stuffing), optionally carrying the random-access flag
            let afLen = 188 - 4 - 1 - payload.count
            p.append(UInt8(0x30 | (cc & 0xF)))
            p.append(UInt8(max(0, afLen)))
            if afLen > 0 { p.append(rai ? 0x40 : 0x00); p += [UInt8](repeating: 0xFF, count: afLen - 1) }
        } else {
            p.append(UInt8(0x10 | (cc & 0xF)))
        }
        p += payload
        if p.count < 188 { p += [UInt8](repeating: 0xFF, count: 188 - p.count) }
        return Data(p.prefix(188))
    }

    static let pat = packet(pid: 0, pusi: true, payload: [0x00, 0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xE1, 0x00, 0, 0, 0, 0])
    static let pmt: Data = {
        let sec: [UInt8] = [0x02, 0xB0, 18, 0x00, 0x01, 0xC1, 0x00, 0x00, 0xE1, 0x01, 0xF0, 0x00, 0x1B, 0xE1, 0x01, 0xF0, 0x00, 0, 0, 0, 0]
        return packet(pid: 0x100, pusi: true, payload: [0x00] + sec)
    }()

    static func pesHeader(pts: Int64) -> [UInt8] {
        let b0 = UInt8(0x21 | ((pts >> 30) & 7) << 1), b1 = UInt8((pts >> 22) & 0xFF)
        let b2 = UInt8(((pts >> 15) & 0x7F) << 1 | 1), b3 = UInt8((pts >> 7) & 0xFF), b4 = UInt8((pts & 0x7F) << 1 | 1)
        return [0, 0, 1, 0xE0, 0, 0, 0x80, 0x80, 5, b0, b1, b2, b3, b4]
    }

    /// One second of video: a frame start (optionally a keyframe) plus filler packets.
    static func frame(seconds: Double, keyframe: Bool) -> Data {
        var d = packet(pid: 0x101, pusi: true, payload: pesHeader(pts: Int64(seconds * 90_000)) + [UInt8](repeating: 0xAB, count: 20), rai: keyframe)
        for _ in 0..<3 { d += packet(pid: 0x101, pusi: false, payload: [UInt8](repeating: 0xCD, count: 184)) }
        return d
    }

    static func stream(seconds: Int, keyframeEvery: Int, startPTS: Double = 0) -> Data {
        var d = pat + pmt
        for s in 0..<seconds { d += frame(seconds: startPTS + Double(s), keyframe: s % keyframeEvery == 0) }
        return d
    }
}

@Suite("Playback") struct PlaybackTests {
    // MARK: segmenter

    @Test func cutsOnKeyframesAndPrefixesTables() {
        var seg = TSSegmenter()
        seg.ingest(TS.stream(seconds: 20, keyframeEvery: 2))
        #expect(seg.segments.count >= 8)
        for s in seg.segments {
            #expect(s.data.prefix(188) == TS.pat && s.data.dropFirst(188).prefix(188) == TS.pmt, "each segment starts with PAT+PMT")
            #expect(s.data.count % 188 == 0)
            #expect(abs(s.duration - 2.0) < 0.01, "duration comes from PTS, got \(s.duration)")
        }
        #expect(seg.segments.map(\.seq) == Array(seg.segments.first!.seq..<(seg.segments.first!.seq + seg.segments.count)))
    }

    @Test func playlistIsValidLiveHLS() throws {
        var seg = TSSegmenter()
        seg.ingest(TS.stream(seconds: 4, keyframeEvery: 2))
        #expect(seg.playlist() == nil, "not enough segments to start yet")
        seg.ingest(TS.stream(seconds: 12, keyframeEvery: 2, startPTS: 4).dropFirst(376))
        let m = try #require(seg.playlist())
        #expect(m.hasPrefix("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:"))
        #expect(!m.contains("#EXT-X-ENDLIST"), "a live playlist never ends")
        #expect(m.components(separatedBy: "#EXTINF").count - 1 == seg.segments.count)
        let first = try #require(seg.segments.first)
        #expect(m.contains("seg/\(first.seq).ts") && seg.segment(first.seq) == first.data)
    }

    @Test func forcesACutWhenNoKeyframeArrives() {
        var seg = TSSegmenter()
        seg.ingest(TS.stream(seconds: 30, keyframeEvery: 1000))      // only the very first frame is a keyframe
        #expect(seg.segments.count >= 2)
        #expect(seg.segments.allSatisfy { $0.duration <= 8.01 })
    }

    @Test func onlyKeepsTheNewestSegmentsAndNeverGrowsUnbounded() {
        var seg = TSSegmenter()
        seg.ingest(TS.stream(seconds: 120, keyframeEvery: 2))
        #expect(seg.segments.count <= seg.keep)
        #expect(seg.nextSeq > seg.keep)
    }

    @Test func toleratesChunkBoundariesGarbageAndPTSWrap() {
        let whole = TS.stream(seconds: 16, keyframeEvery: 2)
        var a = TSSegmenter(); a.ingest(whole)
        var b = TSSegmenter()
        var i = 0
        while i < whole.count { let e = min(i + 77, whole.count); b.ingest(whole.subdata(in: i..<e)); i = e }     // odd chunk sizes
        #expect(a.segments.map(\.data) == b.segments.map(\.data))

        var g = TSSegmenter()
        g.ingest(Data([1, 2, 3, 4, 5]) + whole)                                                                  // leading garbage
        #expect(g.segments.count == a.segments.count && g.droppedBytes == 5)

        var w = TSSegmenter()                                                                                    // PTS wraps at 2^33
        w.ingest(TS.stream(seconds: 12, keyframeEvery: 2, startPTS: Double((1 << 33) - 5 * 90_000) / 90_000))
        #expect(w.segments.count >= 3 && w.segments.allSatisfy { abs($0.duration - 2) < 0.01 })
    }

    @Test func waitsForStreamTablesBeforeSegmenting() {
        var seg = TSSegmenter()
        seg.ingest(TS.stream(seconds: 6, keyframeEvery: 2).dropFirst(376))        // no PAT/PMT
        #expect(seg.segments.isEmpty)
    }

    // MARK: state machine

    @Test func normalPlaybackLifecycle() {
        var m = PlaybackStateMachine()
        let steps: [(PlaybackEvent, PlaybackState)] = [
            (.startResolving, .resolving), (.resolved, .preparing), (.buffering, .buffering), (.ready, .playing),
            (.pause, .paused), (.resume, .playing), (.seekBegan, .seeking), (.seekEnded, .buffering), (.ready, .playing),
            (.reachedEnd, .ended), (.stop, .idle),
        ]
        for (e, s) in steps {
            let accepted = m.send(e)
            let now = m.state
            #expect(accepted && now == s, "\(e) → \(s)")
        }
    }

    @Test func illegalTransitionsAreRejected() {
        var m = PlaybackStateMachine()
        var results: [Bool] = []
        for e: PlaybackEvent in [.ready, .pause, .seekBegan, .resume] { results.append(m.send(e)) }
        #expect(results == [false, false, false, false] && m.state == .idle)
        m.send(.startResolving)
        let early = m.send(.ready), earlyEnd = m.send(.reachedEnd)
        #expect(!early, "cannot be playing before it is prepared")
        #expect(!earlyEnd)
    }

    @Test func switchingChannelsIsAlwaysAllowedAndFailureCanRetry() {
        var m = PlaybackStateMachine()
        for e: PlaybackEvent in [.startResolving, .resolved, .ready] { m.send(e) }
        let switched = m.send(.startResolving)
        #expect(switched && m.state == .resolving, "instant channel switch from playing")
        m.send(.resolved)
        let failed = m.send(.failed(PlaybackError(.network)))
        #expect(failed && m.state == .failed(PlaybackError(.network)))
        let resumed = m.send(.ready)
        #expect(!resumed, "failed streams don't magically resume")
        let retried = m.send(.retry)
        #expect(retried && m.state == .resolving)
        let stopped = m.send(.stop)
        #expect(stopped && m.state == .idle)
        let failIdle = m.send(.failed(PlaybackError(.unknown)))
        #expect(!failIdle, "nothing to fail when idle")
    }

    @Test func recoveringStateTransitions() {
        var m = PlaybackStateMachine()
        for e: PlaybackEvent in [.startResolving, .resolved, .ready] { m.send(e) }
        let began = m.send(.recover)
        #expect(began && m.state == .recovering && m.state.isBusy && m.state.isActive)
        let resumed = m.send(.ready)
        #expect(resumed && m.state == .playing, "a successful reconnect goes straight back to playing")
        m.send(.recover)
        let gaveUp = m.send(.failed(PlaybackError(.network)))
        #expect(gaveUp && m.state == .failed(PlaybackError(.network)), "recovery ends in a terminal failure, never an endless spinner")
        var idle = PlaybackStateMachine()
        let fromIdle = idle.send(.recover)
        #expect(!fromIdle, "nothing to recover when idle")
        var fresh = PlaybackStateMachine()
        fresh.send(.startResolving); fresh.send(.recover)
        let reresolved = fresh.send(.resolved)
        #expect(reresolved && fresh.state == .preparing)
    }

    // MARK: classification, selection, recovery

    @Test func errorClassificationAndMessages() {
        #expect(PlaybackError.fromHTTP(403).kind == .authorization)
        #expect(PlaybackError.fromHTTP(404).kind == .notFound)
        #expect(PlaybackError.fromHTTP(503).kind == .providerUnavailable)
        #expect(PlaybackError.classify(URLError(.notConnectedToInternet)).kind == .network)
        #expect(PlaybackError.classify(URLError(.timedOut)).kind == .timeout)
        #expect(PlaybackError.classify(NSError(domain: "AVFoundationErrorDomain", code: -11829)).kind == .unsupportedFormat)
        #expect(PlaybackError.classify(NSError(domain: "CoreMediaErrorDomain", code: -12660)).kind == .authorization)
        #expect(PlaybackError(.network).message.contains("Network unavailable"))
        #expect(PlaybackError(.unsupportedFormat).message.contains("not supported"))
        #expect(PlaybackError(.authorization).message.contains("rejected"))
        #expect(!PlaybackError(.authorization).isTransient && PlaybackError(.network).isTransient)
        #expect(!PlaybackError(.unknown, detail: "http://h/live/user/pass/1.ts").detail!.contains("pass"))
    }

    @Test func containerDetectionDoesNotTrustExtensionsAlone() {
        func c(_ s: String, live: Bool = false) -> StreamContainer { StreamCapabilities.container(for: URL(string: s)!, isLive: live) }
        #expect(c("http://h/a/index.m3u8") == .hls)
        #expect(c("http://h/movie/u/p/1.mp4") == .mp4)
        #expect(c("http://h/movie/u/p/1.mkv") == .mkv)
        #expect(c("rtsp://h/cam") == .rtsp)
        #expect(c("http://h/x.mpd") == .dash)
        #expect(c("http://h/live/u/p/12") == .mpegTS, "extensionless Xtream live endpoints are TS")
        #expect(c("http://h/stream", live: true) == .mpegTS)
        #expect(c("http://h/stream") == .unknown)
    }

    @Test func engineSelection() {
        let both: Set<PlaybackEngineKind> = [.avPlayer, .mpv], av: Set<PlaybackEngineKind> = [.avPlayer]
        #expect(EngineSelector.select(container: .hls, preference: .automatic, available: both) == .avPlayer)
        #expect(EngineSelector.select(container: .mkv, preference: .automatic, available: both) == .mpv)
        #expect(EngineSelector.select(container: .mkv, preference: .automatic, available: av) == .avPlayer)
        #expect(EngineSelector.select(container: .mp4, preference: .mpv, available: both) == .mpv)
        #expect(EngineSelector.select(container: .mp4, preference: .mpv, available: av) == .avPlayer, "never selects an engine that isn't there")
        #expect(EngineSelector.fallback(from: .avPlayer, available: both) == .mpv)
        #expect(EngineSelector.fallback(from: .avPlayer, available: av) == nil)
    }

    @Test func recoveryIsBoundedAndNeverRetriesAuthorization() {
        let r = PlaybackRecoveryService(maxRetries: 3)
        let both: Set<PlaybackEngineKind> = [.avPlayer, .mpv]
        #expect(r.decide(error: PlaybackError(.authorization), attempt: 0, current: .avPlayer, available: both, isLive: true) == .giveUp)
        guard case .retry(let d0, let re0) = r.decide(error: PlaybackError(.network), attempt: 0, current: .avPlayer, available: both, isLive: true) else { Issue.record("expected retry"); return }
        guard case .retry(let d2, _) = r.decide(error: PlaybackError(.network), attempt: 2, current: .avPlayer, available: both, isLive: true) else { Issue.record("expected retry"); return }
        #expect(re0 && d2 > d0, "re-resolves the URL and backs off")
        #expect(r.decide(error: PlaybackError(.network), attempt: 3, current: .avPlayer, available: both, isLive: true) == .giveUp)
        #expect(r.decide(error: PlaybackError(.unsupportedFormat), attempt: 0, current: .avPlayer, available: both, isLive: false) == .switchEngine(.mpv))
        #expect(r.decide(error: PlaybackError(.unsupportedFormat), attempt: 0, current: .avPlayer, available: [.avPlayer], isLive: false) == .giveUp)
        #expect(r.decide(error: PlaybackError(.unsupportedFormat), attempt: 1, current: .mpv, available: both, isLive: false) == .giveUp, "no ping-pong between engines")
    }

    @Test func bufferingMonitorTracksStallsAfterStartup() {
        var b = BufferingMonitor()
        let t0 = Date()
        b.reset()
        b.bufferingBegan(now: t0)                      // initial buffering is startup, not a stall
        #expect(b.stalls == 0)
        b.playing(now: t0.addingTimeInterval(1.5))
        #expect(b.startupSeconds != nil)
        b.bufferingBegan(now: t0.addingTimeInterval(10))
        b.playing(now: t0.addingTimeInterval(12))
        #expect(b.stalls == 1 && abs(b.stalledSeconds - 2) < 0.001)
    }

    @Test func trackPreferenceMatchesLanguageCodes() {
        let tracks = [AudioTrack(id: "0", label: "English", language: "eng", isSelected: true), AudioTrack(id: "1", label: "Deutsch", language: "de", isSelected: false)]
        #expect(AudioTrackManager.preferredIndex(in: tracks, languages: ["de", "en"]) == 1)
        #expect(AudioTrackManager.preferredIndex(in: tracks, languages: ["en"]) == 0)
        #expect(AudioTrackManager.preferredIndex(in: tracks, languages: ["fr"]) == nil)
    }
}
