import Foundation
import Testing
@testable import REDDY

// All tests use a small synthetic player script that mimics the structure of the real one. They say nothing about whether the patterns match
// YouTube's live script today; that has not been checked.

private let fixtureScript = """
var Qx=function(){return 1};var tbl=["_","x","y"];
var Xy={rv:function(a){a.reverse()},sp:function(a,b){a.splice(0,b)},sw:function(a,b){var c=a[0];a[0]=a[b%a.length];a[b%a.length]=c}};
var Zz=function(a){a=a.split("");Xy.sw(a,3);Xy.rv(a,12);Xy.sp(a,2);return a.join("")};
var nfn=function(a){var b=a.split(""),c=tbl;try{b.reverse();b.push(c[1])}catch(d){return"enhanced_except_AB_"+a}return b.join("")};
var Arr=[nfn];
var cfg={signatureTimestamp:20123,other:1};
function go(a){if(b=a.get("n"))&&(b=Arr[0](b),a.set("n",b))}
"""

private final class CountingTransport: MusicHTTPTransport, @unchecked Sendable {
    private let lock = NSLock(); private(set) var requests: [String] = []
    let handler: @Sendable (URL) -> (Int, String)
    init(_ h: @escaping @Sendable (URL) -> (Int, String)) { handler = h }
    var count: Int { lock.withLock { requests.count } }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url ?? URL(fileURLWithPath: "/")
        lock.withLock { requests.append(url.absoluteString) }
        let (code, body) = handler(url)
        guard let r = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil) else { throw MusicError.network("stub") }
        return (Data(body.utf8), r)
    }
}

private func scriptServer(script: String) -> CountingTransport {
    CountingTransport { url in
        if url.path == "/iframe_api" { return (200, #"var a="https:\/\/www.youtube.com\/s\/player\/abcd1234\/www-widgetapi.vflset\/www-widgetapi.js";"#) }
        if url.path.hasSuffix("base.js") { return (200, script + String(repeating: "/*pad*/", count: 300)) }
        return (404, "")
    }
}

@Suite struct YouTubePlayerScriptTests {
    @Test func timestampAndHash() {
        #expect(YouTubePlayerScript.signatureTimestamp(in: fixtureScript) == 20123)
        #expect(YouTubePlayerScript.signatureTimestamp(in: "x") == nil)
        #expect(YouTubePlayerScript.playerHash(inIframeAPI: #"\/s\/player\/abcd1234\/www-widgetapi.js"#) == "abcd1234")
        #expect(YouTubePlayerScript.scriptPath(inPage: #"{"jsUrl":"\/s\/player\/abcd1234\/player_ias.vflset\/en_US\/base.js"}"#) == "/s/player/abcd1234/player_ias.vflset/en_US/base.js")
    }

    @Test func bracesRespectStringsRegexAndComments() {
        let text = #"""
{ var a="}"; var b='{'; var r=/[}]\//; // }
var c=1/2; /* } */ if(x){y=[1,{z:2}]} return /}/.test(a) }tail
"""#
        let arr = Array(text.utf16)
        let close = YouTubePlayerScript.matchClose(arr, open: 0)
        #expect(close != nil)
        #expect(close.map { String(utf16CodeUnits: Array(arr[($0 + 1)...]), count: arr.count - $0 - 1) } == "tail")
        #expect(YouTubePlayerScript.matchClose(Array("{ never closed".utf16), open: 0) == nil)
    }

    @Test func decipherExtractedAndRuns() async throws {
        let js = try #require(YouTubePlayerScript.extractDecipher(from: fixtureScript))
        #expect(js.contains("var Xy="))
        #expect(!js.contains("nfn"))
        let out = try await YouTubeJSRunner.call(program: js, function: "__ytsig", argument: "abcdefghij")
        #expect(out == "hgfeacbd")
    }

    @Test func nTransformExtractedWithConstantsAndRuns() async throws {
        let js = try #require(YouTubePlayerScript.extractNTransform(from: fixtureScript))
        #expect(js.contains("var tbl="))
        let out = try await YouTubeJSRunner.call(program: js, function: "__ytn", argument: "abc")
        #expect(out == "cbax")
    }

    @Test func nTransformFoundThroughMarkerWhenCallSiteChanges() throws {
        let changed = fixtureScript.replacingOccurrences(of: #"if(b=a.get("n"))&&(b=Arr[0](b),a.set("n",b))"#, with: "noop()")
        #expect(YouTubePlayerScript.extractNTransform(from: changed) != nil)
    }

    @Test func unknownScriptYieldsNothing() {
        #expect(YouTubePlayerScript.extractDecipher(from: "var a=1;function f(){return 2}") == nil)
        #expect(YouTubePlayerScript.extractNTransform(from: "var a=1;") == nil)
    }
}

@Suite struct YouTubeSignatureURLTests {
    @Test func cipherParsingDefaultsParameterName() throws {
        let c = try #require(YouTubeSignature.parseCipher("s=AB%3DCD&url=https%3A%2F%2Fr1.example%2Fv%3Fa%3D1%26n%3Dxyz%26expire%3D1900000000"))
        #expect(c.s == "AB=CD")
        #expect(c.sp == "signature")
        #expect(c.url == "https://r1.example/v?a=1&n=xyz&expire=1900000000")
        let d = try #require(YouTubeSignature.parseCipher("sp=sig&s=Q&url=https%3A%2F%2Fh%2Fv%3Fa%3D1"))
        #expect(d.sp == "sig")
        #expect(YouTubeSignature.parseCipher("s=Q") == nil)
    }

    @Test func rebuildReplacesNAndAppendsSignature() {
        let url = YouTubeSignature.rebuild(url: "https://h/v?a=1&n=old&expire=1900000000", signatureParam: "sig", signature: "a b+c", n: "new")
        #expect(url == "https://h/v?a=1&n=new&expire=1900000000&sig=a%20b%2Bc")
        #expect(YouTubeSignature.nParameter(in: url) == "new")
        #expect(YouTubeAudio.expiry(of: url) == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(YouTubeSignature.rebuild(url: "https://h/v?a=1", signatureParam: nil, signature: nil, n: "zzz") == "https://h/v?a=1")
    }
}

@Suite struct YouTubeSignatureServiceTests {
    @Test func timeoutOnRunawayScript() async {
        do {
            _ = try await YouTubeJSRunner.call(program: "var __ytsig=function(a){while(true){}}", function: "__ytsig", argument: "x", timeout: 0.3)
            Issue.record("expected a timeout")
        } catch {
            #expect(error as? YouTubeSignatureError == .scriptTimedOut)
        }
    }

    @Test func scriptErrorsAreTyped() async {
        do {
            _ = try await YouTubeJSRunner.call(program: "var __ytsig=function(a){throw new Error('x')}", function: "__ytsig", argument: "x")
            Issue.record("expected an error")
        } catch {
            guard case .scriptFailed = error as? YouTubeSignatureError else { Issue.record("wrong error \(error)"); return }
        }
    }

    @Test func playableURLFromCipherAndCachesScript() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yt-sig-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = scriptServer(script: fixtureScript)
        let service = YouTubeSignatureService(http: MusicHTTP(transport: transport), cacheDirectory: dir)
        #expect(await service.signatureTimestamp() == 20123)
        let cipher = "s=abcdefghij&sp=sig&url=" + YouTubeSignature.encode("https://h/v?a=1&n=abc&expire=1900000000")
        let url = try await service.playableURL(url: nil, cipher: cipher)
        #expect(url == "https://h/v?a=1&n=cbax&expire=1900000000&sig=hgfeacbd")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("abcd1234.js").path))
        // A second service with the same directory reads the script from disk instead of fetching it again.
        let again = scriptServer(script: "unused")
        let second = YouTubeSignatureService(http: MusicHTTP(transport: again), cacheDirectory: dir)
        #expect(await second.signatureTimestamp() == 20123)
        #expect(again.requests.allSatisfy { !$0.hasSuffix("base.js") })
        // A direct URL only gets the n fix.
        #expect(await service.unthrottled("https://h/v?n=abc") == "https://h/v?n=cbax")
        #expect(await service.unthrottled("https://h/v?x=1") == "https://h/v?x=1")
    }

    @Test func failureIsCachedForThirtyMinutes() async throws {
        final class Clock: @unchecked Sendable { let lock = NSLock(); var t = Date(timeIntervalSince1970: 1_000_000)
            func get() -> Date { lock.lock(); defer { lock.unlock() }; return t }
            func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() } }
        let clock = Clock()
        let transport = scriptServer(script: "var nothing=1;")
        let service = YouTubeSignatureService(http: MusicHTTP(transport: transport), cacheDirectory: nil, now: { clock.get() })
        await #expect(throws: YouTubeSignatureError.playerScriptChanged) { try await service.currentPlan() }
        let after = transport.count
        #expect(after > 0)
        await #expect(throws: YouTubeSignatureError.playerScriptChanged) { try await service.currentPlan() }
        #expect(transport.count == after)
        clock.advance(31 * 60)
        await #expect(throws: YouTubeSignatureError.playerScriptChanged) { try await service.currentPlan() }
        #expect(transport.count > after)
    }

    @Test func providerParsesCipheredFormats() {
        let obj: [String: Any] = ["streamingData": ["adaptiveFormats": [
            ["mimeType": "audio/webm; codecs=\"opus\"", "signatureCipher": "s=A&url=https%3A%2F%2Fh%2Fv", "bitrate": 130_000],
            ["mimeType": "audio/mp4; codecs=\"mp4a.40.2\"", "url": "https://h/direct", "bitrate": 128_000],
            ["mimeType": "video/mp4", "url": "https://h/video"],
            ["mimeType": "audio/webm"]
        ]]]
        let raws = YouTubeMusicProvider.rawFormats(obj)
        #expect(raws.count == 3)
        #expect(raws.first?.cipher != nil)
        #expect(YouTubeMusicProvider.parseStreams(obj, headers: [:]).count == 1)
    }
}
