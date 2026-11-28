import Foundation
import Testing
@testable import REDDY

// Offline tests for the extractor pieces: client table and order, whole-file probe ranges, playability classification, entry-point discovery
// against an excerpt of a real player script, the attestation flow with stubs, UMP framing and the streaming request.

private struct StubRunner: YouTubeBotGuardRunner {
    var fail = false
    func start(interpreterScript: String, program: String, globalName: String) async throws -> String { if fail { throw YTMCipherRunnerError.timedOut }; return "resp" }
    func prepareMinter(integrityToken: [UInt8]) async throws {}
    func mint(binding: String) async throws -> String { "tok-" + binding }
    func shutdown() async {}
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock(); private var urls: [String] = []
    func add(_ u: String) { lock.withLock { urls.append(u) } }
    var all: [String] { lock.withLock { urls } }
}

@Suite struct YouTubeExtractorTests {
    // MARK: client table and order

    @Test func tableHasTheCurrentWholeFileClients() {
        let t = YTMClientTable.builtIn
        #expect(t[.iosProducer]?.clientName == "IOS_PRODUCER")
        #expect(t[.iosProducer]?.clientID == "92")
        #expect(t[.iosProducer]?.clientVersion == "0.147.945")
        #expect(t[.visionOS]?.clientVersion == "1.02")
        #expect(t[.tvSamsung]?.osName == "Tizen")
        #expect(t[.androidVR]?.clientVersion == "1.65.10")
        #expect(t[.iosProducer]?.useWebPoTokens == false)
    }

    @Test func guestOrderPutsWholeFileClientsFirstAndCappedOnesLast() {
        let o = YTMClientOrder.guest
        #expect(o.first == .visionOS)
        #expect(o.firstIndex(of: .iosProducer)! < o.firstIndex(of: .ios)!)
        #expect(o.firstIndex(of: .iosProducer)! < o.firstIndex(of: .androidVR)!)
        #expect(o.suffix(2) == [.ios, .androidVR])
        #expect(!o.contains(.tvSamsung))
    }

    @Test func probeReadsStartBoundaryMiddleAndTail() {
        let r = YTMClientOrder.probeRanges(length: 3_000_000)
        #expect(r.count == 4)
        #expect(r[0].lowerBound == 0)
        #expect(r[1].lowerBound == 1_048_576)
        #expect(r[2].lowerBound == 1_500_000)
        #expect(r[3] == 2_999_744...2_999_999)
        // A small file has no boundary probe, and an empty one has none at all.
        #expect(YTMClientOrder.probeRanges(length: 500_000).count == 3)
        #expect(YTMClientOrder.probeRanges(length: 0).isEmpty)
        #expect(YTMClientOrder.probeRanges(length: 100).allSatisfy { $0.upperBound <= 99 })
    }

    // MARK: playability

    @Test func classifiesTheAnswersSeenLive() {
        #expect(YouTubePlayability.from(status: "OK", reason: nil) == .playable)
        #expect(YouTubePlayability.from(status: "LOGIN_REQUIRED", reason: "Sign in to confirm you’re not a bot") == .botCheck)
        #expect(YouTubePlayability.from(status: "UNPLAYABLE", reason: "Sign in to confirm you're not a bot.") == .botCheck)
        #expect(YouTubePlayability.from(status: "UNPLAYABLE", reason: "The page needs to be reloaded.") == .tokenRequired)
        #expect(YouTubePlayability.from(status: "LOGIN_REQUIRED", reason: "Please sign in") == .signInRequired)
        #expect(YouTubePlayability.from(status: "ERROR", reason: "This video is unavailable") == .unavailable(.removed))
        #expect(YouTubePlayability.from(status: "AGE_VERIFICATION_REQUIRED", reason: nil) == .ageRestricted)
        #expect(YouTubePlayability.from(status: "UNPLAYABLE", reason: "This video is not available in your country") == .unavailable(.regionLocked))
        #expect(YouTubePlayability.from(status: "UNPLAYABLE", reason: "Available with Music Premium") == .unavailable(.premiumOnly))
    }

    @Test func onlyUnchangeableCausesBecomeVerdicts() {
        #expect(YouTubePlayability.botCheck.verdict == nil)
        #expect(YouTubePlayability.tokenRequired.verdict == nil)
        #expect(YouTubePlayability.signInRequired.verdict == nil)
        #expect(YouTubePlayability.ageRestricted.verdict == .ageRestricted)
        #expect(YouTubePlayability.unavailable(.removed).verdict == .removed)
        #expect(YouTubePlayability.botCheck.isRetryable && !YouTubePlayability.unavailable(.removed).isRetryable)
    }

    // MARK: entry-point discovery (excerpt of a real player script, build b485e332)

    private static let playerExcerpt = """
    zJa=function(a,b,c,d){var e=[];for(let k of c){if(!k.url)continue}return e};
    $o=function(a,b,c){b=b===void 0?"":b;c=c===void 0?"":c;a=new g.Xo(a,!0);a.set("alr","yes");c&&(c=Yo(2,7910,Zo(18,237,c)),a[ca[20]](b,se(8,5744,c)));return a};
    ap=function(a){g.Q.call(this);var b=this};x={signatureTimestamp:20779,autonavState:1};
    """

    @Test func findsTheSignatureCallAndUrlClassInARealScript() {
        let e = YouTubeEntryExtractor.entry(fromScript: Self.playerExcerpt)
        #expect(e == YTMCipherEntry(sig: "Yo(2,7910,INPUT)", nClass: "Xo", sts: 20779))
    }

    @Test func discoveryFailsClosedOnUnknownShapes() {
        #expect(YouTubeEntryExtractor.entry(fromScript: "var a=1;") == nil)
        #expect(YouTubeEntryExtractor.entry(fromScript: "a=new g.Xo(a,!0);a.set(\"alr\",\"yes\");c&&(c=evil();alert(1)") == nil)
    }

    // MARK: attestation

    @Test func parsesTheChallengeAndRejectsForeignScripts() {
        let good = """
        {"bgChallenge":{"interpreterUrl":{"privateDoNotAccessOrElseTrustedResourceUrlWrappedValue":"//www.google.com/js/th/abc.js"},"program":"PROG","globalName":"trayride"}}
        """
        let c = YouTubeAttestation.parseChallenge(Data(good.utf8))
        #expect(c == YouTubeAttestation.Challenge(interpreterURL: "https://www.google.com/js/th/abc.js", program: "PROG", globalName: "trayride"))
        let foreign = good.replacingOccurrences(of: "//www.google.com", with: "//evil.example")
        #expect(YouTubeAttestation.parseChallenge(Data(foreign.utf8)) == nil)
        let badName = good.replacingOccurrences(of: "trayride", with: "a;b")
        #expect(YouTubeAttestation.parseChallenge(Data(badName.utf8)) == nil)
        #expect(YouTubeAttestation.parseChallenge(Data("{}".utf8)) == nil)
    }

    @Test func parsesTheIntegrityAnswerAndWebsafeBase64() {
        let i = YouTubeAttestation.parseIntegrity(Data(#"["QUJD",43200,600,"x"]"#.utf8))
        #expect(i == YouTubeAttestation.Integrity(token: "QUJD", ttl: 43200, refreshThreshold: 600))
        #expect(YouTubeAttestation.decodeWebsafe("QUJD") == [65, 66, 67])
        #expect(YouTubeAttestation.websafe([251, 255, 254]) == "-__-")
        #expect(YouTubeAttestation.decodeWebsafe("-__-") == [251, 255, 254])
        #expect(YouTubeAttestation.visitorBinding("Cgt%3D%3D") == "Cgt==")
        #expect(String(decoding: YouTubeAttestation.generateBody(botguardResponse: "r"), as: UTF8.self) == #"["O43z0dpjhgX20SCx4KAo","r"]"#)
    }

    private func transport(_ log: CallLog, challenge: Bool = true) -> YouTubePoTokenTransport {
        YouTubePoTokenTransport { req in
            let u = req.url?.absoluteString ?? ""
            log.add(u)
            if u.contains("att/get") { return (challenge ? Data(#"{"bgChallenge":{"interpreterUrl":"//www.google.com/js/th/x.js","program":"P","globalName":"g1"}}"#.utf8) : Data("{}".utf8), 200) }
            if u.contains("/js/th/") { return (Data("/*js*/".utf8), 200) }
            if u.contains("GenerateIT") { return (Data(#"["QUJD",3600,600]"#.utf8), 200) }
            return (Data(), 404)
        }
    }

    @Test func providerMintsAndCachesPerVisitorAndVideo() async {
        let log = CallLog()
        let p = YouTubePoTokenProvider(transport: transport(log), runner: StubRunner())
        let s1 = await p.sessionToken(visitorData: "Cgt%3D")
        #expect(s1 == "tok-Cgt=")
        let s2 = await p.sessionToken(visitorData: "Cgt%3D")
        #expect(s2 == s1)
        let v = await p.streamingToken(videoID: "vid00000001")
        #expect(v == "tok-vid00000001")
        #expect(log.all.filter { $0.contains("GenerateIT") }.count == 1)
    }

    @Test func providerFailsQuietlyAndBacksOff() async {
        let log = CallLog()
        let p = YouTubePoTokenProvider(transport: transport(log, challenge: false), runner: StubRunner())
        #expect(await p.sessionToken(visitorData: "v") == nil)
        let first = log.all.count
        #expect(await p.sessionToken(visitorData: "v") == nil)
        #expect(log.all.count == first, "a failed start is not retried at once")
        let q = YouTubePoTokenProvider(transport: transport(CallLog()), runner: StubRunner(fail: true))
        #expect(await q.sessionToken(visitorData: "v") == nil)
        #expect(await q.streamingToken(videoID: "vid00000001") == nil)
    }

    @Test func tokenRequestsWithoutAVisitorGetNothing() async {
        let p = YouTubePoTokenProvider(transport: transport(CallLog()), runner: StubRunner())
        #expect(await p.streamingToken(videoID: "vid00000001") == nil)
    }

    // MARK: UMP and the streaming request

    @Test func umpVarintsRoundTrip() {
        for v in [0, 1, 127, 128, 16_383, 16_384, 2_097_151, 2_097_152, 268_435_455, 268_435_456, 4_000_000_000] {
            let b = YouTubeUMP.encodeVarint(v)
            let r = YouTubeUMP.readVarint(b, at: 0)
            #expect(r?.value == v && r?.length == b.count, "value \(v)")
        }
        #expect(YouTubeUMP.readVarint([0xC0], at: 0) == nil, "cut-off number")
    }

    @Test func umpPartsParseAndReportATruncatedTail() {
        let parts = [YouTubeUMP.Part(type: 20, payload: [1, 2, 3]), YouTubeUMP.Part(type: 21, payload: Array(repeating: 9, count: 300)), YouTubeUMP.Part(type: 22, payload: [])]
        let bytes = YouTubeUMP.encode(parts)
        let ok = YouTubeUMP.parse(bytes)
        #expect(ok.parts == parts && ok.complete)
        let cut = YouTubeUMP.parse(Array(bytes.dropLast(150)))
        #expect(cut.parts.count == 1 && !cut.complete)
    }

    @Test func sabrAnswerReadsControlPartsAndCountsMedia() {
        let status = YTMWire.field(1, varint: 2)
        let redirect = YTMWire.field(1, string: "https://rr4---sn-x.googlevideo.com/videoplayback?a=b")
        let policy = YTMWire.field(4, varint: 1500) + YTMWire.field(7, bytes: [7, 7])
        let body = YouTubeUMP.encode([
            .init(type: 58, payload: status), .init(type: 43, payload: redirect), .init(type: 35, payload: policy),
            .init(type: 20, payload: [1]), .init(type: 21, payload: [1] + Array(repeating: 0, count: 99)), .init(type: 22, payload: [1])
        ])
        let a = YouTubeSabr.read(body)
        #expect(a.protection == 2 && a.needsToken)
        #expect(a.redirect == "https://rr4---sn-x.googlevideo.com/videoplayback?a=b")
        #expect(a.backoffMs == 1500 && a.playbackCookie == [7, 7])
        #expect(a.mediaBytes == 99 && a.segments == 1 && a.complete)
    }

    @Test func sabrAnswerIgnoresRedirectsToOtherHosts() {
        let r = YTMWire.field(1, string: "https://evil.example/videoplayback")
        #expect(YouTubeSabr.read(YouTubeUMP.encode([.init(type: 43, payload: r)])).redirect == nil)
        #expect(YouTubeSabr.read(YouTubeUMP.encode([.init(type: 43, payload: YTMWire.field(1, string: "http://a.googlevideo.com/x"))])).redirect == nil)
    }

    @Test func sabrRequestCarriesConfigFormatAndContext() throws {
        let config = YouTubeAttestation.websafe([1, 2, 3, 4])
        let req = YouTubeSabr.Request(client: .init(clientID: 2, clientVersion: "2.0"), ustreamerConfig: config,
                                      audio: .init(itag: 140, lastModified: 1_700_000_000, xtags: nil), poToken: [9, 9], playbackCookie: [5])
        let body = try #require(YouTubeSabr.body(req))
        let f = try #require(YTMWire.parse(body))
        #expect(f.map(\.number) == [1, 5, 16, 19])
        #expect(f[1].value == .bytes([1, 2, 3, 4]))
        guard case .bytes(let fmt) = f[2].value, let fm = YTMWire.parse(fmt) else { Issue.record("format missing"); return }
        #expect(fm[0].value == .varint(140) && fm[1].value == .varint(1_700_000_000))
        guard case .bytes(let ctx) = f[3].value, let cf = YTMWire.parse(ctx) else { Issue.record("context missing"); return }
        #expect(cf.map(\.number) == [1, 2, 3])
        #expect(cf[1].value == .bytes([9, 9]) && cf[2].value == .bytes([5]))
        #expect(YouTubeSabr.body(.init(client: .init(clientID: 2, clientVersion: "2.0"), ustreamerConfig: "!!", audio: .init(itag: 140))) == nil)
    }

    @Test func sabrRequestURLIsPinnedToGoogleVideoAndNumbered() {
        let u = YouTubeSabr.requestURL(base: "https://rr3---sn-a.googlevideo.com/videoplayback?sabr=1&rn=9", cpn: "abc", number: 2)
        #expect(u?.absoluteString.contains("rn=2") == true)
        #expect(u?.absoluteString.contains("rn=9") == false)
        #expect(u?.absoluteString.contains("alr=yes") == true && u?.absoluteString.contains("cpn=abc") == true)
        #expect(YouTubeSabr.requestURL(base: "https://evil.example/videoplayback", cpn: "a", number: 0) == nil)
    }

    @Test func findsTheEntryInTheTvVariantToo() {
        let tv = #"function lS(a,b,c){b=b===void 0?"":b;c=c===void 0?"":c;a=new Pa(a,!0);a.set("alr","yes");c&&(c=ya(2,7910,ia(16,8582,c)),a[h[38]](b,ka(2,5754,c)));return a}var x={signatureTimestamp:20779};"#
        #expect(YouTubeEntryExtractor.entry(fromScript: tv) == YTMCipherEntry(sig: "ya(2,7910,INPUT)", nClass: "Pa", sts: 20779))
    }

    @Test func exportsAreInjectedBeforeEitherClosureEnd() {
        let e = YTMCipherEntry(sig: "Yo(2,7910,INPUT)", nClass: "Xo", sts: nil)
        let main = YTMPlayerExports.inject(into: "(function(g){var a=1;})(_yt_player);", entry: e)
        #expect(main.contains("window.__ytmSig") && main.hasSuffix("})(_yt_player);"))
        #expect(main.contains(",true)"), "the address class is built with its second argument")
        let tv = YTMPlayerExports.inject(into: "(function(){'use strict';var a=1;}).call(this);", entry: e)
        #expect(tv.contains("window.__ytmN") && tv.hasSuffix("}).call(this);"))
    }
}
