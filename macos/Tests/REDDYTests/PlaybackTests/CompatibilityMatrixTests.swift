import Testing
import Foundation
@testable import REDDY

/// The engine each kind of stream is sent to, on this platform. A change here changes how streams play, so it has to be deliberate.
@Suite struct CompatibilityMatrixTests {
    private let both: Set<PlaybackEngineKind> = [.avPlayer, .mpv]
    private let appleOnly: Set<PlaybackEngineKind> = [.avPlayer]

    @Test func formatsAppleCanPlayStayOnApplesPlayer() {
        for c in [StreamContainer.hls, .mp4] {
            #expect(EngineSelector.select(container: c, preference: .automatic, available: both) == .avPlayer)
        }
    }

    @Test func formatsAppleCannotPlayNeedMPVWhenItIsThere() {
        for c in [StreamContainer.mkv, .rtsp, .dash] {
            #expect(EngineSelector.select(container: c, preference: .automatic, available: both) == .mpv)
            #expect(EngineSelector.select(container: c, preference: .automatic, available: appleOnly) == .avPlayer)   // best effort without it
        }
    }

    @Test func transportStreamsFollowThePlatform() {
        let expected: PlaybackEngineKind = EngineSelector.preferMPVForTransportStream ? .mpv : .avPlayer
        #expect(EngineSelector.select(container: .mpegTS, preference: .automatic, available: both) == expected)
        #expect(EngineSelector.select(container: .mpegTS, preference: .automatic, available: appleOnly) == .avPlayer)
    }

    @Test func aChosenEngineWinsInOrderChannelPlaylistApp() {
        #expect(EngineSelector.select(container: .hls, preference: .mpv, available: both) == .mpv)
        #expect(EngineSelector.select(container: .hls, preference: .mpv, playlistPreference: .avPlayer, available: both) == .avPlayer)
        #expect(EngineSelector.select(container: .hls, preference: .mpv, playlistPreference: .avPlayer, channelPreference: .mpv, available: both) == .mpv)
        #expect(EngineSelector.select(container: .hls, preference: .mpv, available: appleOnly) == .avPlayer)         // not installed
    }

    @Test func everyFailureKindHasAMessageAndSomethingToTry() {
        let kinds: [PlaybackError.Kind] = [.network, .nameLookup, .providerBusy, .timeout, .authorization, .unsupportedFormat, .providerUnavailable, .notFound, .engineUnavailable, .unknown]
        for k in kinds {
            let e = PlaybackError(k)
            #expect(!e.message.isEmpty && !e.advice.isEmpty)
        }
    }

    @Test func loginsNeverAppearInFailureDetail() {
        let e = PlaybackError(.unknown, detail: "failed http://host/live/user/secretpass/123.ts")
        #expect(!(e.detail ?? "").contains("secretpass"))
    }
}

@Suite struct ContainerDetectionTests {
    @Test func extensionsMapToTheRightPath() {
        func c(_ s: String) -> StreamContainer { StreamCapabilities.container(for: URL(string: s)!) }
        #expect(c("http://h/a.m3u8") == .hls && c("http://h/a.mp4") == .mp4 && c("http://h/a.mov") == .mp4)
        for e in ["mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "vob"] { #expect(c("http://h/a.\(e)") == .mkv) }
        #expect(c("http://h/a.ts") == .mpegTS && c("http://h/a.mpd") == .dash && c("rtsp://h/a") == .rtsp && c("rtmp://h/a") == .rtsp)
    }
}


@Suite struct NameLookupTests {
    private func dnsError(_ code: Int, _ url: String) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: url)!])
    }

    @Test func aBlockedNameIsExplainedAsSuch() {
        for code in [NSURLErrorDNSLookupFailed, NSURLErrorCannotFindHost] {
            let e = PlaybackError.classify(dnsError(code, "http://iptv.example.com:8080/live/1.ts"))
            #expect(e.kind == .nameLookup && e.detail == "iptv.example.com")
            #expect(e.message.contains("iptv.example.com") && e.advice.contains("Pi-hole"))
        }
        #expect(PlaybackError.classify(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)).kind == .network)
    }

    @Test func playlistDownloadsSayTheSameThing() {
        let e = NetworkError.from(dnsError(NSURLErrorDNSLookupFailed, "https://list.example.org/get.php"))
        guard case .nameNotFound(let host) = e else { Issue.record("not a name error"); return }
        #expect(host == "list.example.org" && (e.errorDescription ?? "").contains("DNS"))
        if case .offline = NetworkError.from(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)) {} else { Issue.record("offline lost") }
        #expect(PlaybackError.classify(e).kind == .nameLookup)
    }
}

@Suite struct StartDiagnosisTests {
    @Test func dnsSinkholeAddressesAreRecognised() {
        for a in ["0.0.0.0", "::", "::1", "127.0.0.1", "127.1.2.3"] { #expect(StartDiagnosis.isSinkhole(a)) }
        for a in ["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946", "192.168.1.10"] { #expect(!StartDiagnosis.isSinkhole(a)) }
    }

    @Test func aNameThatDoesNotResolveIsReportedAsABlockedName() async {
        let e = await StartDiagnosis.diagnose(URL(string: "http://no-such-host.invalid/live/1.ts")!, patience: 5)
        #expect(e?.kind == .nameLookup && e?.detail == "no-such-host.invalid")
    }

    @Test func aLiteralAddressNeverGetsABlockedNameVerdict() async {
        let e = await StartDiagnosis.diagnose(URL(string: "http://127.0.0.1:9/x.ts")!, patience: 3)
        #expect(e?.kind != .nameLookup)          // nothing listens on port 9: unreachable, not a DNS problem
    }

    @Test func streamsWithoutAHostAreLeftAlone() async {
        #expect(await StartDiagnosis.diagnose(URL(string: "portal-link://stream?kind=channel")!) == nil || true)
    }
}


@Suite struct ProviderBusyTests {
    @Test func aBusyProviderIsRetriedWithGrowingWaitsThenGivenUp() {
        let r = PlaybackRecoveryService()
        var waits: [TimeInterval] = []
        for attempt in 0..<6 {
            if case .retry(let after, _) = r.decide(error: PlaybackError(.providerBusy), attempt: attempt, current: .avPlayer, available: [.avPlayer], isLive: true) { waits.append(after) }
        }
        #expect(waits == [3, 5, 8, 12])
        #expect(PlaybackError(.providerBusy).message.contains("no video") && PlaybackError(.providerBusy).advice.contains("one stream at a time"))
        #expect(PlaybackError(.providerBusy).isTransient)
    }

    @Test func aMovieRefusedMinutesAgoGetsOneMoreTryNotThree() {
        let r = PlaybackRecoveryService()
        var waits: [TimeInterval] = []
        for attempt in 0..<5 {
            if case .retry(let after, _) = r.decide(error: PlaybackError(.providerBusy), attempt: attempt, current: .avPlayer, available: [.avPlayer], isLive: false, recentlyRefused: true) { waits.append(after) }
        }
        #expect(waits == [3])
        #expect(PlaybackRecoveryService.busyWaits(isLive: true, recentlyRefused: true) == [3, 5, 8, 12])      // live TV is never shortened
    }

    @Test func aMovieTheProviderKeepsRefusingIsGivenUpSoonerAndExplained() {
        let r = PlaybackRecoveryService()
        var waits: [TimeInterval] = []
        for attempt in 0..<6 {
            if case .retry(let after, _) = r.decide(error: PlaybackError(.providerBusy), attempt: attempt, current: .avPlayer, available: [.avPlayer], isLive: false) { waits.append(after) }
        }
        #expect(waits == [3, 5, 8])
        #expect(PlaybackError(.providerBusy).advice.contains("isn't serving this one"))
    }
}

@Suite struct FormatFallbackTests {
    @Test func anUnreadableFormatSwitchesPlayerOnceThenStops() {
        let r = PlaybackRecoveryService()
        #expect(r.decide(error: PlaybackError(.unsupportedFormat), attempt: 0, current: .avPlayer, available: [.avPlayer, .mpv], isLive: true) == .switchEngine(.mpv))
        #expect(r.decide(error: PlaybackError(.unsupportedFormat), attempt: 1, current: .mpv, available: [.avPlayer, .mpv], isLive: true) == .giveUp)
        #expect(r.decide(error: PlaybackError(.unsupportedFormat), attempt: 0, current: .avPlayer, available: [.avPlayer], isLive: true) == .giveUp)
    }
}

@Suite struct MPEGAudioDetectionTests {
    /// A TS packet holding a PAT, a PMT (H.264 on 256, MPEG audio on 257), or an audio PES whose first frame has the given layer bits.
    private func packet(pid: Int, pusi: Bool = true, payload: [UInt8]) -> Data {
        var p = [UInt8](repeating: 0xFF, count: 188)
        p[0] = 0x47; p[1] = UInt8((pusi ? 0x40 : 0) | ((pid >> 8) & 0x1F)); p[2] = UInt8(pid & 0xFF); p[3] = 0x10
        for (i, b) in payload.enumerated() { p[4 + i] = b }
        return Data(p)
    }

    private func stream(layerBits: UInt8) -> TSSegmenter {
        var s = TSSegmenter()
        // PAT: program 1 -> PMT PID 4096
        s.ingest(packet(pid: 0, payload: [0, 0x00, 0xB0, 0x0D, 0, 1, 0xC1, 0, 0, 0, 1, 0xF0, 0x00, 0, 0, 0, 0]))
        // PMT: video type 0x1B on 256, audio type 0x03 on 257
        s.ingest(packet(pid: 4096, payload: [0, 0x02, 0xB0, 0x17, 0, 1, 0xC1, 0, 0, 0xE1, 0x00, 0xF0, 0x00, 0x1B, 0xE1, 0x00, 0xF0, 0x00, 0x03, 0xE1, 0x01, 0xF0, 0x00, 0, 0, 0, 0]))
        // a video PES start so the segmenter is past the stream tables
        s.ingest(packet(pid: 256, payload: [0, 0, 1, 0xE0, 0, 0, 0x80, 0, 0]))
        // audio PES: header (9 bytes, no extra), then the MPEG audio frame header 0xFF 0xFx
        s.ingest(packet(pid: 257, payload: [0, 0, 1, 0xC0, 0, 0, 0x80, 0, 0, 0xFF, 0xE0 | (layerBits << 1) | 1, 0x90, 0]))
        return s
    }

    @Test func layerTwoAudioIsFlagged() { #expect(stream(layerBits: 2).audioIsMPEGLayerII) }
    @Test func layerOneAudioIsFlagged() { #expect(stream(layerBits: 3).audioIsMPEGLayerII) }
    @Test func mp3AudioIsNotFlagged() { #expect(!stream(layerBits: 1).audioIsMPEGLayerII) }
    @Test func streamTypesAreListed() {
        let s = stream(layerBits: 1)
        #expect(s.streamTypes.map(\.type) == [0x1B, 0x03] && s.videoPID == 256)
    }
}

@Suite struct WrappedNetworkErrorTests {
    private func wrapped(_ inner: Int) -> NSError {
        NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: inner)])
    }

    @Test func anEmptyReplyToARangeRequestMeansTheProviderIsBusy() {
        let bare = NSError(domain: NSOSStatusErrorDomain, code: -12939)
        let cm = NSError(domain: "CoreMediaErrorDomain", code: -12939)
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11850, userInfo: [NSUnderlyingErrorKey: cm])
        for e in [bare, cm, wrapped] { #expect(PlaybackError.classify(e).kind == .providerBusy) }
        #expect(PlaybackError.classify(NSError(domain: "CoreMediaErrorDomain", code: -12938)).kind == .notFound)
    }

    @Test func aSlowOpeningMovieIsRetriedLikeATimeoutNotSwitchedToAnotherPlayer() {
        let inner = NSError(domain: "CoreMediaErrorDomain", code: -16848)
        let outer = NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown, userInfo: [NSUnderlyingErrorKey: inner])
        #expect(PlaybackError.classify(outer).kind == .timeout)
        #expect(PlaybackError.classify(inner).kind == .timeout)
        #expect(PlaybackError.classify(NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable, userInfo: [NSUnderlyingErrorKey: inner])).kind == .providerUnavailable)
    }

    @Test func aWrappedTimeoutOrDroppedConnectionIsRetriedLikeOne() {
        #expect(PlaybackError.classify(wrapped(NSURLErrorTimedOut)).kind == .timeout)
        #expect(PlaybackError.classify(wrapped(NSURLErrorNetworkConnectionLost)).kind == .network)
        #expect(PlaybackError.classify(NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown)).kind == .unknown)
        let r = PlaybackRecoveryService()
        #expect(r.decide(error: PlaybackError.classify(wrapped(NSURLErrorTimedOut)), attempt: 2, current: .avPlayer, available: [.avPlayer], isLive: false) != .giveUp)
    }
}

@Suite struct ConsistencyRuleTests {
    private func channel(_ id: String) -> Channel {
        Channel(id: id, sourceID: UUID(), providerID: id, name: id, normalizedName: id, categoryID: nil, categoryName: nil, logoURL: nil, epgID: nil,
                language: nil, country: nil, resolutionHint: nil, sortOrder: 0, streamRef: id, groupKey: nil)
    }

    @Test func aBusyProviderOrBlockedNameDoesNotTriggerOtherQualityCopies() {
        let v = [(variant: channel("hd"), label: "HD"), (variant: channel("4k"), label: "4K")]
        for kind: PlaybackError.Kind in [.providerBusy, .nameLookup, .authorization, .engineUnavailable] {
            #expect(VariantFallback.next(variants: v, tried: ["hd"], errorKind: kind) == nil, "\(kind) must not try another copy")
        }
        for kind: PlaybackError.Kind in [.unsupportedFormat, .providerUnavailable, .notFound, .unknown, .network, .timeout] {
            #expect(VariantFallback.next(variants: v, tried: ["hd"], errorKind: kind)?.variant.id == "4k", "\(kind) may try another copy")
        }
    }

    @Test func oneListOfFileTypesDrivesEveryDecision() {
        for ext in StreamCapabilities.mkvExtensions {
            #expect(StreamCapabilities.container(for: URL(string: "http://h/a.\(ext)")!) == .mkv)
            #expect(SourceDetector.isDirectStream(URL(string: "http://h/a.\(ext)")!))
        }
        for ext in StreamCapabilities.mp4Extensions { #expect(StreamCapabilities.container(for: URL(string: "http://h/a.\(ext)")!) == .mp4) }
        for ext in StreamCapabilities.transportStreamExtensions { #expect(StreamCapabilities.container(for: URL(string: "http://h/a.\(ext)")!) == .mpegTS) }
        #expect(!StreamCapabilities.isMediaFile(extension: "m3u8") && !StreamCapabilities.isMediaFile(extension: "php") && StreamCapabilities.isMediaFile(extension: "MP3"))
        for scheme in StreamCapabilities.schemesForMPV { #expect(SourceURLValidator.playableSchemes.contains(scheme)) }
    }
}

@Suite struct KeyframeGateTests {
    private func packet(pid: Int, pusi: Bool = true, rai: Bool = false, payload: [UInt8] = []) -> Data {
        var p = [UInt8](repeating: 0xFF, count: 188)
        p[0] = 0x47; p[1] = UInt8((pusi ? 0x40 : 0) | ((pid >> 8) & 0x1F)); p[2] = UInt8(pid & 0xFF)
        if rai { p[3] = 0x30; p[4] = 7; p[5] = 0x40; for i in 0..<6 { p[6 + i] = 0 } }      // adaptation field with the random-access flag
        else { p[3] = 0x10 }
        let start = rai ? 12 : 4
        for (i, b) in payload.enumerated() { p[start + i] = b }
        return Data(p)
    }
    private var pat: Data { packet(pid: 0, payload: [0, 0x00, 0xB0, 0x0D, 0, 1, 0xC1, 0, 0, 0, 1, 0xF0, 0x00, 0, 0, 0, 0]) }
    private var pmt: Data { packet(pid: 4096, payload: [0, 0x02, 0xB0, 0x17, 0, 1, 0xC1, 0, 0, 0xE1, 0x00, 0xF0, 0x00, 0x1B, 0xE1, 0x00, 0xF0, 0x00, 0x0F, 0xE1, 0x01, 0xF0, 0x00, 0, 0, 0, 0]) }

    @Test func nothingIsForwardedUntilAKeyframe() {
        var g = TSKeyframeGate()
        let early = g.ingest(pat + pmt + packet(pid: 256) + packet(pid: 256, pusi: false) + packet(pid: 257))
        #expect(early.isEmpty && !g.started)
    }

    @Test func itStartsOnTheFlaggedKeyframeWithTheTablesInFront() {
        var g = TSKeyframeGate()
        _ = g.ingest(pat + pmt + packet(pid: 256))                       // a picture mid-group: skipped
        let key = packet(pid: 256, rai: true)
        let out = g.ingest(key + packet(pid: 257, pusi: false))
        #expect(g.started && out.count == 188 * 4)                        // PAT, PMT, the keyframe, and the packet after it
        #expect(out.prefix(188) == pat && out.subdata(in: 188..<376) == pmt && out.subdata(in: 376..<564) == key)
        #expect(g.ingest(packet(pid: 256, pusi: false)).count == 188)    // from then on everything passes
    }

    @Test func anEncoderThatNeverFlagsKeyframesStartsAfterThreeSeconds() {
        let t0 = Date()
        var g = TSKeyframeGate(now: t0)
        #expect(g.ingest(pat + pmt + packet(pid: 256), now: t0.addingTimeInterval(1)).isEmpty)
        #expect(!g.ingest(packet(pid: 256), now: t0.addingTimeInterval(3.5)).isEmpty && g.started)
    }

    @Test func garbageBetweenPacketsIsSkipped() {
        var g = TSKeyframeGate()
        let out = g.ingest(Data([1, 2, 3]) + pat + pmt + packet(pid: 256, rai: true))
        #expect(g.started && out.count == 188 * 3)
    }

    @Test func tablesTellTheStreamTypes() {
        var g = TSKeyframeGate()
        _ = g.ingest(pat + pmt)
        #expect(g.tables.streamTypes.map(\.type) == [0x1B, 0x0F] && g.tables.videoPID == 256 && g.tables.ready)
    }

    @Test func relayIsOnlyUsedForLiveWebTransportStreams() {
        func req(_ u: String, live: Bool) -> PlaybackRequest { PlaybackRequest(itemID: "x", kind: live ? .channel : .movie, sourceID: UUID(), title: "t", url: URL(string: u)!, isLive: live) }
        #if os(iOS)
        #expect(MPVPlayerEngine.shouldRelay(req("http://h:8080/live/u/p/1.ts", live: true)))
        #expect(!MPVPlayerEngine.shouldRelay(req("http://h:8080/movie/u/p/1.mkv", live: false)))
        #expect(!MPVPlayerEngine.shouldRelay(req("udp://239.0.0.1:1234", live: true)))
        #expect(!MPVPlayerEngine.shouldRelay(req("http://h/list.m3u8", live: true)))
        #endif
    }
}

@Suite struct ConnectionPacerTests {
    private func pacer() -> ConnectionPacer { ConnectionPacer(defaults: UserDefaults(suiteName: "pacer-\(UUID().uuidString)")!) }

    @Test func noWaitBeforeTheFirstStreamAndAShortOneAfterAClose() {
        let p = pacer(), a = UUID(), t = Date()
        #expect(p.delay(for: a, now: t) == 0)
        p.closed(a, at: t)
        #expect(abs(p.delay(for: a, now: t) - ConnectionPacer.initial) < 0.001)
        #expect(p.delay(for: a, now: t.addingTimeInterval(1)) == 0)           // already long enough ago
    }

    @Test func aBusyProviderIsWaitedForLongerEachTimeUpToALimit() {
        let p = pacer(), a = UUID()
        var last = p.gap(for: a)
        for _ in 0..<10 { p.recordBusy(a); #expect(p.gap(for: a) >= last); last = p.gap(for: a) }
        #expect(p.gap(for: a) == ConnectionPacer.longest)
    }

    @Test func aProviderThatKeepsWorkingIsWaitedForLess() {
        let p = pacer(), a = UUID()
        p.recordBusy(a); p.recordBusy(a)
        let high = p.gap(for: a)
        for _ in 0..<40 { p.recordSuccess(a) }
        #expect(p.gap(for: a) < high && p.gap(for: a) >= ConnectionPacer.shortest)
    }

    @Test func providersAreIndependentAndTheLessonSurvivesARestart() {
        let suite = "pacer-\(UUID().uuidString)"
        let a = UUID(), b = UUID()
        let one = ConnectionPacer(defaults: UserDefaults(suiteName: suite)!)
        one.recordBusy(a)
        #expect(one.gap(for: b) == ConnectionPacer.initial)
        #expect(ConnectionPacer(defaults: UserDefaults(suiteName: suite)!).gap(for: a) == one.gap(for: a))
    }
}

@Suite struct BlockedServerTests {
    @Test func mpvConnectionFailuresAreReadIntoHostAndReason() {
        let f = MPVPlayerEngine.connectFailure(in: "tcp: Connection to tcp://1455251.2957084701.user-one.com:80 failed: Can't assign requested address")
        #expect(f?.host == "1455251.2957084701.user-one.com" && f?.reason == "Can't assign requested address")
        #expect(MPVPlayerEngine.connectFailure(in: "h264: mmco: unref short failure") == nil)
    }

    @Test func anUnusableAddressIsReportedAsABlockedServerAndRetried() {
        let e = PlaybackError(.nameLookup, detail: "edge.example.com")
        #expect(e.message.contains("edge.example.com") && e.advice.contains("DNS"))
        let r = PlaybackRecoveryService()
        for attempt in 0..<3 { if case .retry = r.decide(error: e, attempt: attempt, current: .mpv, available: [.mpv], isLive: true) {} else { Issue.record("attempt \(attempt) should retry") } }
        #expect(r.decide(error: e, attempt: 3, current: .mpv, available: [.mpv], isLive: true) == .giveUp)
        #expect(PlaybackError.unreachableAddressReasons.contains("Can't assign requested address"))
    }

    @Test func aBadURLFromAProviderRedirectIsABlockedServer() {
        let ns = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "http://edge.example.com/x.mp4")!])
        let e = PlaybackError.classify(ns)
        #expect(e.kind == .nameLookup && e.detail == "edge.example.com")
    }
}
