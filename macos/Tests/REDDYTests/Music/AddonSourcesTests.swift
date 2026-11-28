import Foundation
import Testing
@testable import REDDY

// Addon sources and the quality chain: decoding from canned replies, matching, ranking, the swap rule, failure memory, address rules. No network.

private final class AddonStubTransport: MusicHTTPTransport, @unchecked Sendable {
    typealias Reply = (status: Int, body: String, headers: [String: String])
    private let lock = NSLock()
    private var routes: [(String, @Sendable (URLRequest) -> Reply)] = []
    private(set) var requests: [URLRequest] = []

    func on(_ pathSuffix: String, _ handler: @escaping @Sendable (URLRequest) -> Reply) { lock.lock(); routes.append((pathSuffix, handler)); lock.unlock() }
    func on(_ pathSuffix: String, status: Int = 200, json: String) { on(pathSuffix) { _ in (status, json, [:]) } }
    func count(_ suffix: String) -> Int { lock.lock(); defer { lock.unlock() }; return requests.filter { Self.encodedPath($0).hasSuffix(suffix) }.count }

    static func encodedPath(_ r: URLRequest) -> String { r.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } ?? "" }

    private func lookup(_ request: URLRequest) -> (@Sendable (URLRequest) -> Reply)? {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return routes.last { Self.encodedPath(request).hasSuffix($0.0) }?.1
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let handler = lookup(request)
        let reply: Reply = handler?(request) ?? (status: 404, body: "", headers: [:])
        let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        return (Data(reply.body.utf8), resp)
    }
}

private final class MemorySecrets: ScrobbleSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func read(_ account: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func write(_ value: String, account: String) { lock.lock(); values[account] = value; lock.unlock() }
    func remove(_ account: String) { lock.lock(); values[account] = nil; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock(); private var t = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

private func track(_ title: String, artist: String = "Daft Punk", album: String? = nil, seconds: Int64 = 200, video: Bool? = nil) -> MusicTrack {
    var t = MusicTrack(id: "t1", providerID: "spotify", title: title, durationMs: seconds * 1000, artists: [MusicArtistRef(id: "a", name: artist)])
    if let album { t.album = MusicAlbumRef(id: "al", title: album) }
    t.isVideo = video
    return t
}
private func row(_ id: String, _ title: String, artist: String? = "Daft Punk", album: String? = nil, dur: Double? = 200, quality: String? = nil, format: String? = nil) -> AddonRow {
    AddonRow(id: id, title: title, artist: artist, album: album, durationSec: dur, artworkURL: nil, format: format, audioQuality: quality, audioModes: [], atmosFlag: false, streamURL: nil)
}
private let base = URL(string: "https://addon.example.com/tok123")!
private func streamObject(_ json: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:] }
private func parseStream(_ json: String, row: AddonRow? = nil, own: Bool = false) -> AddonStreamOutcome {
    AddonStreamParser.parse(streamObject(json), row: row, base: base, ownServer: own)
}
private func fastClient(_ t: AddonStubTransport, token: String? = nil, clock: TestClock = TestClock()) -> AddonClient {
    AddonClient(endpoint: AddonEndpoint(id: "x", name: "X", base: base, token: token, ownServer: false), http: MusicHTTP(transport: t),
                now: { clock.now }, sleep: { _ in })
}

@Suite("Addon manifest, search and stream decoding")
struct AddonDecodingTests {
    @Test func manifestFields() throws {
        let json = #"{"id":"com.example.hifi","name":"Hi-Fi","version":"2.1","resources":["Search","stream"],"allowDownloads":0,"checkValidLossless":"yes","settings":[{"key":"quality","default":"FLAC","options":[{"value":"FLAC","label":"CD"},{"value":"HI_RES","label":"Hi-Res"}]},{"key":"region","default":"us"}],"extra":{"ignored":true}}"#
        let m = try #require(AddonManifest.parse(streamObject(json)))
        #expect(m.id == "com.example.hifi" && m.displayName == "Hi-Fi" && m.version == "2.1")
        #expect(m.resources == ["search", "stream"])
        #expect(m.allowDownloads == false && m.checkValidLossless == true)
        #expect(m.qualityOptions.map(\.value) == ["FLAC", "HI_RES"])
        #expect(m.settings.first { $0.key == "region" }?.defaultValue == "us")
        #expect(AddonManifest.parse(streamObject(#"{"name":"no id"}"#)) == nil)
    }

    @Test func searchRowsDropBlankAndKeepFields() {
        let json = #"{"tracks":[{"id":"1","title":"One More Time","artist":"Daft Punk","album":"Discovery","duration":320.5,"artworkURL":"https://x/a.jpg","audioQuality":"LOSSLESS","format":"flac","streamURL":"https://cdn.example.com/1.flac"},{"id":"","title":"No id"},{"id":"3","title":" "},{"id":7,"title":"Numeric id","atmos":1,"audioModes":["DOLBY_ATMOS"]}],"other":[1]}"#
        let rows = AddonRow.parseList(streamObject(json))
        #expect(rows.count == 2)
        #expect(rows[0].durationSec == 320.5 && rows[0].tier == .lossless && rows[0].streamURL != nil && rows[0].isAtmos == false)
        #expect(rows[1].id == "7" && rows[1].isAtmos && rows[1].tier == nil)
        #expect(AddonRow.parseList(streamObject(#"{"items":[]}"#)).isEmpty)
    }

    @Test func tierWordsFollowTheSpecOrder() {
        #expect(AddonTier.infer("FLAC 16-bit") == .lossless)
        #expect(AddonTier.infer("MP3 128") == .low)         // low words are checked before high words
        #expect(AddonTier.infer("AAC") == .high)
        #expect(AddonTier.infer("mystery") == nil)
    }

    @Test func losslessStreamCarriesDepthAndRate() throws {
        guard case .stream(let r) = parseStream(#"{"url":"https://cdn.example.com/a.flac","quality":"FLAC 24-bit / 96 kHz"}"#) else { Issue.record("expected stream"); return }
        #expect(r.quality.isLossless == true && r.quality.bitDepth == 24 && r.quality.sampleRate == 96_000 && r.quality.kbps == nil)
        #expect(r.stream.isLossless && r.stream.sampleRate == 96_000)
        #expect(r.quality.summary == "FLAC · 24-bit · 96 kHz")
    }

    @Test func lossyStreamKbpsAndInference() throws {
        guard case .stream(let a) = parseStream(#"{"url":"https://cdn.example.com/a.m4a","codec":"aac","bitrate":320000}"#) else { Issue.record("expected stream"); return }
        #expect(a.quality.kbps == 320 && a.quality.isLossless == false && a.quality.kbpsInferred == false && a.stream.bitrate == 320)
        guard case .stream(let b) = parseStream(#"{"url":"https://cdn.example.com/b","audioQuality":"HIGH","format":"mp3"}"#) else { Issue.record("expected stream"); return }
        #expect(b.quality.kbps == 320 && b.quality.kbpsInferred && b.quality.codec == "mp3" && !b.stream.isLossless)
    }

    @Test func refusedStreams() {
        func isMiss(_ json: String, row: AddonRow? = nil) -> Bool { if case .miss = parseStream(json, row: row) { true } else { false } }
        #expect(isMiss(#"{"error":"ARL required"}"#))
        #expect(isMiss(#"{"url":"file:///etc/passwd"}"#))
        #expect(isMiss(#"{"url":"http://cdn.example.com/a.flac"}"#))                    // public http
        #expect(isMiss(#"{"url":"https://127.0.0.1/a.flac"}"#))                          // private address without the tick
        #expect(isMiss(#"{"url":"https://cdn.example.com/a.flac","encrypted":true}"#))
        #expect(isMiss(#"{"url":"https://cdn.example.com/a.mp4","encrypted":"widevine"}"#))
        #expect(isMiss(#"{"url":"https://cdn.example.com/a.mp4","audioMode":"DOLBY_ATMOS"}"#))
        #expect(isMiss(#"{"url":"https://cdn.example.com/a.mpd","manifest":"dash"}"#))
        #expect(isMiss(#"{"url":"https://addon.example.com/https://addon.example.com/a.flac"}"#))   // doubled origin
        #expect(!isMiss(#"{"url":"https://proxy.example.com/get?u=https://addon.example.com/a.flac","codec":"flac"}"#))
        #expect(!isMiss(#"{"encrypted":"none","url":"https://cdn.example.com/a.flac"}"#))
        let withRow = AddonRow(id: "1", title: "x", artist: nil, album: nil, durationSec: nil, artworkURL: nil, format: nil, audioQuality: nil, audioModes: [], atmosFlag: false, streamURL: "https://cdn.example.com/row.mp3")
        #expect(!isMiss("{}", row: withRow))       // the row's own address is the fallback
    }

    @Test func hlsIsAnnounced() {
        guard case .stream(let r) = parseStream(#"{"url":"https://cdn.example.com/play","manifest":"hls","bitrate":256}"#) else { Issue.record("expected stream"); return }
        #expect(r.stream.proto == .hls)
        guard case .stream(let r2) = parseStream(#"{"url":"https://cdn.example.com/a.flac","format":"flac"}"#) else { Issue.record("expected stream"); return }
        #expect(r2.stream.proto == .progressive)      // a codec word is not a transport
    }
}

@Suite("Quality comparison, swap rule and download floor")
struct AddonQualityTests {
    private func lossy(_ k: Int, inferred: Bool = false) -> SourceQuality { SourceQuality(codec: "aac", kbps: k, kbpsInferred: inferred, sampleRate: nil, bitDepth: nil, isLossless: false) }
    private func flac(_ depth: Int, _ rate: Int) -> SourceQuality { SourceQuality(codec: "flac", kbps: nil, sampleRate: rate, bitDepth: depth, isLossless: true) }
    private var atmos: SourceQuality { SourceQuality(codec: "eac3-joc", kbps: 768, sampleRate: nil, bitDepth: nil, isLossless: false, isAtmos: true) }

    @Test func orderIsAtmosThenLosslessThenKbps() {
        #expect(SourceQuality.isBetter(atmos, than: flac(24, 192_000)))
        #expect(SourceQuality.isBetter(flac(16, 44_100), than: lossy(320)))
        #expect(SourceQuality.isBetter(flac(24, 44_100), than: flac(16, 96_000)))      // depth first
        #expect(SourceQuality.isBetter(flac(24, 96_000), than: flac(24, 48_000)))
        #expect(SourceQuality.isBetter(lossy(320), than: lossy(256)))
        #expect(!SourceQuality.isBetter(lossy(256), than: lossy(256)))
    }

    @Test func swapNeedsNinetySixMore() {
        #expect(SourceQuality.worthSwapping(playing: lossy(128), candidate: lossy(224)))
        #expect(!SourceQuality.worthSwapping(playing: lossy(128), candidate: lossy(223)))
        #expect(!SourceQuality.worthSwapping(playing: lossy(128, inferred: true), candidate: lossy(320)))
        #expect(!SourceQuality.worthSwapping(playing: lossy(128), candidate: lossy(320, inferred: true)))
        #expect(SourceQuality.worthSwapping(playing: lossy(320), candidate: flac(16, 44_100)))
        #expect(!SourceQuality.worthSwapping(playing: flac(16, 44_100), candidate: lossy(320)))
        #expect(!SourceQuality.worthSwapping(playing: atmos, candidate: flac(24, 96_000)))
        #expect(SourceQuality.worthSwapping(playing: lossy(320), candidate: atmos))
    }

    @Test func downloadFloorIs256() {
        #expect(!lossy(256).meetsDownloadFloor)
        #expect(lossy(257).meetsDownloadFloor)
        #expect(!lossy(320, inferred: true).meetsDownloadFloor)
        #expect(flac(16, 44_100).meetsDownloadFloor)
        #expect(!SourceQuality(codec: nil, kbps: nil, sampleRate: nil, bitDepth: nil, isLossless: nil).meetsDownloadFloor)
    }

    @Test func choosePrefersQualityThenRank() {
        func cand(_ id: String, _ rank: Int, _ q: SourceQuality, below: Bool = false) -> MusicSourceChain.Candidate {
            MusicSourceChain.Candidate(memberID: id, memberName: id, rank: rank, stream: MusicStream(url: "https://x/\(id)", codec: "x", container: "x"), quality: q, page: nil, belowRequest: below)
        }
        let a = cand("a", 0, lossy(256)), b = cand("b", 1, flac(16, 44_100)), c = cand("c", 2, flac(16, 44_100))
        #expect(MusicSourceChain.choose([a, c, b], request: .best)?.memberID == "b")      // equal quality: the higher-ranked source
        #expect(MusicSourceChain.choose([a, b], request: .capped(96))?.memberID == "a")  // a cap follows the person's order
        let low = cand("low", 0, lossy(128), below: true), high = cand("high", 5, flac(16, 44_100))
        #expect(MusicSourceChain.choose([low, high], request: .lossless)?.memberID == "high")
        #expect(MusicSourceChain.choose([low], request: .lossless)?.memberID == "low")   // the floor when nothing satisfies it
        #expect(MusicSourceChain.choose([], request: .best) == nil)
    }

    @Test func lengthProbeFlagsPreviews() {
        let lossless = flac(16, 44_100)
        #expect(SourceLengthProbe.isTooShort(bytes: 500_000, expectedSeconds: 200, slackSeconds: 5, quality: lossless))     // 20 s at 200 kbps
        #expect(!SourceLengthProbe.isTooShort(bytes: 6_000_000, expectedSeconds: 200, slackSeconds: 5, quality: lossless))
        #expect(!SourceLengthProbe.isTooShort(bytes: nil, expectedSeconds: 200, slackSeconds: 5, quality: lossless))
        #expect(SourceLengthProbe.isTooShort(bytes: 240_000, expectedSeconds: 200, slackSeconds: 5, quality: lossy(320)))   // floor 64 kbps: 30 s
    }
}

@Suite("Matching and scoring addon rows")
struct AddonMatcherTests {
    @Test func versionWordsMustMatchBothWays() {
        let plain = track("Get Lucky")
        let rows = [row("live", "Get Lucky (Live)"), row("remix", "Get Lucky - Remix"), row("inst", "Get Lucky (Instrumental)"), row("ok", "Get Lucky")]
        #expect(AddonMatcher.rank(track: plain, rows: rows).map(\.row.id) == ["ok"])
        let live = track("Get Lucky (Live at Coachella)")
        #expect(AddonMatcher.rank(track: live, rows: rows).map(\.row.id) == ["live"])
    }

    @Test func packagingIsIgnored() {
        let t = track("Paniyon Sa (From \"Satyamev Jayate\")", artist: "Aishwarya Majmudar")
        let r = row("1", "Paniyon Sa", artist: "Aishwarya Majmudar", dur: 200)
        #expect(AddonMatcher.rank(track: t, rows: [r]).count == 1)
        let noisy = track("Song Name (Official Video) feat. Someone")
        #expect(AddonMatcher.rank(track: noisy, rows: [row("1", "Song Name")]).count == 1)
        #expect(AddonMatcher.rank(track: track("Radio Edit Song (Radio Edit)"), rows: [row("1", "Radio Edit Song")]).count == 1)   // neutral asides do not count
    }

    @Test func accentsFold() {
        let t = track("Simarik", artist: "Tarkan")
        #expect(AddonMatcher.rank(track: track("Müslüm", artist: "Tarkan"), rows: [row("1", "Muslum", artist: "Tarkan")]).count == 1)
        #expect(AddonMatcher.rank(track: track("Café del Mar", artist: "Energy 52"), rows: [row("1", "Cafe del Mar", artist: "Energy 52")]).count == 1)
    }

    @Test func artistRules() {
        let t = track("Time", artist: "Pink Floyd")
        #expect(AddonMatcher.rank(track: t, rows: [row("1", "Time", artist: "Some Cover Band", dur: nil)]).isEmpty)
        #expect(AddonMatcher.rank(track: track("Hello", artist: "Queen"), rows: [row("1", "Hello", artist: "Queensryche", dur: nil)]).isEmpty)   // whole words only
        #expect(AddonMatcher.rank(track: t, rows: [row("1", "Time", artist: "Pink Floyd, Roger Waters")]).count == 1)
        // Composer on one side, singer on the other, same length: accepted with a penalty, never ahead of a credited row.
        let swapped = AddonMatcher.rank(track: t, rows: [row("1", "Time", artist: "Someone Else", dur: 201)])
        #expect(swapped.count == 1 && swapped[0].score == 110)
        #expect(AddonMatcher.rank(track: track("Time", artist: "Pink Floyd", video: true), rows: [row("1", "Time", artist: "Someone Else", dur: 201)]).isEmpty)
        let both = AddonMatcher.rank(track: t, rows: [row("a", "Time", artist: "Someone Else", dur: 200), row("b", "Time", artist: "Pink Floyd", dur: 200)])
        #expect(both.map(\.row.id) == ["b"])
    }

    @Test func durationRules() {
        let t = track("Time", artist: "Pink Floyd", seconds: 200)
        #expect(AddonMatcher.rank(track: t, rows: [row("1", "Time", artist: "Pink Floyd", dur: 260)]).count == 1)       // shared artist may drift to 90 s
        #expect(AddonMatcher.rank(track: t, rows: [row("1", "Time", artist: "Pink Floyd", dur: 310)]).isEmpty)
        #expect(AddonMatcher.rank(track: t, rows: [row("1", "Time", artist: nil, dur: 245)]).isEmpty)                   // no artist, more than 30 s out
        let ranked = AddonMatcher.rank(track: t, rows: [row("far", "Time", artist: "Pink Floyd", dur: 215), row("tight", "Time", artist: "Pink Floyd", dur: 201)])
        #expect(ranked.map(\.row.id) == ["tight", "far"])
    }

    @Test func albumAgreementBreaksTies() {
        let t = track("Time", artist: "Pink Floyd", album: "The Dark Side of the Moon")
        let ranked = AddonMatcher.rank(track: t, rows: [row("a", "Time", album: "Best Of"), row("b", "Time", album: "The Dark Side Of The Moon")].map { var r = $0; r.artist = "Pink Floyd"; return r })
        #expect(ranked.first?.row.id == "b")
    }

    @Test func openingOrderPrefersLosslessAndTightLength() {
        let rows = [row("mp3", "T", dur: 200, quality: "HIGH"), row("hires", "T", dur: 200, quality: "HI-RES FLAC"), row("flac", "T", dur: 200, quality: "LOSSLESS"), row("short", "T", dur: 30, quality: "HI-RES")]
        #expect(AddonMatcher.preferred(rows, wantedSec: 200, request: .lossless).map(\.id) == ["hires", "flac", "mp3"])
        #expect(AddonMatcher.preferred(rows, wantedSec: 200, request: .best).map(\.id) == ["mp3", "hires", "flac"])
    }

    @Test func primaryArtistAndTitleParts() {
        #expect(AddonMatcher.primaryArtist(["Daft Punk feat. Pharrell", "X"]) == "Daft Punk")
        #expect(AddonMatcher.primaryArtist(["Simon & Garfunkel"]) == "Simon")
        let p = AddonMatcher.parse("Dancing With Myself - Remastered 2002")
        #expect(p.core == "dancingwithmyself" && p.versions.isEmpty)
        #expect(AddonMatcher.parse("Song Instrumental").versions == ["instrumental"])
    }
}

@Suite("Failure memory")
struct AddonFailureMemoryTests {
    @Test func failingSourceIsSkippedThenReturns() {
        let clock = TestClock()
        let m = SourceFailureMemory(now: { clock.now })
        #expect(!m.isSkipped("a"))
        m.recordFailure("a")
        #expect(m.isSkipped("a"))
        clock.advance(59); #expect(m.isSkipped("a"))
        clock.advance(2);  #expect(!m.isSkipped("a"))
        m.recordFailure("a")                            // second failure in a row waits longer
        clock.advance(61); #expect(m.isSkipped("a"))
        clock.advance(300); #expect(!m.isSkipped("a"))
        m.recordFailure("a"); m.recordSuccess("a")
        #expect(!m.isSkipped("a"))
        m.recordFailure("b"); #expect(!m.isSkipped("a") && m.isSkipped("b"))
    }
}

@Suite("Addon addresses")
struct AddonAddressTests {
    @Test func httpsOnlyAndPrivateRules() {
        func v(_ s: String, own: Bool = false) -> String? { AddonURLPolicy.violation(URL(string: s)!, ownServer: own) }
        #expect(v("https://addon.example.com") == nil)
        #expect(v("http://addon.example.com") != nil)
        #expect(v("http://addon.example.com", own: true) != nil)       // the tick never makes a public server plain http
        #expect(v("https://192.168.1.20:8080") != nil)
        #expect(v("http://192.168.1.20:8080", own: true) == nil)
        #expect(v("http://localhost:3000", own: true) == nil)
        #expect(v("http://localhost:3000") != nil)
        #expect(v("https://user:pw@addon.example.com") != nil)
        #expect(v("ftp://addon.example.com") != nil)
        for host in ["10.0.0.5", "172.16.0.1", "172.31.255.1", "169.254.1.1", "127.0.0.1", "100.64.0.1", "nas.local", "printer", "[::1]", "[fd00::1]", "[fe80::1]", "2130706433", "0x7f.0.0.1"] {
            #expect(AddonURLPolicy.isPrivateHost(host), "\(host) should be private")
        }
        for host in ["172.32.0.1", "8.8.8.8", "addon.example.com", "[2606:4700::1111]"] { #expect(!AddonURLPolicy.isPrivateHost(host), "\(host) should be public") }
    }

    @Test func canonicalForm() {
        #expect(AddonFormatDetector.canonicalBase("HTTPS://Addon.Example.COM:443/Tok123/manifest.json")?.absoluteString == "https://addon.example.com/Tok123")
        #expect(AddonFormatDetector.canonicalBase("  https://addon.example.com/  ")?.absoluteString == "https://addon.example.com")
        #expect(AddonFormatDetector.canonicalBase("https://addon.example.com:8443/a/b/?x=1#f")?.absoluteString == "https://addon.example.com:8443/a/b")
        #expect(AddonFormatDetector.canonicalBase("not a url") == nil)
        #expect(AddonFormatDetector.canonicalBase("ftp://x.com") == nil)
    }

    @Test func endpointsEncodeSegments() {
        let u = AddonTransport.endpoint(URL(string: "https://addon.example.com/tok")!, ["stream", "a/b?c"])
        #expect(u?.absoluteString == "https://addon.example.com/tok/stream/a%2Fb%3Fc")
    }

    @Test func detectsFormats() {
        func kind(_ json: String) -> String {
            switch AddonFormatDetector.detect(streamObject(json)) { case .addon: "addon"; case .unsupported(let m): m; case .unknown: "unknown" }
        }
        #expect(kind(#"{"id":"x","name":"X","resources":["search","stream"]}"#) == "addon")
        #expect(kind(#"{"id":"x","version":"1"}"#) == "addon")
        #expect(kind(#"{"resources":[]}"#) != "addon")        // empty list but no id
        #expect(kind(#"{"id":"x","name":"X","resources":["catalog"]}"#).contains("needs search"))
        #expect(kind(#"{"category:music":[{"id":"m"}]}"#).contains("never runs downloaded code"))
        #expect(kind(#"{"movies":[{"a":1}]}"#).contains("\"movies\""))
    }

    @Test func identifyFindsManifestAtRoot() async throws {
        let t = AddonStubTransport()
        t.on("/manifest.json", json: #"{"id":"x","name":"Hi-Fi","version":"1.0","resources":["search","stream"]}"#)
        let id = try await AddonFormatDetector.identify("https://addon.example.com/tok/", ownServer: false, http: MusicHTTP(transport: t))
        #expect(id.hasManifest && id.manifest.displayName == "Hi-Fi" && id.base.absoluteString == "https://addon.example.com/tok")
    }

    @Test func identifyAcceptsManifestLinkAndSearchOnlyServers() async throws {
        let t = AddonStubTransport()
        t.on("/manifest.json", json: #"{"id":"x","name":"N"}"#)
        let a = try await AddonFormatDetector.identify("https://addon.example.com/manifest.json", ownServer: false, http: MusicHTTP(transport: t))
        #expect(a.base.absoluteString == "https://addon.example.com")
        let t2 = AddonStubTransport()
        t2.on("/search", json: #"{"tracks":[]}"#)
        let b = try await AddonFormatDetector.identify("https://plain.example.com", ownServer: false, http: MusicHTTP(transport: t2))
        #expect(!b.hasManifest && b.manifest.resources == ["search", "stream"])
        #expect(t2.requests.contains { $0.url?.query?.contains("q=music") == true })
    }

    @Test func identifyReportsProblemsDifferently() async {
        func outcome(_ setup: (AddonStubTransport) -> Void, _ url: String = "https://addon.example.com", own: Bool = false) async -> AddonProblem? {
            let t = AddonStubTransport(); setup(t)
            do { _ = try await AddonFormatDetector.identify(url, ownServer: own, http: MusicHTTP(transport: t)); return nil }
            catch { return error as? AddonProblem }
        }
        let down = await outcome { $0.on("") { _ in (503, "", [:]) } }
        if case .unreachable = down {} else { Issue.record("503 should be unreachable, got \(String(describing: down))") }
        let refused = await outcome { $0.on("") { _ in (403, "", [:]) } }
        if case .rejected = refused {} else { Issue.record("403 should be rejected, got \(String(describing: refused))") }
        let nothing = await outcome { _ in }
        if case .notRecognised = nothing {} else { Issue.record("404 everywhere should be not recognised, got \(String(describing: nothing))") }
        let list = await outcome { $0.on("/manifest.json", json: "[1,2]") }
        if case .unsupported = list {} else { Issue.record("a list should be unsupported, got \(String(describing: list))") }
        let index = await outcome { $0.on("/manifest.json", json: #"{"category:a":[{"id":"1"}]}"#) }
        if case .unsupported = index {} else { Issue.record("a plug-in index should be unsupported") }
        let plain = await outcome({ _ in }, "http://addon.example.com")
        if case .blocked = plain {} else { Issue.record("plain http should be blocked") }
        let lan = await outcome({ _ in }, "https://192.168.0.4")
        if case .blocked = lan {} else { Issue.record("a private address needs the tick") }
    }
}

@Suite("Addon requests")
struct AddonRequestTests {
    private let options = [AddonOption(value: "FLAC", label: "CD"), AddonOption(value: "HI_RES", label: "Hi-Res"), AddonOption(value: "MP3_320", label: "320"), AddonOption(value: "MP3_96", label: "Low")]

    @Test func qualityVocabulary() {
        #expect(AddonQuery.qualityValue(request: .lossless, options: options, picked: nil) == "FLAC")        // first listed, not matched on the word
        #expect(AddonQuery.qualityValue(request: .lossless, options: options, picked: "HI_RES") == "HI_RES")
        #expect(AddonQuery.qualityValue(request: .lossless, options: options, picked: "GONE") == "FLAC")
        #expect(AddonQuery.qualityValue(request: .lossless, options: [], picked: nil) == "LOSSLESS")
        #expect(AddonQuery.qualityValue(request: .best, options: options, picked: "HI_RES") == "MP3_320")      // a pick never overrides a lower request
        #expect(AddonQuery.qualityValue(request: .capped(96), options: options, picked: nil) == "MP3_96")
        #expect(AddonQuery.qualityValue(request: .best, options: [], picked: nil) == "HIGH")
        #expect(AddonQuery.qualityValue(request: .best, options: [AddonOption(value: "high", label: "")], picked: nil) == "high")
        #expect(AddonRequest(.lossless) == .lossless && AddonRequest(.high) == .best && AddonRequest(.low) == .capped(96))
    }

    @Test func parametersCarryDefaultsAndTrackHints() throws {
        let m = try #require(AddonManifest.parse(streamObject(#"{"id":"x","settings":[{"key":"region","default":"us"}]}"#)))
        let p = AddonQuery.parameters(manifest: m, request: .best, picked: nil, q: "one more time daft punk", title: " One More Time ", artist: "")
        #expect(p["region"] == "us" && p["quality"] == "HIGH" && p["title"] == "One More Time" && p["artist"] == nil && p["q"] == "one more time daft punk")
        let typed = AddonQuery.parameters(manifest: nil, request: .best, picked: nil, q: "abc", title: nil, artist: nil)
        #expect(typed["title"] == nil && typed["artist"] == nil)
    }
}

@Suite("Addon client over a stubbed server")
struct AddonClientTests {
    @Test func searchSendsParametersAndTokenAndCaches() async throws {
        let t = AddonStubTransport()
        t.on("/manifest.json", json: #"{"id":"x","name":"X","settings":[{"key":"quality","default":"FLAC","options":[{"value":"FLAC","label":"CD"}]}]}"#)
        t.on("/search", json: #"{"tracks":[{"id":"1","title":"Time","artist":"Pink Floyd","duration":200}]}"#)
        let c = fastClient(t, token: "secret-token")
        let rows = try await c.search(q: "time pink floyd", title: "Time", artist: "Pink Floyd", request: .lossless)
        #expect(rows.count == 1)
        let req = try #require(t.requests.last { $0.url?.path.hasSuffix("/search") == true })
        let q = req.url?.query ?? ""
        #expect(q.contains("quality=FLAC") && q.contains("title=Time") && q.contains("artist=Pink%20Floyd") && q.contains("q=time"))
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/json")
        _ = try await c.search(q: "time pink floyd", title: "Time", artist: "Pink Floyd", request: .lossless)
        #expect(t.count("/search") == 1)          // the second call came from the cache
    }

    @Test func cacheExpiresAfterTenMinutes() async throws {
        let t = AddonStubTransport(); let clock = TestClock()
        t.on("/search", json: #"{"tracks":[]}"#)
        let c = fastClient(t, clock: clock)
        _ = try await c.search(q: "a", request: .best); clock.advance(601)
        _ = try await c.search(q: "a", request: .best)
        #expect(t.count("/search") == 2)
    }

    @Test func rateLimitRetriesTwiceThenGivesUp() async throws {
        let t = AddonStubTransport()
        let hits = NSLock(); nonisolated(unsafe) var n = 0
        t.on("/search") { _ in hits.lock(); n += 1; let k = n; hits.unlock(); return k < 3 ? (429, "", ["Retry-After": "1"]) : (200, #"{"tracks":[]}"#, [:]) }
        let ok = try await fastClient(t).search(q: "a", request: .best)
        #expect(ok.isEmpty && t.count("/search") == 3)
        let t2 = AddonStubTransport(); t2.on("/search") { _ in (429, "", [:]) }
        await #expect(throws: (any Error).self) { _ = try await fastClient(t2).search(q: "a", request: .best) }
        #expect(t2.count("/search") == 3)
    }

    @Test func badRepliesAreRejectedStrictly() async {
        let t = AddonStubTransport()
        t.on("/search", json: "[1,2,3]")
        await #expect(throws: (any Error).self) { _ = try await fastClient(t).search(q: "a", request: .best) }
        let t2 = AddonStubTransport(); t2.on("/search", json: #"{"results":[]}"#)
        await #expect(throws: (any Error).self) { _ = try await fastClient(t2).search(q: "a", request: .best) }
        let t3 = AddonStubTransport(); t3.on("/search", json: "<html>")
        await #expect(throws: (any Error).self) { _ = try await fastClient(t3).search(q: "a", request: .best) }
        let big = AddonStubTransport(); big.on("/stream/1", json: #"{"url":"https://cdn.example.com/a.flac","pad":""# + String(repeating: "x", count: 300_000) + #""}"#)
        await #expect(throws: (any Error).self) { _ = try await fastClient(big).stream(row: row("1", "T"), request: .best) }
    }

    @Test func streamEndpointEncodesIdAndMissesOn404() async throws {
        let t = AddonStubTransport()
        t.on("/stream/a%2Fb", json: #"{"url":"https://cdn.example.com/a.flac","codec":"flac"}"#)
        guard case .stream = try await fastClient(t).stream(row: row("a/b", "T"), request: .lossless) else { Issue.record("expected stream"); return }
        guard case .miss = try await fastClient(AddonStubTransport()).stream(row: row("zzz", "T"), request: .lossless) else { Issue.record("a 404 is a miss, not an error"); return }
    }

    @Test func addonMemberPicksHiResForLosslessRequest() async throws {
        let t = AddonStubTransport()
        t.on("/search", json: #"{"tracks":[{"id":"mp3","title":"Get Lucky","artist":"Daft Punk","duration":248,"audioQuality":"HIGH"},{"id":"hires","title":"Get Lucky","artist":"Daft Punk","duration":248,"audioQuality":"HI-RES FLAC"},{"id":"live","title":"Get Lucky (Live)","artist":"Daft Punk","duration":248,"audioQuality":"LOSSLESS"}]}"#)
        t.on("/stream/hires", json: #"{"url":"https://cdn.example.com/h.flac","quality":"FLAC 24-bit 96 kHz"}"#)
        t.on("/stream/mp3", json: #"{"url":"https://cdn.example.com/m.mp3","bitrate":320}"#)
        let provider = AddonAudioProvider(client: fastClient(t), displayName: "Test")
        let member = MusicSourceChain.Member(id: provider.info.id, name: "Test", rank: 0, kind: .addon(provider), allowsDownload: true)
        let opts = MusicSourceChain.Options(request: .lossless, quality: .lossless, strictLengthSeconds: nil, probeLength: false, earlyExit: true, budget: 5, http: MusicHTTP(transport: t))
        let c = try #require(try await MusicSourceChain.runAddon(provider, member: member, track: track("Get Lucky", seconds: 248), opts: opts))
        #expect(c.quality.bitDepth == 24 && !c.belowRequest && t.count("/stream/mp3") == 0 && t.count("/stream/live") == 0)
        // Only an MP3 on offer: kept as the floor and flagged.
        let t2 = AddonStubTransport()
        t2.on("/search", json: #"{"tracks":[{"id":"mp3","title":"Get Lucky","artist":"Daft Punk","duration":248}]}"#)
        t2.on("/stream/mp3", json: #"{"url":"https://cdn.example.com/m.mp3","bitrate":320}"#)
        let p2 = AddonAudioProvider(client: fastClient(t2), displayName: "T2")
        let floor = try #require(try await MusicSourceChain.runAddon(p2, member: member, track: track("Get Lucky", seconds: 248), opts: opts))
        #expect(floor.belowRequest && floor.quality.kbps == 320)
        // Strict length refuses a row that is 20 s off.
        let strict = MusicSourceChain.Options(request: .best, quality: .high, strictLengthSeconds: 5, probeLength: false, earlyExit: false, budget: 5, http: MusicHTTP(transport: t2))
        let none = try await MusicSourceChain.runAddon(p2, member: member, track: track("Get Lucky", seconds: 268), opts: strict)
        #expect(none == nil)
    }

    @Test func testerProbesManifestSearchAndStream() async {
        let t = AddonStubTransport()
        t.on("/manifest.json", json: #"{"id":"x","name":"Hi-Fi","version":"1.2"}"#)
        t.on("/search", json: #"{"tracks":[{"id":"1","title":"A","artist":"B"}]}"#)
        t.on("/stream/1", json: #"{"url":"https://cdn.example.com/a.flac","codec":"flac","bitDepth":16,"sampleRate":44100}"#)
        let r = await AddonTester.run("https://addon.example.com", ownServer: false, token: nil, http: MusicHTTP(transport: t))
        #expect(r.ok && r.steps.map(\.name) == ["Manifest", "Search", "Stream"] && r.steps.allSatisfy(\.ok))
        #expect(r.health.detail.contains("Hi-Fi v1.2"))
        let down = AddonStubTransport(); down.on("") { _ in (503, "", [:]) }
        let bad = await AddonTester.run("https://addon.example.com", ownServer: false, token: nil, http: MusicHTTP(transport: down))
        #expect(bad.health.state == .unreachable)
    }
}

@MainActor
@Suite("Addon store")
struct AddonStoreTests {
    private func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("addon-store-\(UUID().uuidString)", isDirectory: true) }
    private func server(_ t: AddonStubTransport, name: String = "Hi-Fi") {
        t.on("/manifest.json", json: #"{"id":"x","name":"\#(name)","version":"1","resources":["search","stream"],"settings":[{"key":"quality","options":[{"value":"FLAC","label":"CD"},{"value":"HI_RES","label":"Hi-Res"}]}]}"#)
    }

    @Test func startsEmptyAndUsesNothing() {
        let s = AddonStore(directory: tempDir(), secrets: MemorySecrets())
        #expect(s.addons.isEmpty && !s.hasEnabledAddon && s.activeProviders(for: .lossless).isEmpty)
    }

    @Test func addKeepsSecretsOutOfTheJSONFile() async throws {
        let dir = tempDir(); let secrets = MemorySecrets(); let t = AddonStubTransport(); server(t)
        let s = AddonStore(directory: dir, secrets: secrets, http: MusicHTTP(transport: t))
        let a = try await s.add("https://addon.example.com/PRIVATE-TOKEN-PATH", token: "abc123")
        #expect(a.displayName == "Hi-Fi" && a.enabled && a.qualityOptions.count == 2 && a.health.state == .ok)
        let json = try String(contentsOf: dir.appendingPathComponent("addons.json"), encoding: .utf8)
        #expect(!json.contains("PRIVATE-TOKEN-PATH") && !json.contains("abc123"))
        #expect(secrets.count == 2)
        #expect(s.endpoint(for: a)?.token == "abc123" && s.endpoint(for: a)?.base.path == "/PRIVATE-TOKEN-PATH")
        let reloaded = AddonStore(directory: dir, secrets: secrets, http: MusicHTTP(transport: t))
        #expect(reloaded.addons.map(\.id) == [a.id])
        s.remove(a.id)
        #expect(secrets.count == 0 && s.addons.isEmpty)
    }

    @Test func duplicateIsRefusedOnCanonicalAddress() async throws {
        let t = AddonStubTransport(); server(t)
        let s = AddonStore(directory: tempDir(), secrets: MemorySecrets(), http: MusicHTTP(transport: t))
        try await s.add("https://Addon.example.com/tok/")
        await #expect(throws: AddonProblem.self) { try await s.add("https://addon.example.com/tok/manifest.json") }
        #expect(s.addons.count == 1)
        try await s.add("https://addon.example.com/other")
        #expect(s.addons.count == 2)
    }

    @Test func unrecognisedAndBlockedAddressesAreNotSaved() async {
        let s = AddonStore(directory: tempDir(), secrets: MemorySecrets(), http: MusicHTTP(transport: AddonStubTransport()))
        await #expect(throws: AddonProblem.self) { try await s.add("https://nothing.example.com") }
        await #expect(throws: AddonProblem.self) { try await s.add("http://addon.example.com") }
        await #expect(throws: AddonProblem.self) { try await s.add("https://192.168.1.2") }
        #expect(s.addons.isEmpty)
    }

    @Test func ownServerMayBePrivateHttp() async throws {
        let t = AddonStubTransport(); server(t)
        let s = AddonStore(directory: tempDir(), secrets: MemorySecrets(), http: MusicHTTP(transport: t))
        let a = try await s.add("http://192.168.1.20:8080", ownServer: true)
        #expect(a.ownServer && s.endpoint(for: a)?.base.absoluteString == "http://192.168.1.20:8080")
    }

    @Test func orderSwitchesAndPolicy() async throws {
        let t = AddonStubTransport(); server(t)
        let s = AddonStore(directory: tempDir(), secrets: MemorySecrets(), http: MusicHTTP(transport: t))
        let a = try await s.add("https://a.example.com"), b = try await s.add("https://b.example.com"), c = try await s.add("https://c.example.com")
        s.move(from: IndexSet(integer: 2), to: 0)
        #expect(s.addons.map(\.id) == [c.id, a.id, b.id])
        s.move(from: IndexSet(integer: 0), to: 3)
        #expect(s.addons.map(\.id) == [a.id, b.id, c.id])
        s.reorder([b.id, UUID(), c.id, c.id])
        #expect(s.addons.map(\.id) == [b.id, c.id, a.id])
        s.setEnabled(false, id: c.id)
        #expect(s.activeProviders(for: .lossless).map(\.config.id) == [b.id, a.id])
        s.qualityPolicy = .losslessOnly
        #expect(s.activeProviders(for: .high).isEmpty && !s.activeProviders(for: .lossless).isEmpty)
        s.qualityPolicy = .always
        #expect(!s.activeProviders(for: .low).isEmpty)
        s.setPickedQuality("HI_RES", id: b.id)
        #expect(s.config(b.id)?.activeQuality == "HI_RES" && s.config(a.id)?.activeQuality == "FLAC")
    }

    @Test func healthIsRecordedWithLatencyAndOutage() async throws {
        let t = AddonStubTransport(); server(t)
        t.on("/search", json: #"{"tracks":[]}"#)
        let s = AddonStore(directory: tempDir(), secrets: MemorySecrets(), http: MusicHTTP(transport: t))
        let a = try await s.add("https://a.example.com")
        let report = await s.test(a.id)
        #expect(report?.ok == true && s.config(a.id)?.health.state == .ok && s.config(a.id)?.health.latencyMs != nil)
        t.on("") { _ in (503, "", [:]) }
        t.on("/manifest.json") { _ in (503, "", [:]) }
        _ = await s.test(a.id)
        #expect(s.config(a.id)?.health.state == .unreachable && s.config(a.id)?.enabled == true)      // an outage keeps it on
    }

    @Test func corruptFileIsSetAside() throws {
        let dir = tempDir(); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("addons.json"))
        let s = AddonStore(directory: dir, secrets: MemorySecrets())
        #expect(s.addons.isEmpty && FileManager.default.fileExists(atPath: dir.appendingPathComponent("addons.json.bad").path))
    }
}
