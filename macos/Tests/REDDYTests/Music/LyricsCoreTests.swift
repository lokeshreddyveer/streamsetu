import Testing
import Foundation
@testable import REDDY

private final class LyricsStub: MusicHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URLRequest] = []
    private let handler: @Sendable (URLRequest) -> (Int, String)
    init(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) { self.handler = handler }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { seen.append(request) }
        let (code, body) = handler(request)
        let resp = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: code, httpVersion: nil, headerFields: nil)
        return (Data(body.utf8), resp ?? HTTPURLResponse())
    }
}

private func lhttp(_ s: LyricsStub) -> MusicHTTP { MusicHTTP(transport: s) }

private func request(title: String = "Song", artists: String = "Artist", album: String? = nil, seconds: Double? = 200, video: String? = "abcdEFGhij_",
                     searched: Bool = false) -> MusicLyricsRequest {
    MusicLyricsRequest(videoID: video, title: title, artists: artists, album: album, durationSeconds: seconds, searched: searched)
}

private func synced(_ id: String, words: Bool = false) -> MusicLyrics {
    let w = words ? [MusicLyricWord(text: "a", startMs: 1000, endMs: 1500)] : nil
    return MusicLyrics(synced: [MusicLyricLine(timeMs: 1000, text: "a", words: w), MusicLyricLine(timeMs: 5000, text: "b")], providerID: id)
}

private func entry(_ id: String, takesSlot: Bool = true, delay: Double = 0, _ result: MusicLyrics?, fail: Bool = false,
                   onRun: (@Sendable () -> Void)? = nil) -> MusicLyricsWalkEntry {
    MusicLyricsWalkEntry(id: id, takesSlot: takesSlot) {
        onRun?()
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        if fail { throw MusicError.network("down") }
        return result
    }
}

private let kpoe = #"""
{"type":"Word","metadata":{"totalDuration":"3:20.500"},"lyrics":[
 {"time":1000,"duration":2000,"text":"Hello world","syllabus":[{"time":1000,"duration":900,"text":"Hello ","isBackground":false},{"time":2000,"duration":1000,"text":"world","isBackground":true}],
  "transliteration":{"lang":"ja","text":"Hello world","syllabus":[]}},
 {"time":4000,"duration":1500,"text":"愛","syllabus":[{"time":4000,"duration":500,"text":"愛","isBackground":false}],"transliteration":{"lang":"ja","text":"ai","syllabus":[{"time":4000,"duration":500,"text":"ai","isBackground":false}]}}]}
"""#

@Suite struct LyricsCoreTests {

    // MARK: walk and selection

    @Test func settlesRule() {
        #expect(MusicLyricsWalk.settles(MusicLyrics(instrumental: true), preferWords: true))
        #expect(MusicLyricsWalk.settles(synced("a"), preferWords: false))
        #expect(!MusicLyricsWalk.settles(synced("a"), preferWords: true))
        #expect(MusicLyricsWalk.settles(synced("a", words: true), preferWords: true))
        #expect(!MusicLyricsWalk.settles(MusicLyrics(plain: "x"), preferWords: false))
    }

    @Test func slotsLetCommunityShareTheNextStart() {
        #expect(MusicLyricsWalk.slots(takesSlot: [false, true, true]) == [0, 0, 1])
        #expect(MusicLyricsWalk.slots(takesSlot: [true, true, true]) == [0, 1, 2])
    }

    @Test func firstSyncedInUserOrderWinsEvenIfLaterAnswersFirst() async {
        let out = await MusicLyricsWalk.run([entry("slow", delay: 0.08, synced("slow")), entry("fast", synced("fast"))], preferWords: false, stagger: 0.01, cap: 2)
        #expect(out.lyrics?.providerID == "slow" && out.answered)
    }

    @Test func plainNeverStopsTheWalk() async {
        let out = await MusicLyricsWalk.run([entry("p", MusicLyrics(plain: "words", providerID: "p")), entry("s", synced("s"))], preferWords: false, stagger: 0.01, cap: 2)
        #expect(out.lyrics?.providerID == "s")
    }

    @Test func preferWordsHoldsOutForWordTimed() async {
        let list = [entry("line", synced("line")), entry("words", synced("words", words: true))]
        let on = await MusicLyricsWalk.run(list, preferWords: true, stagger: 0.01, cap: 2)
        #expect(on.lyrics?.providerID == "words")
        let off = await MusicLyricsWalk.run(list, preferWords: false, stagger: 0.01, cap: 2)
        #expect(off.lyrics?.providerID == "line")
    }

    @Test func fallbackIsFirstLineOnlyThenFirstPlain() async {
        let lines = [entry("p", MusicLyrics(plain: "x", providerID: "p")), entry("l1", synced("l1")), entry("l2", synced("l2"))]
        let out = await MusicLyricsWalk.run(lines, preferWords: true, stagger: 0.01, cap: 2)
        #expect(out.lyrics?.providerID == "l1")
        let plainOnly = await MusicLyricsWalk.run([entry("n", nil), entry("p", MusicLyrics(plain: "x", providerID: "p"))], preferWords: true, stagger: 0.01, cap: 2)
        #expect(plainOnly.lyrics?.providerID == "p")
    }

    @Test func instrumentalSettles() async {
        let out = await MusicLyricsWalk.run([entry("i", MusicLyrics(providerID: "i")), entry("s", synced("s"))], preferWords: false, stagger: 0.01, cap: 2)
        #expect(out.lyrics?.providerID == "s")  // an empty answer is a "no", not an instrumental
        let inst = await MusicLyricsWalk.run([entry("i", MusicLyrics(providerID: "i", instrumental: true)), entry("s", synced("s"))], preferWords: true, stagger: 0.01, cap: 2)
        #expect(inst.lyrics?.instrumental == true)
    }

    @Test func settleCancelsProviderThatHasNotStarted() async throws {
        let ran = LockedLyricsFlag()
        let out = await MusicLyricsWalk.run([entry("a", synced("a")), entry("b", delay: 0, synced("b"), onRun: { ran.set() })], preferWords: false, stagger: 5, cap: 8)
        #expect(out.lyrics?.providerID == "a")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!ran.value)
    }

    @Test func errorsAreSkippedAndAllErrorsMeanNotAnswered() async {
        let mixed = await MusicLyricsWalk.run([entry("e", nil, fail: true), entry("s", synced("s"))], preferWords: false, stagger: 0.01, cap: 2)
        #expect(mixed.lyrics?.providerID == "s")
        let offline = await MusicLyricsWalk.run([entry("e", nil, fail: true), entry("f", nil, fail: true)], preferWords: false, stagger: 0.01, cap: 2)
        #expect(offline.lyrics == nil && !offline.answered)
        let none = await MusicLyricsWalk.run([entry("e", nil, fail: true), entry("n", nil)], preferWords: false, stagger: 0.01, cap: 2)
        #expect(none.lyrics == nil && none.answered)
    }

    @Test func perProviderCapCountsAsError() async {
        let out = await MusicLyricsWalk.run([entry("slow", delay: 2, synced("slow")), entry("ok", synced("ok"))], preferWords: false, stagger: 0.01, cap: 0.1)
        #expect(out.lyrics?.providerID == "ok")
    }

    // MARK: normalisation

    @Test func sameTimestampLyricsAreDemotedToPlain() {
        let flat = MusicLyrics(synced: [MusicLyricLine(timeMs: 0, text: "one"), MusicLyricLine(timeMs: 0, text: "two")])
        let n = MusicLyricsNormalizer.normalize(flat)
        #expect(n?.synced == nil && n?.plain == "one\ntwo")
        let real = MusicLyrics(synced: [MusicLyricLine(timeMs: 0, text: "credit"), MusicLyricLine(timeMs: 4000, text: "sung")])
        #expect(MusicLyricsNormalizer.normalize(real)?.isSynced == true)
        let oneWordLine = MusicLyrics(synced: [MusicLyricLine(timeMs: 0, text: "a b", words: [MusicLyricWord(text: "a ", startMs: 0, endMs: 400), MusicLyricWord(text: "b", startMs: 400, endMs: 900)])])
        #expect(MusicLyricsNormalizer.normalize(oneWordLine)?.isSynced == true)
        #expect(MusicLyricsNormalizer.normalize(MusicLyrics()) == nil)
    }

    @Test func kindLabels() {
        #expect(MusicLyrics(instrumental: true).kind == .instrumental)
        #expect(MusicLyrics(plain: "x").kind == .plain)
        #expect(synced("a").kind == .synced)
        #expect(synced("a", words: true).kind == .wordSynced)
        #expect(!MusicLyrics(instrumental: true).isEmpty)
    }

    @Test func oldCacheRowsStillDecodeAndCleanRowsEncodeAsBefore() throws {
        let old = #"{"synced":[{"timeMs":1000,"text":"hi"}],"sourceName":"LRCLIB"}"#
        let l = try JSONDecoder().decode(MusicLyrics.self, from: Data(old.utf8))
        #expect(l.synced?.first?.text == "hi" && !l.pinned && l.offsetMs == 0 && l.authors.isEmpty)
        let back = try #require(String(data: try JSONEncoder().encode(MusicLyricLine(timeMs: 5, text: "x")), encoding: .utf8))
        #expect(!back.contains("words") && !back.contains("voice") && !back.contains("endMs"))
        let rich = MusicLyrics(synced: [MusicLyricLine(timeMs: 1, text: "a b", endMs: 9, words: [MusicLyricWord(text: "a ", startMs: 1, endMs: 4, background: true)], voice: "v2", translation: "t", romanized: "r")],
                               pinned: true, offsetMs: -250, revision: 3, authors: ["moss"], via: "Boidu", communityID: "zzz")
        #expect(try JSONDecoder().decode(MusicLyrics.self, from: try JSONEncoder().encode(rich)) == rich)
    }

    // MARK: text helpers and matching

    @Test func searchTitleCleaning() {
        #expect(MusicLyricsText.searchTitle("Bad Apple／ Lizz Robinett (English Cover) | Lyrics/Lyric Video [English]") == "Bad Apple／ Lizz Robinett")
        #expect(MusicLyricsText.searchTitle("【MV】 我的驕傲 （Official Video）") == "我的驕傲")
        #expect(MusicLyricsText.searchTitle("(Intro)") == "")
        #expect(MusicLyricsText.searchTitle("A (b (c) d)  e") == "A e")
    }

    @Test func closestLengthRule() {
        let items: [(String, Double?)] = [("remix", 263), ("far", 240), ("near", 235), ("unknown", nil)]
        #expect(MusicLyricsMatch.closest(items, wanted: 233) { $0.1 }?.0 == "near")
        #expect(MusicLyricsMatch.closest(items, wanted: nil) { $0.1 }?.0 == "remix")
        #expect(MusicLyricsMatch.closest([("a", 300.0 as Double?), ("u", nil)], wanted: 200) { $0.1 }?.0 == "u")
        #expect(MusicLyricsMatch.closest([("a", 300.0 as Double?)], wanted: 200) { $0.1 } == nil)
        #expect(MusicLyricsMatch.closest([("a", 205.0 as Double?)], wanted: 200) { $0.1 }?.0 == "a")
        #expect(MusicLyricsMatch.closest([("a", 205.1 as Double?)], wanted: 200) { $0.1 } == nil)
    }

    @Test func entityDecoding() {
        #expect(MusicLyricsText.decodeEntities("It&apos;s &amp; &#39;x&#x41; &foo;") == "It's & 'xA &foo;")
    }

    // MARK: parsers

    @Test func lrcStampsOffsetAndBracketText() {
        let lines = MusicLyricsParsers.parseLRC("[ar:x]\n[offset:+500]\n[00:05.123]first\n[00:12.00][01:30.5]chorus\n[00:20]no fraction\n[00:30.00][Chorus] yeah\n[00:40.00]")
        #expect(lines.map(\.text) == ["first", "chorus", "no fraction", "[Chorus] yeah", "", "chorus"])
        #expect(lines.map(\.timeMs) == [4623, 11500, 19500, 29500, 39500, 90000])
    }

    @Test func enhancedLrcWords() {
        let lines = MusicLyricsParsers.parseLRC("[00:01.00]<00:01.00>Hello <00:01.50>world <00:02.00>\n[00:03.00]<00:03.00>Next <00:03.40>one\n[00:20.00]<00:20.00>last")
        #expect(lines[0].text == "Hello world")
        #expect(lines[0].words?.map(\.startMs) == [1000, 1500] && lines[0].words?.map(\.endMs) == [1500, 2000])
        #expect(lines[1].words?.last?.endMs == 6400)       // no closing tag, no next line within 3 s: capped at start + 3000
        #expect(lines[2].words?.first?.endMs == 23000)
        #expect(MusicLyricsParsers.parseLRC("[00:01.00]a < b > c").first?.text == "a < b > c")
    }

    private let ttml = """
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:itunes="http://music.apple.com/lyric-ttml-internal"><head><metadata><iTunes:transliterations><transliteration xml:lang="ja-Latn"><text for="L1"><span begin="1.0s" end="1.5s">ai</span> <span begin="1.5s" end="2.0s">shite</span></text></transliteration></iTunes:transliterations></metadata></head>
    <body><div><p begin="1.0s" end="3.0s" itunes:key="L1"><span begin="1.0s" end="1.5s">愛</span> <span begin="1.5s" end="2.0s">して</span><span ttm:role="x-bg">(<span begin="2.0s" end="2.5s">oh</span> <span begin="2.5s" end="3.0s">yeah</span>)</span></p>
    <p begin="0:04.000" end="5500ms"><span begin="4s" end="4.5s">It&apos;s</span> <span begin="4.5s" end="5s">me</span></p><p>untimed</p></div></body></tt>
    """

    @Test func ttmlWordsBackgroundReadingsAndEntities() {
        let parsed = MusicLyricsParsers.parse(ttml)
        #expect(parsed.count == 3 && parsed.filter(\.timed).count == 2)
        let l0 = parsed[0].line
        #expect(l0.words?.map(\.text) == ["愛 ", "して", "(oh ", "yeah)"])
        #expect(l0.words?.map(\.background) == [false, false, true, true])
        #expect(l0.romanized == "ai shite" && l0.romanizedWords?.count == 2)
        #expect(parsed[1].line.text == "It's me" && parsed[1].line.timeMs == 4000 && parsed[1].line.endMs == 5500)
        #expect(!parsed[2].timed)
        #expect(MusicLyricsParsers.clock("1.241s") == 1241 && MusicLyricsParsers.clock("500ms") == 500 && MusicLyricsParsers.clock("1:02:03.5") == 3_723_500)
        #expect(MusicLyricsParsers.clock("3:53.713") == 233_713 && MusicLyricsParsers.clock("12.5") == 12_500 && MusicLyricsParsers.clock(nil) == nil)
    }

    @Test func genericParserOrderAndPlainFallback() {
        #expect(MusicLyricsParsers.lyrics(from: "[00:01.00]a\n[00:02.00]b", source: "S", provider: "p")?.isSynced == true)
        #expect(MusicLyricsParsers.lyrics(from: ttml, source: "S", provider: "p")?.isWordTimed == true)
        let untimed = MusicLyricsParsers.lyrics(from: #"<tt><body><div><p>one</p><p>two</p></div></body></tt>"#, source: "S", provider: "p")
        #expect(untimed?.plain == "one\ntwo" && untimed?.synced == nil)
        #expect(MusicLyricsParsers.lyrics(from: "just words\nmore", source: "S", provider: "p")?.plain == "just words\nmore")
    }

    // MARK: LRCLIB

    @Test func lrclibPicksClosestCutWithinFiveSeconds() async throws {
        let stub = LyricsStub { r in
            if r.url?.path == "/api/get" { return (404, "") }
            return (200, #"[{"duration":204,"syncedLyrics":"[00:01.00]far"},{"duration":201,"syncedLyrics":"[00:01.00]near"},{"duration":260,"syncedLyrics":"[00:01.00]other"},{"plainLyrics":"p"}]"#)
        }
        let l = try await LRCLibProvider(http: lhttp(stub)).lyrics(for: request())
        #expect(l?.synced?.first?.text == "near")
    }

    @Test func lrclibFreeTextRetriesNeedKnownLengthAndUseCleanTitle() async throws {
        let stub = LyricsStub { r in
            if r.url?.path == "/api/get" { return (404, "") }
            let q = URLComponents(url: r.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?.queryItems ?? []
            if q.contains(where: { $0.name == "q" && $0.value == "Song Artist" }) { return (200, #"[{"duration":200,"syncedLyrics":"[00:01.00]hit"}]"#) }
            return (200, "[]")
        }
        let l = try await LRCLibProvider(http: lhttp(stub)).lyrics(for: request(title: "Song (Official Video) | HD"))
        #expect(l?.synced?.first?.text == "hit")
        let urls = stub.requests.compactMap { $0.url?.absoluteString }
        #expect(urls.contains { $0.contains("q=Song") })
        let noLen = LyricsStub { r in r.url?.path == "/api/get" ? (404, "") : (200, "[]") }
        _ = try await LRCLibProvider(http: lhttp(noLen)).lyrics(for: request(seconds: nil))
        // Without a known length the free-text search still runs (a wrong cut is better than silence).
        #expect(noLen.requests.contains { $0.url?.query?.contains("q=") == true })
    }

    @Test func lrclibInstrumentalAndPlainFallbackAndErrors() async throws {
        let inst = LyricsStub { _ in (200, #"{"instrumental":true}"#) }
        #expect(try await LRCLibProvider(http: lhttp(inst)).lyrics(for: request())?.instrumental == true)
        let plain = LyricsStub { r in r.url?.path == "/api/get" ? (200, #"{"plainLyrics":"only plain"}"#) : (200, "[]") }
        let p = try await LRCLibProvider(http: lhttp(plain)).lyrics(for: request())
        #expect(p?.plain == "only plain" && p?.synced == nil)
        let down = LyricsStub { _ in (500, "") }
        await #expect(throws: MusicError.self) { _ = try await LRCLibProvider(http: lhttp(down)).lyrics(for: request()) }
        let flat = LyricsStub { r in r.url?.path == "/api/get" ? (200, #"{"syncedLyrics":"[00:00.00]a\n[00:00.00]b","plainLyrics":"a\nb"}"#) : (200, "[]") }
        #expect(try await LRCLibProvider(http: lhttp(flat)).lyrics(for: request())?.isSynced == false)
    }

    // MARK: other sources

    @Test func unisonByVideoThenByNameAndPlain() async throws {
        let stub = LyricsStub { _ in (200, #"{"success":true,"data":{"id":"1","videoId":"v","format":"lrc","syncType":"line","lyrics":"[00:01.00]hello\n[00:02.00]world"}}"#) }
        let l = try await UnisonProvider(http: lhttp(stub)).lyrics(for: request())
        #expect(l?.isSynced == true && l?.sourceName == "Unison")
        #expect(stub.requests.first?.url?.query?.contains("v=abcdEFGhij_") == true)
        _ = try await UnisonProvider(http: lhttp(stub)).lyrics(for: request(searched: true))
        let q = stub.requests.last?.url?.query ?? ""
        #expect(q.contains("song=Song") && q.contains("artist=Artist") && q.contains("duration=200") && !q.contains("v="))
        let plain = LyricsStub { _ in (200, #"{"success":true,"data":{"format":"plain","lyrics":"a\n\nb"}}"#) }
        #expect(try await UnisonProvider(http: lhttp(plain)).lyrics(for: request())?.plain == "a\n\nb")
        let miss = LyricsStub { _ in (404, "") }
        #expect(try await UnisonProvider(http: lhttp(miss)).lyrics(for: request()) == nil)
    }

    @Test func boiduNeedsLengthAndRetriesWithoutAlbumOn401() async throws {
        let stub = LyricsStub { r in
            if r.url?.query?.contains("al=") == true { return (401, "") }
            return (200, #"{"ttml":"<tt><body><div><p begin=\"1s\" end=\"2s\"><span begin=\"1s\" end=\"2s\">Hi</span></p></div></body></tt>"}"#)
        }
        let l = try await BoiduProvider(http: lhttp(stub)).lyrics(for: request(album: "Alb"))
        #expect(l?.isWordTimed == true && stub.requests.count == 2)
        #expect(try await BoiduProvider(http: lhttp(stub)).lyrics(for: request(seconds: nil)) == nil)
        let always401 = LyricsStub { _ in (401, "") }
        #expect(try await BoiduProvider(http: lhttp(always401)).lyrics(for: request(album: "A")) == nil)
        let boom = LyricsStub { _ in (500, "") }
        await #expect(throws: MusicError.self) { _ = try await BoiduProvider(http: lhttp(boom)).lyrics(for: request()) }
        let arr = LyricsStub { _ in (200, #"{"lyrics":[{"text":"a","time":1000},{"text":"b","time":2000}]}"#) }
        #expect(try await BoiduProvider(http: lhttp(arr)).lyrics(for: request())?.synced?.count == 2)
    }


    @Test func lyricsPlusMappingAndDurationGuard() async throws {
        let stub = LyricsStub { _ in (200, kpoe) }
        let l = try #require(try await LyricsPlusProvider(http: lhttp(stub)).lyrics(for: request(seconds: 202)))
        #expect(l.isWordTimed && l.synced?[0].words?.map(\.background) == [false, true] && l.synced?[0].endMs == 3000)
        #expect(l.synced?[0].romanized == nil && l.synced?[1].romanized == "ai" && l.synced?[1].romanizedWords?.count == 1)
        #expect(try await LyricsPlusProvider(http: lhttp(stub)).lyrics(for: request(seconds: 230)) == nil)   // 20 s off: another track
        #expect(try await LyricsPlusProvider(http: lhttp(stub)).lyrics(for: request(seconds: nil)) != nil)    // unknown: accept
        let flat = LyricsStub { _ in (200, #"{"type":"Word","lyrics":[{"time":0,"duration":0,"text":"a","syllabus":[]},{"time":0,"duration":0,"text":"b","syllabus":[]}]}"#) }
        #expect(try await LyricsPlusProvider(http: lhttp(flat)).lyrics(for: request())?.plain == "a\nb")
    }

    @Test func communityMappingQueryAndRevalidation() async throws {
        let body = #"{"video_id":"zzzzzzzzzzz","origin":"boidu","revision":7,"authors":["a","","b","c","d","e","f"],"lines":[{"time_ms":1000,"end_time_ms":2000,"text":"hi there","agent":"v2","words":[{"text":"hi ","start_ms":1000,"end_ms":1400},{"text":"there","start_ms":1400,"end_ms":2000,"bg":true}],"romanized":"hi"},{"time_ms":3000,"text":"x","agent":"bad"}],"newField":1}"#
        let stub = LyricsStub { r in r.value(forHTTPHeaderField: "If-None-Match") != nil ? (304, "") : (200, body) }
        let p = CommunityLyricsProvider(http: lhttp(stub))
        let l = try #require(try await p.lyrics(for: request()))
        #expect(l.revision == 7 && l.communityID == "zzzzzzzzzzz" && l.via == "Boidu" && l.authors.isEmpty)   // authors only for community origin
        #expect(l.synced?[0].voice == "v2" && l.synced?[1].voice == nil && l.synced?[0].words?[1].background == true)
        let q = stub.requests.first?.url?.query ?? ""
        #expect(q.contains("title=Song") && q.contains("artist=Artist") && q.contains("duration=200"))
        guard case .notModified = try await p.fetch(request(), filedID: "zzzzzzzzzzz", revision: 7) else { Issue.record("expected 304"); return }
        #expect(stub.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"7\"")
        #expect(stub.requests.last?.url?.query == nil)
        let community = LyricsStub { _ in (200, #"{"origin":"community","authors":["a","","b","c","d","e","f"],"lines":[{"time_ms":1,"text":"x"},{"time_ms":2,"text":"y"}]}"#) }
        let c = try await CommunityLyricsProvider(http: lhttp(community)).lyrics(for: request())
        #expect(c?.authors == ["a", "b", "c", "d", "e"] && c?.communityID == "abcdEFGhij_")
        let none = LyricsStub { _ in (200, "x") }
        #expect(try await CommunityLyricsProvider(http: lhttp(none)).lyrics(for: request(searched: true)) == nil)
        #expect(none.requests.isEmpty)
        let gone = LyricsStub { _ in (404, "") }
        #expect(try await CommunityLyricsProvider(http: lhttp(gone)).lyrics(for: request(seconds: nil)) == nil)
        #expect(gone.requests.first?.url?.query == nil)       // no length: no name is sent
    }

    @Test func communityHintRules() {
        let boidu = MusicLyrics(synced: [MusicLyricLine(timeMs: 1, text: "a", words: [MusicLyricWord(text: "a", startMs: 1, endMs: 2)])], providerID: "boidu")
        #expect(CommunityLyricsProvider.shouldHint(winner: boidu, request: request(), communityOn: true))
        #expect(!CommunityLyricsProvider.shouldHint(winner: boidu, request: request(), communityOn: false))
        #expect(!CommunityLyricsProvider.shouldHint(winner: boidu, request: request(searched: true), communityOn: true))
        var local = request(); local.isLocal = true
        #expect(!CommunityLyricsProvider.shouldHint(winner: boidu, request: local, communityOn: true))
        var lineOnly = boidu; lineOnly.synced = [MusicLyricLine(timeMs: 1, text: "a")]
        #expect(!CommunityLyricsProvider.shouldHint(winner: lineOnly, request: request(), communityOn: true))
        var own = boidu; own.providerID = "community-lyrics"
        #expect(!CommunityLyricsProvider.shouldHint(winner: own, request: request(), communityOn: true))
        let body = CommunityLyricsProvider.hintBody(request: request(album: "Al"), provider: "boidu").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(body?["video_id"] as? String == "abcdEFGhij_" && body?["duration"] as? Int == 200 && body?["album"] as? String == "Al")
    }

    @Test func neteaseSearchPicksClosestAndAssemblesTranslation() async throws {
        let stub = LyricsStub { r in
            if r.url?.path == "/api/search/get" { return (200, #"{"result":{"songs":[{"id":1,"duration":263000},{"id":2,"duration":201500}]}}"#) }
            return (200, #"{"lrc":{"lyric":"[00:01.00]你好\n[00:05.00]再见"},"tlyric":{"lyric":"[00:01.00]Hello\n[00:05.50]Bye"},"klyric":{"lyric":"[00:01.20]<00:01.20>你<00:01.60>好"}}"#)
        }
        let l = try #require(try await NeteaseProvider(http: lhttp(stub)).lyrics(for: request()))
        #expect(l.synced?[0].translation == "Hello" && l.synced?[1].translation == nil)   // equal times only
        #expect(l.synced?[0].words?.count == 2 && l.hasTranslation)
        let search = stub.requests.first
        #expect(search?.httpMethod == "POST" && search?.value(forHTTPHeaderField: "Referer") == "https://music.163.com/")
        #expect(String(data: search?.httpBody ?? Data(), encoding: .utf8)?.contains("type=1") == true)
        #expect(stub.requests.last?.url?.query?.contains("id=2") == true)
        let nothingClose = LyricsStub { _ in (200, #"{"result":{"songs":[{"id":1,"duration":263000}]}}"#) }
        #expect(try await NeteaseProvider(http: lhttp(nothingClose)).lyrics(for: request()) == nil)
        let noLrc = LyricsStub { r in r.url?.path == "/api/search/get" ? (200, #"{"result":{"songs":[{"id":1}]}}"#) : (200, #"{"tlyric":{"lyric":"[00:01.00]x"}}"#) }
        #expect(try await NeteaseProvider(http: lhttp(noLrc)).lyrics(for: request()) == nil)
    }

    @Test func qqSuggestLengthsAndBase64() async throws {
        let lrc = "[00:01.00]hello\n[00:02.00]world"
        let b64 = Data(lrc.utf8).base64EncodedString()
        let stub = LyricsStub { r in
            let path = r.url?.path ?? ""
            if path.contains("smartbox") { return (200, #"{"data":{"song":{"itemlist":[{"mid":"m1"},{"mid":"m2"}]}}}"#) }
            if path.contains("fcg_play_single_song") { return (200, #"{"data":[{"mid":"m1","interval":260},{"mid":"m2","interval":199}]}"#) }
            return (200, "{\"lyric\":\"\(b64)\"}")
        }
        let l = try await QQMusicProvider(http: lhttp(stub)).lyrics(for: request())
        #expect(l?.synced?.count == 2 && l?.sourceName == "QQ Music")
        #expect(stub.requests.last?.url?.query?.contains("songmid=m2") == true)
        #expect(stub.requests.allSatisfy { $0.value(forHTTPHeaderField: "Referer") == "https://y.qq.com/" })
        let plainText = LyricsStub { r in
            if (r.url?.path ?? "").contains("smartbox") { return (200, #"{"data":{"song":{"itemlist":[{"mid":"m1"}]}}}"#) }
            return (200, #"{"lyric":"[00:01.00]raw one\n[00:02.00]raw two"}"#)
        }
        #expect(try await QQMusicProvider(http: lhttp(plainText)).lyrics(for: request(seconds: nil))?.synced?.first?.text == "raw one")
    }

    @Test func kugouThreeStepChain() async throws {
        let lrc = Data("[00:01.00]one\n[00:03.00]two".utf8).base64EncodedString()
        let stub = LyricsStub { r in
            let host = r.url?.host ?? ""
            if host.hasPrefix("mobileservice") { return (200, #"{"data":{"info":[{"hash":"far","duration":300},{"hash":"H1","duration":198}]}}"#) }
            if host.hasPrefix("krcs") { return (200, #"{"candidates":[{"id":"77","accesskey":"KEY"}]}"#) }
            return (200, "{\"content\":\"\(lrc)\"}")
        }
        let l = try await KugouProvider(http: lhttp(stub)).lyrics(for: request())
        #expect(l?.synced?.count == 2)
        #expect(stub.requests[1].url?.query?.contains("hash=H1") == true)
        #expect(stub.requests[2].url?.query?.contains("accesskey=KEY") == true && stub.requests[2].url?.query?.contains("id=77") == true)
        let throttled = LyricsStub { _ in (200, #"{"data":{"lists":[]}}"#) }
        #expect(try await KugouProvider(http: lhttp(throttled)).lyrics(for: request()) == nil)
    }

    @Test func youTubeSourceUnavailableUntilConnectedAndResponseReaders() async throws {
        let link = MusicYouTubeLyricsLink()
        let p = MusicYouTubeLyricsProvider(link: link)
        #expect(!p.isAvailable)
        await #expect(throws: MusicError.self) { _ = try await p.lyrics(for: request()) }
        let timed: [String: Any] = ["a": [["timedLyricsData": [["lyricLine": "one", "cueRange": ["startTimeMilliseconds": "1500"]], ["lyricLine": "credit"]]]]]
        #expect(MusicYouTubeLyricsProvider.timedLines(in: timed) == [MusicYouTubeTimedLine(text: "one", startMs: 1500)])
        let shelf: [String: Any] = ["x": ["musicDescriptionShelfRenderer": ["description": ["runs": [["text": "la la"]]], "footer": ["runs": [["text": "Source: Musixmatch"]]]]]]
        #expect(MusicYouTubeLyricsProvider.plainLyrics(in: shelf)?.footer == "Source: Musixmatch")
        let next: [String: Any] = ["tabs": [["browseEndpoint": ["browseId": "MPLYt_x", "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_TRACK_LYRICS"]]]]]]
        #expect(MusicYouTubeLyricsProvider.lyricsBrowseID(in: next) == "MPLYt_x")
    }

    @Test func id3UnsyncedLyricsFrame() throws {
        // ID3v2.3 header + one USLT frame: encoding 3 (UTF-8), "eng", empty descriptor, text.
        var frame: [UInt8] = [3, 0x65, 0x6E, 0x67, 0]
        frame += Array("[00:01.00]hi\n[00:02.00]there".utf8)
        var body: [UInt8] = Array("USLT".utf8)
        let n = frame.count
        body += [UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255), 0, 0]
        body += frame
        let size = body.count
        let header: [UInt8] = [0x49, 0x44, 0x33, 3, 0, 0, UInt8((size >> 21) & 127), UInt8((size >> 14) & 127), UInt8((size >> 7) & 127), UInt8(size & 127)]
        let l = ID3Lyrics.parse(header: Data(header), body: Data(body))
        #expect(l?.synced?.count == 2 && l?.providerID == "local-lyrics")
    }

    // MARK: ordering and settings

    @Test func sourceOrderNormalisation() {
        let def = MusicLyricsSources.resolve(order: [], enabled: [:])
        #expect(def.map(\.id) == MusicLyricsSources.defaultOrder && def.allSatisfy(\.enabled))
        let saved = MusicLyricsSources.resolve(order: ["lrclib", "bogus", "lrclib", "kugou"], enabled: ["kugou": false])
        let head = ["community-lyrics", "lrclib", "kugou"]
        #expect(saved.map(\.id) == head + MusicLyricsSources.defaultOrder.filter { !head.contains($0) })
        #expect(saved.first { $0.id == "kugou" }?.enabled == false && saved.first { $0.id == "boidu" }?.enabled == true)
        let allOff = MusicLyricsSources.resolve(order: ["lrclib"], enabled: ["lrclib": false])
        #expect(allOff.filter(\.enabled).isEmpty)       // someone who wanted none is not surprised by new sources
        let named = MusicLyricsSources.resolve(order: ["unison", "community-lyrics"], enabled: ["community-lyrics": false])
        #expect(Array(named.map(\.id).prefix(2)) == ["unison", "community-lyrics"] && named[1].enabled == false)
        #expect(MusicLyricsSources.resolve(order: [], enabled: [:], extra: ["plug.lyrics"]).last?.id == "plug.lyrics")
    }

    @Test func settingsDefaultsAndOldFileDecode() throws {
        let s = MusicSettings()
        #expect(s.lyricsSourceOrder == MusicLyricsSources.defaultOrder && s.lyricsSourceEnabled.count == MusicLyricsSources.defaultOrder.count && s.lyricsSourceEnabled.values.allSatisfy { $0 })
        #expect(!s.preferWordByWord && s.showTranslation && !s.showRomanisation)
        let old = try JSONDecoder().decode(MusicSettings.self, from: Data(#"{"consentDone":true}"#.utf8))
        #expect(old.consentDone && old.lyricsSourceOrder == MusicLyricsSources.defaultOrder && old.showTranslation)
        let round = try JSONDecoder().decode(MusicSettings.self, from: try JSONEncoder().encode(MusicSettings(lyricsSourceOrder: ["lrclib"], lyricsSourceEnabled: ["lrclib": false], preferWordByWord: true)))
        #expect(round.lyricsSourceOrder == ["lrclib"] && round.lyricsSourceEnabled["lrclib"] == false && round.preferWordByWord)
    }

    // MARK: cache rules

    @Test func cacheTTLAndStoreRules() {
        let now = Date()
        #expect(MusicLyricsCachePolicy.isFresh(hit: true, fetchedAt: now.addingTimeInterval(-86400 * 400), now: now))
        #expect(MusicLyricsCachePolicy.isFresh(hit: false, fetchedAt: now.addingTimeInterval(-5 * 3600), now: now))
        #expect(!MusicLyricsCachePolicy.isFresh(hit: false, fetchedAt: now.addingTimeInterval(-7 * 3600), now: now))
        #expect(MusicLyricsCachePolicy.shouldStoreHit(durationKnown: true, providerID: "lrclib"))
        #expect(!MusicLyricsCachePolicy.shouldStoreHit(durationKnown: false, providerID: "lrclib"))
        for id in ["youtube", "unison", "community-lyrics"] { #expect(MusicLyricsCachePolicy.shouldStoreHit(durationKnown: false, providerID: id)) }
        #expect(MusicLyricsCachePolicy.shouldStoreMiss(answered: true) && !MusicLyricsCachePolicy.shouldStoreMiss(answered: false))
    }

    @Test func revalidationPlans() {
        let now = Date()
        let order = MusicLyricsSources.resolve(order: [], enabled: [:]).filter(\.enabled)
        var lim = synced("community-lyrics"); lim.revision = 4; lim.communityID = "otherIdAAAA"
        #expect(MusicLyricsRevalidation.plan(lyrics: lim, fetchedAt: now.addingTimeInterval(-3600), now: now, request: request(), communityOn: true, order: order, preferWords: false) == .none)
        #expect(MusicLyricsRevalidation.plan(lyrics: lim, fetchedAt: now.addingTimeInterval(-90_000), now: now, request: request(), communityOn: true, order: order, preferWords: false) == .refreshCommunity(filedID: "otherIdAAAA", revision: 4))
        let lrc = synced("lrclib")
        let old = now.addingTimeInterval(-8 * 86400)
        #expect(MusicLyricsRevalidation.plan(lyrics: lrc, fetchedAt: old, now: now, request: request(), communityOn: true, order: order, preferWords: false) == .askCommunity)
        #expect(MusicLyricsRevalidation.plan(lyrics: lrc, fetchedAt: now.addingTimeInterval(-6 * 86400), now: now, request: request(), communityOn: true, order: order, preferWords: false) == .none)
        #expect(MusicLyricsRevalidation.plan(lyrics: lrc, fetchedAt: old, now: now, request: request(), communityOn: false, order: order, preferWords: false) == .none)
        var pinned = lrc; pinned.pinned = true
        #expect(MusicLyricsRevalidation.plan(lyrics: pinned, fetchedAt: old, now: now, request: request(), communityOn: true, order: order, preferWords: false) == .none)
        #expect(MusicLyricsRevalidation.plan(lyrics: lrc, fetchedAt: old, now: now, request: request(searched: true), communityOn: true, order: order, preferWords: false) == .none)
        var local = request(); local.isLocal = true
        #expect(MusicLyricsRevalidation.plan(lyrics: lrc, fetchedAt: old, now: now, request: local, communityOn: true, order: order, preferWords: false) == .none)
        // Community ranked below the cached source and the cached lyric settles: nothing to gain.
        let communityLast = MusicLyricsSources.resolve(order: ["lrclib", "community-lyrics"], enabled: [:]).filter(\.enabled)
        #expect(MusicLyricsRevalidation.plan(lyrics: lrc, fetchedAt: old, now: now, request: request(), communityOn: true, order: communityLast, preferWords: false) == .none)
        #expect(MusicLyricsRevalidation.plan(lyrics: lrc, fetchedAt: old, now: now, request: request(), communityOn: true, order: communityLast, preferWords: true) == .askCommunity)
    }

    @Test func diskStoreRoundTripLegacyRowsAndPinnedSurvival() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-core-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MusicLyricsDiskStore(directory: dir)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        await store.write(key: "a", lyrics: synced("lrclib"), fetchedAt: when)
        await store.write(key: "miss", lyrics: nil, fetchedAt: when)
        var pin = synced("unison"); pin.pinned = true
        await store.write(key: "pin", lyrics: pin, fetchedAt: when)
        let a = await store.read(key: "a")
        #expect(a?.lyrics?.providerID == "lrclib" && a?.fetchedAt == when && a?.legacy == false)
        let miss = await store.read(key: "miss")
        #expect(miss != nil && miss?.lyrics == nil)
        try JSONEncoder().encode(MusicLyrics(plain: "old", sourceName: "LRCLIB")).write(to: MusicLyricsDiskStore.fileURL(dir, key: "legacy"))
        let legacy = await store.read(key: "legacy")
        #expect(legacy?.legacy == true)
        await store.clear(keepPinned: true)
        let goneA = await store.read(key: "a"), goneMiss = await store.read(key: "miss"), kept = await store.read(key: "pin")
        #expect(goneA == nil && goneMiss == nil)
        #expect(kept?.lyrics?.pinned == true)
        await store.clear(keepPinned: false)
        let goneAll = await store.read(key: "pin")
        #expect(goneAll == nil)
    }

    // MARK: duet layout, lookup

    @Test func duetSidesBySingerNumberAndBackgroundRuns() {
        func line(_ t: Int64, _ voice: String?) -> MusicLyricLine { MusicLyricLine(timeMs: t, text: "x", voice: voice) }
        let lines = [line(0, "v2"), line(1, "v1"), line(2, nil), line(3, "v1000"), line(4, "v5")]
        let layout = MusicLyricsVoices.layout(lines)
        // singers 1, 2, 5 sorted: 1 near, 2 far, 5 near
        #expect(layout?.map(\.far) == [true, false, false, false, false])
        #expect(MusicLyricsVoices.layout([line(0, "v1"), line(1, "v1")]) == nil)
        #expect(MusicLyricsVoices.singer("v1000") == nil && MusicLyricsVoices.singer("v12") == 12 && MusicLyricsVoices.singer("v12345") == nil && MusicLyricsVoices.singer("x1") == nil)
        let bg = MusicLyricLine(timeMs: 0, text: "a (b)", words: [MusicLyricWord(text: "a ", startMs: 0, endMs: 500), MusicLyricWord(text: "(b)", startMs: 400, endMs: 1500, background: true)])
        let l = MusicLyricsVoices.layout([bg])
        #expect(l?[0].lead.count == 1 && l?[0].background.count == 1 && l?[0].untilMs == 1500)
    }

    @Test func lookupLookaheadLingeringAndOffsetClamp() {
        let lines = [MusicLyricLine(timeMs: 1000, text: "a"), MusicLyricLine(timeMs: 5000, text: "b"), MusicLyricLine(timeMs: 9000, text: "c")]
        #expect(MusicLyricsLookup.lineIndex(in: lines, at: 999) == nil && MusicLyricsLookup.lineIndex(in: lines, at: 5000) == 1)
        #expect(MusicLyricsLookup.scrollTarget(in: lines, at: 4500) == 1)
        let bgLines = [MusicLyricLine(timeMs: 0, text: "a", words: [MusicLyricWord(text: "a", startMs: 0, endMs: 9000, background: true)]), MusicLyricLine(timeMs: 4000, text: "b")]
        #expect(MusicLyricsLookup.lingeringIndex(in: bgLines, active: 1, at: 5000) == 0)
        #expect(MusicLyricsLookup.lingeringIndex(in: bgLines, active: 1, at: 9500) == nil)
        #expect(MusicLyricsLookup.clampOffset(40_000) == 15_000 && MusicLyricsLookup.clampOffset(-40_000) == -15_000)
    }

    // MARK: romanisation

    @Test func koreanRevisedRomanization() {
        #expect(MusicRomanizer.koreanReading("좋아해") == "joahae")
        #expect(MusicRomanizer.koreanReading("한국말") == "hangungmal")
        #expect(MusicRomanizer.koreanReading("같이") == "gachi")
        #expect(MusicRomanizer.koreanReading("신라") == "silla")
        #expect(MusicRomanizer.koreanReading("독립") == "dongnip")
        #expect(MusicRomanizer.koreanReading("좋다") == "jota")
        #expect(MusicRomanizer.koreanReading("입학") == "ipak")
        #expect(MusicRomanizer.koreanReading("음악") == "eumak")
    }

    @Test func otherScriptsAndJapaneseSamples() {
        #expect(MusicRomanizer.reading(of: "Привет мир", japanese: false) == "Privet mir")
        #expect(MusicRomanizer.reading(of: "我的驕傲", japanese: false)?.hasPrefix("wǒ de") == true)
        #expect(MusicRomanizer.reading(of: "Baby愛してる", japanese: true) == "Baby aishiteru")
        #expect(MusicRomanizer.reading(of: "私は学生です", japanese: true) == "watakushi wa gakusei desu")
        #expect(MusicRomanizer.reading(of: "待って", japanese: true) == "matte")
        #expect(MusicRomanizer.reading(of: "Already Latin", japanese: false) == nil)
        #expect(MusicRomanizer.reading(of: "สวัสดี", japanese: false) == nil)           // Thai is skipped on purpose
        #expect(MusicRomanizer.isJapanese(texts: ["愛してる", "夢"]) && !MusicRomanizer.isJapanese(texts: ["我的驕傲你好我的驕傲你好我的驕傲你好の"]))
    }

    @Test func readingIsAppliedOnlyWhenTheLyricHasNone() {
        let plain = MusicLyrics(synced: [MusicLyricLine(timeMs: 1, text: "한국말"), MusicLyricLine(timeMs: 2, text: "Hello")])
        let out = MusicRomanizer.apply(to: plain)
        #expect(out.synced?[0].romanized == "hangungmal" && out.synced?[1].romanized == nil)
        var own = plain; own.synced?[1].romanized = "own reading"
        #expect(MusicRomanizer.apply(to: own).synced?[0].romanized == nil)      // never mixes spellings
        let words = MusicLyrics(synced: [MusicLyricLine(timeMs: 1, text: "Привет мир", words: [MusicLyricWord(text: "Привет ", startMs: 1, endMs: 5), MusicLyricWord(text: "мир", startMs: 5, endMs: 9)])])
        let timed = MusicRomanizer.apply(to: words).synced?[0].romanizedWords
        #expect(timed?.map(\.text) == ["Privet ", "mir"] && timed?.map(\.startMs) == [1, 5])
    }

    @Test func localLyricsFileSizeAndDecoding() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lrc = dir.appendingPathComponent("Song.LRC")
        try Data("[00:01.00]hi\n[00:02.00]there".utf8).write(to: lrc)
        let audio = dir.appendingPathComponent("song.mp3")
        #expect(LocalLyricsProvider.sidecar(for: audio, ext: "lrc")?.lastPathComponent == "Song.LRC")
        #expect(LocalLyricsProvider.parseFile(lrc)?.isSynced == true)
        let big = dir.appendingPathComponent("big.lrc")
        try Data(repeating: 0x61, count: LocalLyricsProvider.maxFileBytes + 1).write(to: big)
        #expect(LocalLyricsProvider.parseFile(big) == nil)
    }
}

private final class LockedLyricsFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
