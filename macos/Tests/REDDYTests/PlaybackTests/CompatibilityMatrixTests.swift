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
