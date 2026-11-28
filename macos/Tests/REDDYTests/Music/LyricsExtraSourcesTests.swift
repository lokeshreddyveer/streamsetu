import Foundation
import Testing
@testable import REDDY

// Offline tests for the additional lyrics sources, the syllable and background rules, duet alternation, the lyric clock, translation
// data, the share card and the embedded lyric formats. Every answer is canned.

private struct CannedTransport: MusicHTTPTransport {
    let handler: @Sendable (URLRequest) -> (Int, String)
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (code, body) = handler(request)
        guard let url = request.url, let r = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil) else { throw MusicError.network("stub") }
        return (Data(body.utf8), r)
    }
}
private func canned(_ h: @escaping @Sendable (URLRequest) -> (Int, String)) -> MusicHTTP { MusicHTTP(transport: CannedTransport(handler: h)) }

private func req(title: String = "Song", artists: String = "Artist", seconds: Double? = 200, video: String? = "abcdEFGhij_", isrc: String? = nil) -> MusicLyricsRequest {
    var r = MusicLyricsRequest(videoID: video, title: title, artists: artists, album: nil, durationSeconds: seconds, searched: false)
    r.isrc = isrc
    return r
}

private func w(_ t: String, _ s: Int64, _ e: Int64, bg: Bool = false) -> MusicLyricWord { MusicLyricWord(text: t, startMs: s, endMs: e, background: bg) }

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    func update(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
}

private let simpleTTML = #"<tt><body><div><p begin="1s" end="2s"><span begin="1s" end="1.5s">Hi</span> <span begin="1.5s" end="2s">you</span></p></div></body></tt>"#

// MARK: - text rules

@Suite struct LyricsTextRuleTests {
    @Test func titleCleaning() {
        #expect(MusicLyricsTitleClean.title("Dracula (feat. JENNIE)") == "Dracula")
        #expect(MusicLyricsTitleClean.title("Levitating (feat. DaBaby) [Official Video]") == "Levitating")
        #expect(MusicLyricsTitleClean.title("(Official Video)") == "(Official Video)")
        #expect(MusicLyricsTitleClean.title("Dracula (JENNIE Remix)") == "Dracula (JENNIE Remix)")
        #expect(MusicLyricsTitleClean.title("Song ft. Someone") == "Song")
        #expect(MusicLyricsTitleClean.artist("Artist - Topic") == "Artist")
        #expect(MusicLyricsTitleClean.lrclibTitle("Song (From Movie) [HD] | Channel") == "Song")
    }

    @Test func isrcShape() {
        #expect(MusicISRC.normalize("us-um7 1700001") == "USUM71700001")
        #expect(MusicISRC.normalize("USUM7170000") == nil)
        #expect(MusicISRC.normalize("1SUM71700001") == nil)
        #expect(MusicISRC.normalize(nil) == nil)
    }

    @Test func entityDecodingBeyondTheBMP() {
        #expect(MusicLyricsText.decodeEntities("fire &#128293; it&#x27;s &amp;#x27; &nbsp;x") == "fire 🔥 it's &#x27;  x")
        #expect(MusicLyricsText.decodeEntities("bad &#99999999999; ref") == "bad &#99999999999; ref")
    }

    @Test func syllableGluing() {
        let g = MusicLyricsSyllables.glue([w("e", 0, 100), w("nough ", 100, 300), w("is", 300, 400)])
        #expect(g.count == 2 && g[0].text == "enough " && g[0].syllables?.count == 2)
        #expect(g[0].syllables?[0].endChar == 1 && g[0].syllables?[1].startChar == 1 && g[0].syllables?[1].endChar == 6)
        // No spacing anywhere: one word per run.
        #expect(MusicLyricsSyllables.glue([w("I", 0, 1), w("been", 1, 2), w("tryna", 2, 3)]).count == 3)
        // Explicit spacing is believed even with a single split word.
        let e = MusicLyricsSyllables.glue([w("Go", 0, 1), w("ing", 1, 2)], explicitSpacing: true)
        #expect(e.count == 1 && e[0].text == "Going" && e[0].syllables?.count == 2)
        // Unspaced scripts stay separate.
        #expect(MusicLyricsSyllables.glue([w("愛", 0, 1), w("して ", 1, 2)]).count == 2)
        // Background and lead never join.
        #expect(MusicLyricsSyllables.glue([w("a", 0, 1), w("b ", 1, 2, bg: true)]).count == 2)
    }

    @Test func charactersSungWithSyllablesAndPauses() {
        let g = MusicLyricsSyllables.glue([w("e", 0, 100), w("nough ", 200, 300)], explicitSpacing: true)[0]
        #expect(g.charsSung(at: 0) == 0 && g.charsSung(at: 150) == 1 && g.charsSung(at: 250) == 3 && g.charsSung(at: 400) == 6)
        let plain = w("hello", 0, 1000)
        #expect(plain.charsSung(at: 500) == 2 && plain.charsSung(at: 1000) == 5)
    }

    @Test func lineRevealWithWords() {
        let l = MusicLyricLine(timeMs: 0, text: "Hello world", endMs: 2000, words: [w("Hello ", 0, 1000), w("world", 1000, 2000)])
        #expect(l.revealedChars(at: 0) == 0)
        #expect(l.revealedChars(at: 2000) == 11)
        #expect(l.revealedChars(at: 1500) > 6 && l.revealedChars(at: 1500) < 11)
        let line = MusicLyricLine(timeMs: 1000, text: "abc")
        #expect(line.revealedChars(at: 999) == 0 && line.revealedChars(at: 1000) == 3)
        #expect(line.hasKnownEnd == false && l.hasKnownEnd && l.resolvedEndMs == 2000 && MusicLyricLine(timeMs: 5, text: "").isGap)
    }

    @Test func backgroundTailSplitting() {
        let words = [w("Hello ", 0, 500), w("world ", 500, 1000), w("(oh ", 1000, 1200), w("yeah)", 1200, 1500)]
        let split = MusicLyricsBackground.split(MusicLyricLine(timeMs: 0, text: "Hello world (oh yeah)", words: words))
        #expect(split.words?.map(\.background) == [false, false, true, true])
        let timed = MusicLyricsBackground.split(MusicLyricLine(timeMs: 0, text: "Hello (oh yeah)"))
        #expect(timed.backgroundText == "(oh yeah)")
        #expect(MusicLyricsBackground.split(MusicLyricLine(timeMs: 0, text: "(oh yeah)")).backgroundText == nil)
        #expect(MusicLyricsBackground.split(MusicLyricLine(timeMs: 0, text: "Hello (...)")).backgroundText == nil)
        var already = MusicLyricLine(timeMs: 0, text: "a (b)"); already.backgroundText = "(x)"
        #expect(MusicLyricsBackground.split(already).backgroundText == "(x)")
        // A bracket that does not start on a word boundary is left alone.
        let mid = MusicLyricLine(timeMs: 0, text: "Hel(lo)", words: [w("Hel", 0, 1), w("(lo)", 1, 2)])
        #expect(MusicLyricsBackground.split(mid).words?.contains(where: \.background) == false)
        #expect(MusicLyricsSyllables.displayBackground("(oh yeah)") == "oh yeah")
        #expect(MusicLyricsSyllables.displayWord(w("(oh ", 0, 1)).text == "oh ")
    }

    @Test func instrumentalGaps() {
        let a = MusicLyricLine(timeMs: 5000, text: "a", endMs: 7000, words: [w("a", 5000, 7000)])
        let b = MusicLyricLine(timeMs: 13000, text: "b", endMs: 14000, words: [w("b", 13000, 14000)])
        let out = MusicLyricsGaps.insert(into: [a, b])
        #expect(out.map(\.timeMs) == [0, 5000, 7000, 13000] && out[0].isGap && out[2].isGap)
        let near = MusicLyricLine(timeMs: 8000, text: "c", endMs: 9000, words: [w("c", 8000, 9000)])
        #expect(MusicLyricsGaps.insert(into: [a, near]).count == 3)
        let lrc = [MusicLyricLine(timeMs: 1000, text: ""), MusicLyricLine(timeMs: 2000, text: "x"), MusicLyricLine(timeMs: 9000, text: "")]
        #expect(MusicLyricsGaps.pruneEmptyStamps(lrc).map(\.timeMs) == [2000, 9000])
    }

    @Test func duetAlternation() {
        #expect(MusicLyricsVoices.alternationSides(["a", "b", "a", "b"]) == [false, true, false, true])
        #expect(MusicLyricsVoices.alternationSides(["a", "a", "b"]) == [false, false, true])
        #expect(MusicLyricsVoices.alternationSides(["a", "a"]) == nil)
        #expect(MusicLyricsVoices.alternationSides(["a", "v1000", "b"]) == [false, false, true])
        #expect(MusicLyricsVoices.alternationSides([nil, "a", nil, "b"]) == [false, false, false, true])
        // The first voice of type "other" starts on the far side; when 85% or more landed far the song flips.
        let flipped = MusicLyricsVoices.alternationSides(["a", "a", "a", "a", "a", "a", "a", "b"], types: ["a": "other"])
        #expect(flipped == [false, false, false, false, false, false, false, true])
        // Layout uses it for agent ids that are not numbered singers.
        let lines = ["x", "y", "x"].enumerated().map { MusicLyricLine(timeMs: Int64($0.offset) * 1000, text: "l", voice: $0.element) }
        #expect(MusicLyricsVoices.layout(lines)?.map(\.far) == [false, true, false])
    }
}

// MARK: - parsing the answers

@Suite struct LyricsEnvelopeTests {
    @Test func jsonWrappersFencesAndNotices() {
        let json = MusicLyricsEnvelope.parse(#"{"lyrics":"[00:01.00]hi\n[00:05.00]there"}"#, source: "S", provider: "p")
        #expect(json?.synced?.map(\.text) == ["hi", "there"])
        let fenced = MusicLyricsEnvelope.parse("```\n[00:01.00]hi\n[00:02.00]yo\n```", source: "S", provider: "p")
        #expect(fenced?.synced?.count == 2)
        #expect(MusicLyricsEnvelope.parse("Lyrics not found", source: "S", provider: "p") == nil)
        #expect(MusicLyricsEnvelope.parse(#"{"error":"nope","lyrics":"[00:01.00]x"}"#, source: "S", provider: "p") == nil)
        #expect(MusicLyricsEnvelope.parse("[00:01.00]纯音乐，请欣赏", source: "S", provider: "p") == nil)
        #expect(MusicLyricsEnvelope.parse("plain one\nplain two", source: "S", provider: "p")?.plain == "plain one\nplain two")
    }

    @Test func escapedTTMLAndKaraoke() {
        let esc = "&lt;tt xmlns=&quot;http://www.w3.org/ns/ttml&quot;&gt;&lt;body&gt;&lt;div&gt;&lt;p begin=&quot;1s&quot; end=&quot;2s&quot;&gt;Hi&lt;/p&gt;&lt;p begin=&quot;3s&quot; end=&quot;4s&quot;&gt;Yo&lt;/p&gt;&lt;/div&gt;&lt;/body&gt;&lt;/tt&gt;"
        #expect(MusicLyricsEnvelope.parse(esc, source: "S", provider: "p")?.synced?.first?.text == "Hi")
        let qrc = MusicLyricsEnvelope.parse("[1000,2000]Hel(1000,300)lo (1300,400)world(1700,300)", source: "S", provider: "p")
        let line = qrc?.synced?.first
        #expect(line?.text == "Hello world" && line?.endMs == 3000 && line?.words?.count == 2 && line?.words?[0].syllables?.count == 2)
        let yrc = MusicLyricsEnvelope.parseKaraoke("[500,1000](500,400)Go (900,600)on")
        #expect(yrc.first?.words?.map(\.text).joined().trimmingCharacters(in: .whitespaces) == "Go on")
    }

    @Test func ttmlSingersAgentsAndTranslationSpans() {
        let ttml = #"<tt xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><head><metadata><ttm:agent type="person" xml:id="v1"/><ttm:agent type="other" xml:id="v2"/></metadata></head><body><div><p begin="1s" end="2s" ttm:agent="v1"><span begin="1s" end="2s">Hi</span><span ttm:role="x-translation">Hola</span></p><p begin="3s" end="4s" ttm:agent="v2"><span begin="3s" end="4s">Yo</span></p></div></body></tt>"#
        let l = MusicLyricsEnvelope.parse(ttml, source: "S", provider: "p")
        #expect(l?.synced?.map(\.text) == ["Hi", "Yo"] && l?.synced?.map(\.voice) == ["v1", "v2"])
        #expect(l?.voiceTypes == ["v1": "person", "v2": "other"])
    }

    @Test func recordingMatchRules() {
        let ok = { (t: String, a: String, s: Double?) in MusicRecordingMatch.accepts(wantTitle: "Song", wantArtist: "Artist", wantSeconds: 200, title: t, artist: a, seconds: s) }
        #expect(ok("Song", "Artist", 201.5) && ok("Sóng", "Eminem & Artist", 200) && ok("Song (Remastered 2011)", "artist", nil))
        #expect(!ok("Song (Live)", "Artist", 200) && !ok("Song", "Other", 200) && !ok("Song", "Artist", 205) && !ok("Other Song", "Artist", 200))
        #expect(MusicRecordingMatch.versions("Song (Acoustic) - Remix") == ["acoustic", "remix"])
        #expect(MusicRecordingMatch.coreTitle("Hello - Radio Edit") == "hello")
        let rows = (0..<15).map { BiniLyricsProvider.Result(title: "Mockingbird", artist: "Other \($0)", seconds: 251, isrc: "USUM71700001", url: "https://x/\($0)", timing: "word") }
        #expect(BiniLyricsProvider.pick(rows, title: "Mockingbird", artist: "Eminem", seconds: 251) == nil)
    }

    @Test func candidateScoringOverAnyJSON() {
        let obj: [String: Any] = ["results": ["songs": ["data": [
            ["id": "1", "attributes": ["name": "Other", "artistName": "Nobody", "durationInMillis": 100_000]],
            ["id": "2", "attributes": ["name": "Song", "artistName": "Artist", "durationInMillis": 201_000]]]]]]
        #expect(MusicCandidateScore.best(in: obj, title: "Song", artist: "Artist", seconds: 200)?.id == "2")
        #expect(MusicCandidateScore.best(in: obj, title: "Zzz", artist: "Qqq", seconds: 5) == nil)
    }
}

// MARK: - sources

@Suite struct LyricsNewSourceTests {
    @Test func everySourceIsRegisteredWithAPrivacyNote() {
        let order = MusicLyricsSources.defaultOrder
        #expect(order.count == 19 && Set(order).count == 19)
        for id in order { #expect(MusicLyricsSources.names[id] != nil && MusicLyricsSources.about[id] != nil) }
        #expect(MusicLyricsSources.defaultEnabled.values.allSatisfy { $0 } && MusicLyricsSources.defaultEnabled.count == 19)
        let h = MusicHTTP()
        let infos = [LrcRedProvider(http: h).info, BiniLyricsProvider(http: h).info, PortatoProvider(http: h).info, PaxSenixProvider(http: h).info,
                     SimpMusicProvider(http: h).info, MegalobizProvider(http: h).info, MusixmatchProvider(http: h).info, GeniusProvider(http: h).info,
                     MusicYouTubeCaptionsProvider().info]
        #expect(infos.allSatisfy { !$0.privacyNote.isEmpty } && Set(infos.map(\.id)).count == 9)
        #expect(PaxSenixProvider(http: h).info.privacyNote.contains("unofficial access to a third-party web client"))
        #expect(MusixmatchProvider(http: h).info.privacyNote.contains("unofficial access to a third-party service"))
        #expect(MusicLyricsSources.lazyProviders == [MusicLyricsSources.genius])
    }

    @Test func lrcRedPicksTheRecordingByNameAndReadsItsDocument() async throws {
        let search = #"{"hits":[{"isrc":"USUM70000001","title":"Song (Live)","artist":"Artist","duration":200},{"isrc":"USUM70000002","title":"Song","artist":"Artist","duration":201.2}],"next":null}"#
        let stub = canned { r in r.url?.path == "/search.json" ? (200, search) : (200, simpleTTML) }
        let l = try await LrcRedProvider(http: stub).lyrics(for: req())
        #expect(l?.isWordTimed == true && l?.synced?.first?.text == "Hi you")
        let hit = LrcRedProvider.pick(try MusicLyricsIO.parse(Data(search.utf8)), title: "Song", artist: "Artist", seconds: 200)
        #expect(hit?.isrc == "USUM70000002")
        // With a known recording code the document is fetched directly.
        let direct = Box<[String]>([])
        let s2 = canned { r in direct.update { $0.append(r.url?.path ?? "") }; return (200, simpleTTML) }
        _ = try await LrcRedProvider(http: s2).lyrics(for: req(isrc: "USUM70000009"))
        #expect(direct.value == ["/s/USUM70000009.ttml"])
    }

    @Test func biniLyricsIdentifiesAndReadsTheNamedDocument() async throws {
        let results = #"{"total":1,"source":"HIT-EXACT","results":[{"id":1,"track_name":"Song","artist_name":"Artist","album_name":"A","duration":200,"isrc":"USUM70000003","timing_type":"word","lyricsUrl":"https://lyrics-storage.binimum.org/bini-test-doc.ttml"}]}"#
        let stub = canned { r in r.url?.path == "/api/v1" ? (200, results) : (200, simpleTTML) }
        let p = BiniLyricsProvider(http: stub)
        let found = await p.identify(req())
        #expect(found?.isrc == "USUM70000003" && found?.documentURL == "https://lyrics-storage.binimum.org/bini-test-doc.ttml")
        var r = req(); r.identified = found
        #expect(try await p.lyrics(for: r)?.isWordTimed == true)
        let miss = canned { _ in (404, "") }
        let none = await BiniLyricsProvider(http: miss).identify(req())
        #expect(none == nil)
    }

    @Test func recordingMemoryKeepsOneHundred() async {
        let m = MusicRecordingMemory()
        for i in 0..<130 { await m.set("v\(i)", MusicLyricsIdentified(isrc: "USUM7000000\(i % 10)", documentURL: nil)) }
        let count = await m.count, first = await m.get("v0"), last = await m.get("v129")
        #expect(count == 100 && first == nil && last != nil)
    }

    @Test func portatoRejectsPlaceholders() {
        let ok = PortatoProvider.map(Data("[1000,1000]Hi(1000,500)\n[3000,1000]Yo(3000,500)".utf8))
        #expect(ok?.synced?.first?.text == "Hi")
        #expect(PortatoProvider.map(Data("[00:01.00]Instrumental\n[00:03.00]Instrumental".utf8)) == nil)
    }

    @Test func paxSenixTokenKeyAndStructuredAnswer() {
        #expect(PaxSenixAppleToken.firstJWT(in: "x var t=\"eyJhbGciOi.abc_def.ghi-jk\"; y") == "eyJhbGciOi.abc_def.ghi-jk")
        #expect(PaxSenixAppleToken.scriptPath(in: #"<script src="/assets/index~abc123.js"></script>"#) == "/assets/index~abc123.js")
        #expect(PaxSenixProvider.cleanKey("  Bearer   abc ") == "abc" && PaxSenixProvider.cleanKey("   ") == nil)
        let body = #"{"content":[{"timestamp":1000,"text":[{"text":"Hel","timestamp":1000,"endtime":1300,"part":true},{"text":"lo","timestamp":1300,"endtime":1600,"part":false},{"text":"you","timestamp":1600,"endtime":2000,"part":false}]},{"timestamp":3000,"text":[{"text":"Bye","timestamp":3000,"part":false}]}]}"#
        let l = PaxSenixProvider.map(Data(body.utf8))
        let first = l?.synced?.first
        #expect(first?.text == "Hello you" && first?.words?[0].text == "Hello " && first?.words?[0].syllables?.count == 2 && first?.endMs == 2000)
        #expect(l?.synced?.last?.words?.first?.endMs == 3800)
    }

    @Test func simpMusicPrefersRichSyncAndDecodesEntities() {
        let obj: [String: Any] = ["success": true, "data": [
            ["duration": 100, "syncedLyrics": "[00:01.00]far"],
            ["duration": 201, "syncedLyrics": "[00:01.00]it&#x27;s\n[00:03.00]ok"]]]
        let l = SimpMusicProvider.map(obj, wantSeconds: 200)
        #expect(l?.synced?.first?.text == "it's" && l?.synced?.count == 2)
        #expect(SimpMusicProvider.map(obj, wantSeconds: 500) == nil)
    }

    @Test func megalobizPageReading() {
        let search = #"<a href="/lrc/maker/foo-bar.html">x</a>"#
        #expect(MegalobizProvider.firstLink(in: search) == "/lrc/maker/foo-bar.html")
        let page = #"<span id="lrc_1_details">[00:01.00]hi<br>[00:02.00]there &amp; you</span>"#
        #expect(MegalobizProvider.lrcText(in: page) == "[00:01.00]hi\n[00:02.00]there & you")
        #expect(MegalobizProvider.lrcText(in: "<p>none</p>") == nil)
    }

    @Test func musixmatchScoringParsingAndSigning() throws {
        let list = #"{"message":{"header":{"status_code":200},"body":{"track_list":[{"track":{"track_id":1,"track_name":"Song Remix","artist_name":"Artist","track_length":260,"has_richsync":1}},{"track":{"track_id":2,"track_name":"Song","artist_name":"The Artist","track_length":201,"has_richsync":0}}]}}}"#
        let obj = try MusicLyricsIO.parse(Data(list.utf8))
        #expect(MusixmatchProvider.pickTrack(obj, title: "Song", artist: "Artist", seconds: 200)?.id == 2)
        #expect(MusixmatchProvider.status(obj) == 200)
        let rich = #"[{"ts":1.0,"te":3.0,"l":[{"c":"Hel","o":0},{"c":"lo ","o":0.5},{"c":"you","o":1.0}],"x":"Hello you"}]"#
        let r = MusixmatchProvider.parseRichsync(rich)?.first
        #expect(r?.text == "Hello you" && r?.words?.count == 2 && r?.words?[0].syllables?.count == 2 && r?.timeMs == 1000 && r?.endMs == 3000)
        #expect(MusixmatchProvider.parseSubtitle(#"[{"text":"hi","time":{"total":1.5}}]"#)?.first?.timeMs == 1500)
        let u = try MusixmatchProvider.url("macro.subtitles.get", ["q_track": "a b", "usertoken": "tok"]).absoluteString
        #expect(u.hasPrefix("https://apic-appmobile.musixmatch.com/ws/1.1/macro.subtitles.get?") && u.contains("app_id=mac-ios-v2.0") && !u.contains("signature"))
        let richBody = #"[{"ts":1.0,"te":3.0,"l":[{"c":"Hel","o":0},{"c":"lo","o":0.5}],"x":"Hello"}]"#
        let calls: [String: Any] = [
            "matcher.track.get": ["message": ["body": ["track": ["track_id": 5, "track_name": "Blinding Lights", "artist_name": "The Weeknd", "track_length": 200]]]],
            "track.subtitles.get": ["message": ["body": ["subtitle_list": [["subtitle": ["subtitle_body": "[00:14.35] Yeah\n[00:27.41] I've been tryna call"]]]]]],
            "track.richsync.get": ["message": ["body": ["richsync": ["richsync_body": richBody]]]]]
        let rich2 = MusixmatchProvider.lyrics(from: calls, title: "Blinding Lights", artist: "The Weeknd", seconds: 200)
        #expect(rich2?.synced?.first?.words != nil)
        var lineOnly = calls; lineOnly["track.richsync.get"] = nil
        #expect(MusixmatchProvider.lyrics(from: lineOnly, title: "Blinding Lights", artist: "The Weeknd", seconds: 200)?.synced?.count == 2)
        #expect(MusixmatchProvider.lyrics(from: lineOnly, title: "Another Song", artist: "Someone Else", seconds: 200) == nil)
    }

    @Test func geniusQueriesScoringAndPage() throws {
        let q = GeniusProvider.queries(title: "Song (feat. X)", artist: "Artist")
        #expect(q.first == "Artist Song (feat. X)" && q.count <= 5 && Set(q).count == q.count && q.contains("Song"))
        let (t, a) = GeniusProvider.workOut(title: "Artist - Song", artist: "Artist")
        #expect(t == "Song" && a == "Artist")
        let search = #"{"response":{"sections":[{"type":"song","hits":[{"result":{"path":"/Artist-song-translation-lyrics","title":"Song","primary_artist":{"name":"Artist"}}},{"result":{"path":"/Artist-song-lyrics","title":"Song","primary_artist":{"name":"Artist"}}}]}]}}"#
        let hits = GeniusProvider.hits(try MusicLyricsIO.parse(Data(search.utf8)), title: "Song", artist: "Artist")
        #expect(GeniusProvider.best(hits)?.path == "/Artist-song-lyrics")
        let page = #"<html><div data-lyrics-container="true">[Verse 1]<br/>Line one<br/>Line two<div data-exclude-from-selection="true">Hidden</div><br/><br/>Line three</div><div>after</div></html>"#
        #expect(GeniusProvider.lyricsText(inPage: page) == "[Verse 1]\nLine one\nLine two\n\nLine three")
        #expect(GeniusProvider.isSectionMarker("[Chorus]") && !GeniusProvider.isSectionMarker("[]"))
        #expect(GeniusProvider.build("a\n\nb")?.plain == "a\n\nb")
    }

    @Test func youTubeCaptionsReadersAndAvailability() async throws {
        let transcript: [String: Any] = ["actions": [
            ["transcriptCueRenderer": ["startOffsetMs": "2000", "cue": ["simpleText": " ♪ hi \n"]]],
            ["transcriptCueRenderer": ["startOffsetMs": "1000", "cue": ["runs": [["text": "first"]]]]],
            ["transcriptCueRenderer": ["startOffsetMs": "3000", "cue": ["simpleText": "  "]]]]]
        #expect(MusicYouTubeCaptionsProvider.transcriptLines(in: transcript).map(\.text) == ["first", "hi"])
        let j3: [String: Any] = ["events": [["tStartMs": 500, "segs": [["utf8": "a "], ["utf8": "b"]]], ["tStartMs": 100, "segs": [["utf8": "\n"]]]]]
        #expect(MusicYouTubeCaptionsProvider.json3Lines(j3).map(\.text) == ["a b"])
        let link = MusicYouTubeCaptionsLink()
        let p = MusicYouTubeCaptionsProvider(link: link)
        #expect(!p.isAvailable)
        struct Src: MusicYouTubeCaptionsSource { func captions(videoID: String) async throws -> [MusicYouTubeTimedLine] { [MusicYouTubeTimedLine(text: "x", startMs: 10), MusicYouTubeTimedLine(text: "y", startMs: 20)] } }
        link.source = Src()
        let got = try await p.lyrics(for: req())
        #expect(p.isAvailable && got?.synced?.count == 2)
    }

    @Test func unisonShapes() async throws {
        let ttml = try MusicLyricsIO.parse(Data(#"{"success":true,"data":{"format":"ttml","syncType":"wordsync","lyrics":"\#(simpleTTML.replacingOccurrences(of: "\"", with: "\\\""))"}}"#.utf8))
        #expect(UnisonProvider.map(ttml)?.isWordTimed == true)
        let plain = ["data": ["format": "lrc", "syncType": "plain", "lyrics": "a\n\nb"]]
        #expect(UnisonProvider.map(plain)?.plain == "a\n\nb")
        #expect(UnisonProvider.map(["data": ["format": "lrc", "lyrics": "  "]]) == nil)
        // The name lookup on the newer host is used when the id lookup misses.
        let hosts = Box<[String]>([])
        let stub = canned { r in
            hosts.update { $0.append((r.url?.host ?? "") + "?" + (r.url?.query ?? "")) }
            if r.url?.host == "unison.boidu.dev" { return (200, #"{"data":{"format":"lrc","lyrics":"[00:01.00]hi\n[00:02.00]yo"}}"#) }
            return (404, "")
        }
        #expect(try await UnisonProvider(http: stub).lyrics(for: req())?.synced?.count == 2)
        #expect(hosts.value.first?.contains("v=abcdEFGhij_") == true && hosts.value.last?.hasPrefix("unison.boidu.dev?") == true)
    }

    @Test func lyricsPlusRacesMirrors() async throws {
        let body = #"{"type":"Line","lyrics":[{"time":1000,"duration":2000,"text":"hi","syllabus":[]},{"time":4000,"duration":1000,"text":"there","syllabus":[]}]}"#
        let one = canned { r in r.url?.host == "lyricsplus.binimum.org" ? (200, body) : (500, "") }
        #expect(try await LyricsPlusProvider(http: one).lyrics(for: req(isrc: "USUM70000001"))?.synced?.count == 2)
        let none = canned { _ in (500, "") }
        await #expect(throws: MusicError.self) { _ = try await LyricsPlusProvider(http: none).lyrics(for: req()) }
        let missing = canned { _ in (404, "") }
        #expect(try await LyricsPlusProvider(http: missing).lyrics(for: req()) == nil)
        let sent = Box<String>("")
        let spy = canned { r in sent.update { $0 = r.url?.query ?? "" }; return (404, "") }
        _ = try await LyricsPlusProvider(http: spy).lyrics(for: req(isrc: "USUM70000001"))
        #expect(sent.value.contains("isrc=USUM70000001"))
    }

    @Test func kugouCreditsAreStripped() throws {
        let lrc = "[00:00.00]Song - Artist\n[00:01.00]Lyricist: A\n[00:02.00]Composer\u{FF1A}B\n[00:10.00]real line one\n[00:20.00]real line two\n[03:00.00]Produced by: C"
        #expect(KugouProvider.stripCredits(lrc) == "[00:10.00]real line one\n[00:20.00]real line two")
        let content = Data("[00:00.00]\u{7EAF}\u{97F3}\u{4E50}\u{FF0C}\u{8BF7}\u{6B23}\u{8D4F}".utf8).base64EncodedString()
        #expect(KugouProvider.map(["content": content]) == nil)
        let ok = Data("[00:10.00]one\n[00:20.00]two".utf8).base64EncodedString()
        #expect(KugouProvider.map(["content": ok])?.synced?.count == 2)
    }
}

// MARK: - walk additions

@Suite struct LyricsWalkAdditionTests {
    private func events(_ out: Box<[String]>) -> @Sendable (String, MusicLyricsWalkEvent) -> Void {
        { id, e in
            let name: String
            switch e { case .started: name = "started"; case .hit: name = "hit"; case .none: name = "none"; case .error: name = "error"; case .cancelled: name = "cancelled" }
            out.update { $0.append("\(id):\(name)") }
        }
    }

    @Test func lazySourceRunsOnlyWhenEverythingAboveMissed() async {
        let ran = Box(0)
        let lazy = MusicLyricsWalkEntry(id: "g", takesSlot: true, lazy: true) { ran.update { $0 += 1 }; return MusicLyrics(plain: "words", providerID: "g") }
        let log = Box<[String]>([])
        let miss = MusicLyricsWalkEntry(id: "a", takesSlot: true) { nil }
        let o1 = await MusicLyricsWalk.run([miss, lazy], preferWords: false, stagger: 0, progress: events(log))
        #expect(o1.lyrics?.plain == "words" && ran.value == 1)
        let log2 = Box<[String]>([])
        let hit = MusicLyricsWalkEntry(id: "a", takesSlot: true) { MusicLyrics(plain: "plain", providerID: "a") }
        let o2 = await MusicLyricsWalk.run([hit, lazy], preferWords: false, stagger: 0, progress: events(log2))
        #expect(o2.lyrics?.plain == "plain" && ran.value == 1 && log2.value.contains("g:cancelled"))
        let syncedHit = MusicLyricsWalkEntry(id: "a", takesSlot: true) { MusicLyrics(synced: [MusicLyricLine(timeMs: 1, text: "x"), MusicLyricLine(timeMs: 2, text: "y")], providerID: "a") }
        let o3 = await MusicLyricsWalk.run([syncedHit, lazy], preferWords: false, stagger: 0)
        #expect(o3.lyrics?.isSynced == true && ran.value == 1)
    }

    @Test func eventsReportEachSource() async {
        let log = Box<[String]>([])
        let a = MusicLyricsWalkEntry(id: "a", takesSlot: true) { nil }
        let b = MusicLyricsWalkEntry(id: "b", takesSlot: true) { throw MusicError.network("x") }
        _ = await MusicLyricsWalk.run([a, b], preferWords: false, stagger: 0, progress: events(log))
        #expect(log.value.contains("a:started") && log.value.contains("a:none") && log.value.contains("b:error"))
        #expect(MusicLyricsSourceState.notFound.label == "Lyrics not found" && MusicLyricsSourceState.fetching.label.hasPrefix("Fetching"))
    }
}

// MARK: - offset

@Suite struct LyricsOffsetTests {
    @Test func globalOffsetArithmetic() throws {
        #expect(MusicLyricsLookup.lyricPosition(playbackMs: 10_000, globalOffsetMs: 1500) == 8500)
        #expect(MusicLyricsLookup.lyricPosition(playbackMs: 1000, globalOffsetMs: 1500) == 0)
        #expect(MusicLyricsLookup.lyricPosition(playbackMs: 10_000, globalOffsetMs: 1000, songOffsetMs: 500) == 8500)
        #expect(MusicLyricsLookup.seekTarget(lineMs: 8500, globalOffsetMs: 1500) == 10_000)
        #expect(MusicLyricsLookup.seekTarget(lineMs: 100, globalOffsetMs: -500) == 0)
        #expect(MusicLyricsLookup.clampGlobalOffset(7000) == 5000 && MusicLyricsLookup.clampGlobalOffset(-9000) == -5000 && MusicLyricsLookup.clampGlobalOffset(1234) == 1200)
        #expect(MusicLyricsLookup.offsetLabel(1500) == "+1.5 s" && MusicLyricsLookup.offsetLabel(-300) == "-0.3 s" && MusicLyricsLookup.offsetLabel(0) == "+0.0 s")
        let s = try JSONDecoder().decode(MusicSettings.self, from: Data(#"{"lyricsOffsetMs":9000}"#.utf8))
        #expect(s.lyricsOffsetMs == 5000 && MusicSettings().lyricsOffsetMs == 0)
        let back = try JSONDecoder().decode(MusicSettings.self, from: try JSONEncoder().encode(MusicSettings(lyricsOffsetMs: -700)))
        #expect(back.lyricsOffsetMs == -700)
    }

    @Test func newModelFieldsKeepOldRowsDecodable() throws {
        let old = try JSONDecoder().decode(MusicLyrics.self, from: Data(#"{"synced":[{"timeMs":1,"text":"a","words":[{"text":"a","startMs":1,"endMs":2}]}],"sourceName":"S"}"#.utf8))
        #expect(old.synced?.first?.words?.first?.syllables == nil && old.voiceTypes.isEmpty && old.synced?.first?.backgroundText == nil)
        var l = old
        l.synced?[0].words?[0].syllables = [MusicLyricSyllable(startMs: 1, endMs: 2, startChar: 0, endChar: 1)]
        l.synced?[0].backgroundText = "(x)"; l.voiceTypes = ["v1": "person"]
        let back = try JSONDecoder().decode(MusicLyrics.self, from: try JSONEncoder().encode(l))
        #expect(back == l)
        let plain = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        #expect(!plain.contains("syllables") && !plain.contains("voiceTypes") && !plain.contains("backgroundText"))
    }
}

// MARK: - the lyric clock

@Suite struct LyricClockTests {
    /// Frames at 60 Hz from `from` to `to`; a reading every 0.5 s computed by `position`.
    private func drive(_ c: inout MusicLyricClock, from: Double, to: Double, token: Int = 0, position: (Double) -> Double, readings: Bool = true) -> [Double] {
        var out: [Double] = []
        var t = from
        var nextReading = from
        while t <= to + 1e-9 {
            if readings, t + 1e-9 >= nextReading { c.ingest(MusicLyricClockReading(positionMs: position(t), takenAt: t, token: token)); nextReading += 0.5 }
            out.append(c.positionMs(at: t))
            t += 1.0 / 60
        }
        return out
    }

    @Test func steadyPlaybackFollowsTheSong() {
        var c = MusicLyricClock()
        let frames = drive(&c, from: 0, to: 4) { $0 * 1000 }
        #expect(abs((frames.last ?? 0) - 4000) < 40)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $1 >= $0 })
    }

    @Test func learnsAFasterPlaybackRate() {
        var c = MusicLyricClock()
        let frames = drive(&c, from: 0, to: 6) { $0 * 1250 }
        #expect(abs(c.rate - 1.25) < 0.06 && c.rateSettled)
        #expect(abs((frames.last ?? 0) - 7500) < 200)
    }

    @Test func announcedSeekJumpsFarAndRollsNear() {
        var c = MusicLyricClock()
        _ = drive(&c, from: 0, to: 2) { $0 * 1000 }
        c.ingest(MusicLyricClockReading(positionMs: 60_000, takenAt: 2.02, token: 1))
        #expect(abs(c.positionMs(at: 2.03) - 60_000) < 100)
        var d = MusicLyricClock()
        _ = drive(&d, from: 0, to: 2) { $0 * 1000 }
        d.ingest(MusicLyricClockReading(positionMs: 3000, takenAt: 2.0, token: 1))
        let mid = d.positionMs(at: 2.1)
        #expect(mid > 2100 && mid < 3200)
        var last = 0.0
        var t = 2.1
        while t < 2.5 { last = d.positionMs(at: t); t += 1.0 / 60 }
        #expect(abs(last - 3500) < 80)
    }

    @Test func unannouncedBackwardsReadingIsRefusedAndNeverMovesTheDisplayBack() {
        var c = MusicLyricClock()
        var frames = drive(&c, from: 0, to: 2) { $0 * 1000 }
        c.ingest(MusicLyricClockReading(positionMs: 500, takenAt: 2.0))
        var t = 2.0
        while t < 2.6 { frames.append(c.positionMs(at: t)); t += 1.0 / 60 }
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $1 >= $0 })
        #expect(abs((frames.last ?? 0) - 2600) < 120)
    }

    @Test func aFarReadingNeedsASecondOneToAgree() {
        var c = MusicLyricClock()
        _ = drive(&c, from: 0, to: 2) { $0 * 1000 }
        c.ingest(MusicLyricClockReading(positionMs: 12_500, takenAt: 2.5))
        #expect(abs(c.positionMs(at: 2.5) - 2500) < 120)
        c.ingest(MusicLyricClockReading(positionMs: 13_000, takenAt: 3.0))
        _ = c.positionMs(at: 3.0)
        #expect(abs(c.positionMs(at: 3.02) - 13_020) < 150)
    }

    @Test func pausedClockHoldsAndResumeStartsFresh() {
        var c = MusicLyricClock()
        _ = drive(&c, from: 0, to: 1) { $0 * 1000 }
        c.ingest(MusicLyricClockReading(positionMs: 1000, takenAt: 1.0, advancing: false))
        #expect(c.positionMs(at: 2.0) == 1000 && c.positionMs(at: 3.0) == 1000 && !c.isRunning)
        c.ingest(MusicLyricClockReading(positionMs: 1000, takenAt: 5.0))
        _ = c.positionMs(at: 5.0)
        #expect(abs(c.positionMs(at: 5.5) - 1500) < 60)
    }
}

// MARK: - translation data

private struct UpperTranslator: MusicLyricsTextTranslator {
    func availability(source: String?, target: String) async -> MusicTranslatorAvailability { .ready }
    func translate(_ texts: [String], source: String?, target: String) async throws -> [String] { texts.map { $0.uppercased() } }
}

@Suite struct LyricsTranslationDataTests {
    private func lines() -> [MusicLyricLine] {
        var l1 = MusicLyricLine(timeMs: 1000, text: "Hello (oh yeah)")
        l1.backgroundText = "(oh yeah)"
        return [MusicLyricLine(timeMs: 0, text: "[Chorus]"), l1, MusicLyricLine(timeMs: 2000, text: "")]
    }

    @Test func slotsKeepMarkersAndBackgrounds() {
        let slots = MusicLyricsSlots.build(lines())
        #expect(slots.map(\.text) == ["Chorus", "Hello", "oh yeah"] && slots[0].wrapped && slots[2].background)
        let out = MusicLyricsSlots.assemble(lineCount: 3, slots: slots, texts: ["Estribillo", "Hola", "oh si"])
        #expect(out[0]?.text == "[Estribillo]" && out[1]?.text == "Hola" && out[1]?.background == "oh si" && out[2] == nil)
        let sub = MusicLyricsSubLines(kind: .translation, target: "es", source: "en", lines: [nil, MusicLyricSubLine(text: "hello"), nil])
        #expect(sub.display(for: 1, original: "Hello") == nil && sub.display(for: 0, original: "x") == nil)
        #expect(MusicLyricsSubLines.revealedChars(original: MusicLyricLine(timeMs: 0, text: "abcd"), position: 10, translatedLength: 8) == 8)
    }

    @Test func languageTags() {
        #expect(MusicTranslationLanguage.canonical("iw") == "he" && MusicTranslationLanguage.canonical("in") == "id" && MusicTranslationLanguage.canonical("ji") == "yi")
        #expect(MusicTranslationLanguage.canonical("zh_TW") == "zh-Hant" && MusicTranslationLanguage.canonical("zh-CN") == "zh-Hans")
        #expect(MusicTranslationLanguage.canonical("pt-BR") == "pt" && MusicTranslationLanguage.canonical(" ") == "en")
        #expect(!MusicTranslationLanguage.same("zh-Hans", "zh-Hant") && MusicTranslationLanguage.same("en-US", "en-GB"))
        #expect(MusicTranslationLanguage.detect(["Hola amigo, como estas hoy, me gusta la musica"]) == "es")
    }

    @Test func gzipRoundTripAndCorruption() throws {
        let data = Data(String(repeating: "lyrics ", count: 400).utf8)
        let gz = try #require(MusicGzip.compress(data))
        #expect(gz.count < data.count && gz.starts(with: [0x1F, 0x8B]) && MusicGzip.decompress(gz) == data)
        var bad = gz; bad[bad.count - 1] ^= 0xFF
        #expect(MusicGzip.decompress(bad) == nil)
        #expect(MusicGzip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func cacheKeysLimitsAndPersistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-translation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let k1 = MusicLyricsTranslationCache.key(trackID: "t", target: "es", slots: ["a", "b"])
        #expect(k1 == MusicLyricsTranslationCache.key(trackID: "t", target: "es", slots: ["a", "b"]))
        #expect(k1 != MusicLyricsTranslationCache.key(trackID: "t", target: "fr", slots: ["a", "b"]) && k1 != MusicLyricsTranslationCache.key(trackID: "t", target: "es", slots: ["ab"]))
        let cache = MusicLyricsTranslationCache(directory: dir)
        for i in 0..<15 {
            cache.put("key\(i)", MusicLyricsTranslationCache.Entry(version: MusicLyricsTranslationCache.version, source: "en", target: "es", texts: ["x\(i)"]))
        }
        #expect(cache.memoryCount == 12)
        let again = MusicLyricsTranslationCache(directory: dir)
        #expect(again.get("key0", slotCount: 1)?.texts == ["x0"] && again.get("key0", slotCount: 2) == nil)
        cache.put("old", MusicLyricsTranslationCache.Entry(version: 2, source: "", target: "", texts: ["z"]))
        #expect(MusicLyricsTranslationCache(directory: dir).get("old", slotCount: 1) == nil)
    }

    @MainActor @Test func serviceTranslatesCachesAndReportsStates() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-translation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = MusicLyricsTranslationService(cacheDirectory: dir, translator: UpperTranslator())
        let spanish = MusicLyrics(synced: [MusicLyricLine(timeMs: 1000, text: "Hola amigo, como estas hoy"), MusicLyricLine(timeMs: 5000, text: "Me gusta mucho la musica")], providerID: "x")
        func settle() async { for _ in 0..<200 where s.translation == .loading || s.translation == .idle { try? await Task.sleep(nanoseconds: 20_000_000) } }
        s.requestTranslation(of: spanish, trackID: "t1", target: "en")
        await settle()
        #expect(s.translation.subLines?.lines.first??.text == "HOLA AMIGO, COMO ESTAS HOY")
        // The cached answer needs no translator.
        s.connect(nil)
        s.requestTranslation(of: spanish, trackID: "t1", target: "en")
        await settle()
        #expect(s.translation.subLines?.lines.count == 2)
        s.requestTranslation(of: spanish, trackID: "t2", target: "en")
        await settle()
        if case .unavailable = s.translation {} else { Issue.record("expected unavailable without a translator") }
        let english = MusicLyrics(synced: [MusicLyricLine(timeMs: 0, text: "This is a simple English sentence about love and life")], providerID: "x")
        s.requestTranslation(of: english, trackID: "t3", target: "en")
        await settle()
        #expect(s.translation == .unchanged)
        s.reset()
        #expect(s.translation == .idle && s.romanization == .idle)
    }

    @Test func romanisationIsLocalAndLatinLyricsReportUnchanged() {
        #expect(MusicLyricsTranslationService.romanize([MusicLyricLine(timeMs: 0, text: "Hello world")]) == .unchanged)
        let r = MusicLyricsTranslationService.romanize([MusicLyricLine(timeMs: 0, text: "안녕하세요")])
        #expect(r.subLines?.kind == .romanization && r.subLines?.lines.first??.text.isEmpty == false)
    }

    /// Romanising while a translation is still running must leave the translation alone (it used to cancel it and leave "Translating" on for good).
    @MainActor @Test func romanisingDuringATranslationDoesNotStrandIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-translation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = MusicLyricsTranslationService(cacheDirectory: dir, translator: UpperTranslator())
        let spanish = MusicLyrics(synced: [MusicLyricLine(timeMs: 1000, text: "Hola amigo, como estas hoy"), MusicLyricLine(timeMs: 5000, text: "Me gusta mucho la musica")], providerID: "x")
        s.requestTranslation(of: spanish, trackID: "t9", target: "en")
        #expect(s.translation == .loading)
        s.requestRomanization(of: spanish)
        for _ in 0..<200 where s.translation == .loading { try? await Task.sleep(nanoseconds: 20_000_000) }
        #expect(s.translation.subLines?.lines.count == 2)
    }
}

// MARK: - share card

@Suite struct LyricsShareCardTests {
    private func lines() -> [MusicLyricLine] {
        let long = String(repeating: "x", count: 100)
        return [MusicLyricLine(timeMs: 1000, text: long, endMs: 3000), MusicLyricLine(timeMs: 4000, text: long), MusicLyricLine(timeMs: 8000, text: long),
                MusicLyricLine(timeMs: 9000, text: ""), MusicLyricLine(timeMs: 10_000, text: "short")]
    }

    @Test func budgetAndToggling() {
        let l = lines()
        var picked = Set<Int>()
        #expect(MusicLyricsShareCard.toggle(0, in: &picked, lines: l) == .added && MusicLyricsShareCard.toggle(1, in: &picked, lines: l) == .added)
        #expect(MusicLyricsShareCard.toggle(2, in: &picked, lines: l) == .full && picked == [0, 1])
        #expect(MusicLyricsShareCard.toggle(3, in: &picked, lines: l) == .ignored && MusicLyricsShareCard.toggle(9, in: &picked, lines: l) == .ignored)
        #expect(MusicLyricsShareCard.toggle(1, in: &picked, lines: l) == .removed && picked == [0])
        #expect(MusicLyricsShareCard.build(lines: l, picked: [], title: "T", artist: "A") == nil)
    }

    @Test func gapsBecomeAnEllipsis() {
        let l = lines()
        let c = MusicLyricsShareCard.build(lines: l, picked: [0, 4], title: "T", artist: "A")
        #expect(c?.rows.map(\.isEllipsis) == [false, true, false] && c?.characterCount == 105)
        let adjacent = MusicLyricsShareCard.build(lines: l, picked: [2, 4], title: "T", artist: "A")
        #expect(adjacent?.rows.map(\.isEllipsis) == [false, false])
        let sub = MusicLyricsSubLines(kind: .translation, target: "es", source: "en", lines: [nil, nil, nil, nil, MusicLyricSubLine(text: "corto")])
        #expect(MusicLyricsShareCard.build(lines: l, picked: [4], title: "T", artist: "A", subLines: sub)?.rows.first?.sub == "corto")
    }

    @Test func videoSegmentsFollowNeighboursAndCaps() {
        let l = lines()
        let seg = MusicLyricsShareCard.videoSegments(lines: l, picked: [0, 1])
        #expect(seg[0].startMs == 1000 && seg[0].endMs == 4000)
        #expect(seg[1].startMs == 4000 && seg[1].endMs <= 4000 + 5000)
        let last = MusicLyricsShareCard.videoSegments(lines: l, picked: [4])
        #expect(last[0].endMs == 15_000)
        #expect(MusicLyricsShareCard.Measure.width == 1080 && MusicLyricsShareCard.characterBudget == 250)
    }
}

// MARK: - embedded lyrics

@Suite struct EmbeddedLyricsTests {
    private func sample() -> MusicLyrics {
        var hello = w("Hello ", 1000, 1600)
        hello.syllables = [MusicLyricSyllable(startMs: 1000, endMs: 1300, startChar: 0, endChar: 3), MusicLyricSyllable(startMs: 1300, endMs: 1600, startChar: 3, endChar: 5)]
        let l1 = MusicLyricLine(timeMs: 1000, text: "Hello world", endMs: 2000, words: [hello, w("world", 1600, 2000)], voice: "v1")
        let l2 = MusicLyricLine(timeMs: 3000, text: "plain line", voice: "v2")
        return MusicLyrics(synced: [l1, l2], sourceName: "S", providerID: "p")
    }

    @Test func stampsAndPortableForm() {
        #expect(MusicLRCText.stamp(61_234) == "01:01.23" && MusicLRCText.stamp(-5) == "00:00.00" && MusicLRCText.stamp(6_000_000) == "100:00.00")
        #expect(MusicLRCText.portable(sample()) == "[00:01.00]Hello world\n[00:03.00]plain line")
        #expect(MusicLRCText.portable(MusicLyrics(plain: "a\nb")) == "a\nb")
    }

    @Test func enhancedFieldRoundTripKeepsSyllablesAndDuetSide() throws {
        let text = try #require(MusicLRCText.enhanced(sample()))
        #expect(text.hasPrefix("[00:01.00]<00:01.00>Hel<00:01.30>lo <00:01.60>world <00:02.00>"))
        #expect(text.contains("[00:03.00]<R>plain line"))
        let back = try #require(MusicLRCText.parseEnhanced(text, source: "x", provider: "y"))
        let line = try #require(back.synced?.first)
        #expect(line.text == "Hello world" && line.words?.map(\.text) == ["Hello ", "world"] && line.words?[0].syllables?.count == 2)
        #expect(line.words?[0].syllables?[1].startMs == 1300 && line.words?[1].endMs == 2000)
        #expect(back.synced?.map(\.voice) == ["v1", "v2"])
        #expect(MusicLRCText.enhanced(MusicLyrics(synced: [MusicLyricLine(timeMs: 1, text: "a"), MusicLyricLine(timeMs: 2, text: "b")])) == nil)
    }

    @Test func backgroundWordsTravelAsBracketedTail() throws {
        let line = MusicLyricLine(timeMs: 1000, text: "Hello oh", endMs: 1500, words: [w("Hello ", 1000, 1500), w("oh", 1200, 1500, bg: true)])
        let text = try #require(MusicLRCText.enhanced(MusicLyrics(synced: [line])))
        #expect(text == "[00:01.00]<00:01.00>Hello <00:01.20>(oh)<00:01.50>")
        let back = try #require(MusicLRCText.parseEnhanced(text, source: "x", provider: "y"))
        #expect(back.synced?.first?.words?.map(\.background) == [false, true])
    }

    @Test func id3FramesRoundTripInBothVersions() throws {
        let lyrics = sample()
        for version in [3, 4] {
            // An existing tag with a title frame and an old lyric frame.
            let old = MusicID3LyricFrames.frame("TIT2", Data([0x00]) + Data("Title".utf8) + Data([0x00]), version: version)
                + MusicID3LyricFrames.frame("USLT", MusicID3LyricFrames.uslt("old text"), version: version)
            var existing = Data("ID3".utf8)
            existing.append(contentsOf: [UInt8(version), 0, 0]); existing.append(contentsOf: MusicID3LyricFrames.syncsafe(old.count)); existing.append(old)
            let tag = try #require(MusicID3LyricFrames.replacingLyrics(inTag: existing, with: lyrics))
            let parsed = try #require(MusicID3LyricFrames.frames(inTag: tag))
            #expect(parsed.version == version)
            #expect(parsed.frames.map(\.id) == ["TIT2", "USLT", "SYLT", "TXXX"])
            let enhanced = try #require(MusicID3LyricFrames.appText(inTag: tag))
            #expect(MusicLRCText.parseEnhanced(enhanced, source: "x", provider: "y")?.synced?.first?.words?[0].syllables?.count == 2)
            let read = try #require(ID3Lyrics.parse(header: tag.prefix(10), body: tag.dropFirst(10)))
            #expect(read.synced?.map(\.timeMs) == [1000, 3000] && read.synced?.first?.text == "Hello world")
            // Replacing again leaves exactly one set of lyric frames.
            let twice = try #require(MusicID3LyricFrames.replacingLyrics(inTag: tag, with: lyrics))
            #expect(MusicID3LyricFrames.frames(inTag: twice)?.frames.map(\.id) == ["TIT2", "USLT", "SYLT", "TXXX"])
        }
        #expect(MusicID3LyricFrames.replacingLyrics(inTag: Data("ID3".utf8) + Data([2, 0, 0, 0, 0, 0, 0]), with: lyrics) == nil)
    }

    @Test func mp3FileRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("embedded-lyrics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("song.mp3")
        // A tiny stand-in: an empty tag followed by MPEG-like bytes; only the container's start matters here.
        var data = Data("ID3".utf8); data.append(contentsOf: [3, 0, 0, 0, 0, 0, 0]); data.append(Data([0xFF, 0xFB, 0x90, 0x00] + Array(repeating: UInt8(0), count: 200)))
        try data.write(to: file)
        let wrote = await MusicEmbeddedLyrics.write(sample(), to: file)
        #expect(wrote == .written)
        let back = try #require(await MusicEmbeddedLyrics.read(file))
        #expect(back.synced?.first?.words?[0].syllables?.count == 2 && back.sourceName == MusicEmbeddedLyrics.sourceName)
        let audio = try Data(contentsOf: file)
        #expect(audio.suffix(204).prefix(4) == Data([0xFF, 0xFB, 0x90, 0x00]))
        #expect(MusicEmbeddedLyrics.writeSidecar(sample(), in: dir))
        #expect((try? String(contentsOf: dir.appendingPathComponent("lyrics.lrc"), encoding: .utf8))?.hasPrefix("[00:01.00]") == true)
    }
}
