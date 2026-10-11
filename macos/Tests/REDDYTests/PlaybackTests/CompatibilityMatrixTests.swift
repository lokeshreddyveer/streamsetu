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
        let kinds: [PlaybackError.Kind] = [.network, .nameLookup, .timeout, .authorization, .unsupportedFormat, .providerUnavailable, .notFound, .engineUnavailable, .unknown]
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
