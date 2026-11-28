import Testing
import Foundation
@testable import REDDY

private func line(_ t: Int64, _ text: String = "x", end: Int64? = nil, words: [MusicLyricWord]? = nil) -> MusicLyricLine {
    MusicLyricLine(timeMs: t, text: text, endMs: end, words: words)
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URLRequest] = []
    func add(_ r: URLRequest) { lock.lock(); items.append(r); lock.unlock() }
    var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return items }
}

private struct StubTransport: MusicHTTPTransport {
    let recorder: Recorder
    let answer: @Sendable (URLRequest) -> (Int, String)
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorder.add(request)
        let (code, body) = answer(request)
        let resp = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: code, httpVersion: nil, headerFields: nil) ?? HTTPURLResponse()
        return (Data(body.utf8), resp)
    }
}

@Suite("Lyrics motion and scroll math") struct LyricsMotionTests {
    @Test func curveEndsAndIsMonotonic() {
        #expect(MusicLyricsMotion.curve(0) == 0)
        #expect(MusicLyricsMotion.curve(1) == 1)
        var last = 0.0
        for i in 1...20 { let v = MusicLyricsMotion.curve(Double(i) / 20); #expect(v >= last); last = v }
        #expect(MusicLyricsMotion.curve(0.5) > 0.5)
    }

    @Test func alphaAndBlurFallOffWithDistance() {
        let alphas = MusicLyricsMotion.rowAlphas(count: 8, lit: [2], wide: false)
        #expect(alphas[2] == 1)
        #expect(alphas[3] == 0.8 && alphas[1] == 0.8)
        #expect(alphas[7] == 0.5)
        let wide = MusicLyricsMotion.rowAlphas(count: 8, lit: [0], wide: true)
        #expect(wide[1] == 0.84 && wide[7] == 0.58)
        let blurs = MusicLyricsMotion.rowBlurs(count: 8, lit: [0], enabled: true)
        #expect(blurs[0] == 0 && blurs[1] == 1 && blurs[3] == 1.7 && blurs[7] == 2.4)
        #expect(MusicLyricsMotion.rowBlurs(count: 3, lit: [0], enabled: false) == [0, 0, 0])
        #expect(MusicLyricsMotion.rowAlphas(count: 3, lit: [0], wide: false, browsing: true) == [0.8, 0.8, 0.8])
    }

    @Test func overlappingVocalsStayLit() {
        let lines = [line(0, "a", end: 5000), line(2000, "b", end: 4000), line(6000, "c")]
        #expect(MusicLyricsMotion.litRows(lines: lines, at: 3000) == [0, 1])
        #expect(MusicLyricsMotion.litRows(lines: lines, at: 4500) == [0, 1])
        #expect(MusicLyricsMotion.litRows(lines: lines, at: 5500) == [1])
        #expect(MusicLyricsMotion.litRows(lines: lines, at: -5).isEmpty)
    }

    @Test func scrollLeadIsClamped() {
        let lines = [line(0, "a", end: 1000), line(1100, "b", end: 2000), line(5000, "c", end: 6000)]
        #expect(MusicLyricsMotion.scrollLead(lines: lines, at: 500) == 350)
        #expect(MusicLyricsMotion.scrollLead(lines: lines, at: 1500) == 500)
        #expect(MusicLyricsMotion.scrollLead(lines: lines, at: 5500) == 350)
        let f = MusicLyricsMotion.focusRow(lines: lines, at: 800)
        #expect(f.index == 1 && f.leadMs == 350)
    }

    @Test func staggerAndTravel() {
        #expect(MusicLyricsMotion.rowDelay(rowsBehind: 0, duration: 0.4) == 0)
        #expect(abs(MusicLyricsMotion.rowDelay(rowsBehind: 2, duration: 0.5) - 0.06) < 1e-9)
        #expect(abs(MusicLyricsMotion.rowDelay(rowsBehind: 9, duration: 0.5) - 0.09) < 1e-9)
        let h: [Int: Double] = [0: 40, 1: 60]
        #expect(MusicLyricsMotion.travel(heights: h, spacing: 10, from: 0, to: 3, estimate: 50) == (40 + 10) + (60 + 10) + (50 + 10))
        #expect(MusicLyricsMotion.travel(heights: h, spacing: 10, from: 2, to: 0, estimate: 50) == -((40 + 10) + (60 + 10)))
        #expect(MusicLyricsMotion.travel(heights: h, spacing: 10, from: 1, to: 1, estimate: 50) == 0)
    }

    @Test func scrollOffsetPlacesRowAtAnchorAndClamps() {
        #expect(MusicLyricsMotion.scrollOffset(rowTop: 1000, rowHeight: 60, viewport: 500, content: 3000, anchor: 0.37) == 1000 + 30 - 185)
        #expect(MusicLyricsMotion.scrollOffset(rowTop: 10, rowHeight: 60, viewport: 500, content: 3000, anchor: 0.5) == 0)
        #expect(MusicLyricsMotion.scrollOffset(rowTop: 2990, rowHeight: 60, viewport: 500, content: 3000, anchor: 0.5) == 2500)
    }

    @Test func manualScrollPausesFollowingForThreeSeconds() {
        let t = Date()
        #expect(!MusicLyricsMotion.followResumes(lastManual: t, now: t.addingTimeInterval(2.9)))
        #expect(MusicLyricsMotion.followResumes(lastManual: t, now: t.addingTimeInterval(3)))
        #expect(MusicLyricsMotion.followResumes(lastManual: nil, now: t))
    }

    @Test func liftRisesAndSettles() {
        let w = MusicLyricWord(text: "hey ", startMs: 1000, endMs: 2000)
        #expect(MusicLyricsMotion.lift(w, at: 900) == 0)
        #expect(MusicLyricsMotion.lift(w, at: 1350) > 0.4)
        #expect(MusicLyricsMotion.lift(w, at: 2000 + 700) == 0)
        #expect(MusicLyricsMotion.heightFactor(holdMs: 100) == 0.25 && MusicLyricsMotion.heightFactor(holdMs: 1000) == 1)
    }

    @Test func heldWordQualification() {
        #expect(MusicLyricsMotion.qualifiesForSwell(text: "oh", holdMs: 1400))
        #expect(!MusicLyricsMotion.qualifiesForSwell(text: "oh", holdMs: 1200))
        #expect(MusicLyricsMotion.qualifiesForSwell(text: "love", holdMs: 1100))
        #expect(!MusicLyricsMotion.qualifiesForSwell(text: "forever and", holdMs: 5000))
        #expect(!MusicLyricsMotion.qualifiesForSwell(text: "well-known", holdMs: 5000))
        #expect(!MusicLyricsMotion.qualifiesForSwell(text: "愛", holdMs: 5000))
        #expect(MusicLyricsMotion.qualifiesForSwell(text: "dream", holdMs: 1000))
        #expect(!MusicLyricsMotion.qualifiesForSwell(text: "dream", holdMs: 950 - 100))
    }

    @Test func heldWordLetterTiming() {
        let peaks = MusicLyricsMotion.letterPeaks(length: 7, holdMs: 3000)
        #expect(peaks.count == 7)
        #expect(peaks[0].scale > peaks[6].scale)
        #expect(peaks.allSatisfy { $0.scale <= 1.14 && $0.scale > 1 })
        #expect(MusicLyricsMotion.letterStart(wordStartMs: 1000, index: 2, holdMs: 1000) == 1180)
        #expect(MusicLyricsMotion.letterMove(wordStartMs: 0, index: 0, holdMs: 1000, at: -10) == 0)
        #expect(MusicLyricsMotion.letterMove(wordStartMs: 0, index: 0, holdMs: 1000, at: 1500 * 275 / 1000) == 1)
        #expect(MusicLyricsMotion.letterMove(wordStartMs: 0, index: 0, holdMs: 1000, at: 1200) == 0)
        #expect(MusicLyricsMotion.swellRestsAt(wordStartMs: 0, length: 4, holdMs: 1000) == 1000 * (3 * 0.09 + 1.5))
    }

    @Test func interludeDots() {
        #expect(MusicLyricsMotion.dotFills(progress: 0) == [0.25, 0.25, 0.25])
        #expect(MusicLyricsMotion.dotFills(progress: 1) == [1, 1, 1])
        let mid = MusicLyricsMotion.dotFills(progress: 0.5)
        #expect(mid[0] == 1 && mid[2] == 0.25 && mid[1] > 0.25 && mid[1] < 1)
        let lines = [line(0, "a"), line(4000, ""), line(9000, "b")]
        let b = MusicLyricsMotion.interlude(lines: lines, index: 1, trackEndMs: nil)
        #expect(b?.start == 4000 && b?.end == 9000)
        #expect(MusicLyricsMotion.interlude(lines: lines, index: 0, trackEndMs: nil) == nil)
    }

    @Test func stripFade() {
        #expect(MusicLyricsMotion.stripAlpha(remainingMs: 5000, lineMs: 2000) == 0.78)
        #expect(MusicLyricsMotion.stripAlpha(remainingMs: 0, lineMs: 2000) == 0)
        #expect(MusicLyricsMotion.stripEnd(lines: [line(0), line(3000)], index: 1, durationMs: 10_000) == 10_000)
        #expect(MusicLyricsMotion.stripEnd(lines: [line(0), line(3000)], index: 1, durationMs: nil) == 7000)
    }

    @Test func offsetsAndSubLines() {
        #expect(MusicLyricsMotion.offsetLabel(1500) == "+1.5 s" && MusicLyricsMotion.offsetLabel(-200) == "-0.2 s" && MusicLyricsMotion.offsetLabel(0) == "0.0 s")
        #expect(MusicLyricsMotion.clampUIOffset(9000) == 5000)
        #expect(MusicLyricsMotion.lyricTime(position: 1000, songOffset: 300, globalOffset: 200) == 500)
        #expect(MusicLyricsMotion.lyricTime(position: 100, songOffset: 300, globalOffset: 0) == 0)
        #expect(MusicLyricsMotion.seekTime(lineMs: 1000, songOffset: 300, globalOffset: 0) == 1300)
        #expect(MusicLyricsMotion.showsSubLine("Hello", original: "hello") == false)
        #expect(MusicLyricsMotion.showsSubLine("Hola", original: "hello"))
        #expect(MusicLyricsMotion.showsSubLine("  ", original: "hello") == false)
    }

    @Test func wordSweepProgress() {
        let w = MusicLyricWord(text: "a ", startMs: 100, endMs: 300)
        #expect(MusicLyricsMotion.wordProgress(w, at: 50) == 0)
        #expect(MusicLyricsMotion.wordProgress(w, at: 200) == 0.5)
        #expect(MusicLyricsMotion.wordProgress(w, at: 400) == 1)
    }
}

@Suite("Lyrics UI wording and settings") struct LyricsWordingTests {
    @Test func sourceRowStatus() {
        #expect(MusicLyricsSourceRowState.status(.idle, enabled: false, current: false) == "Off · Check")
        #expect(MusicLyricsSourceRowState.status(.idle, enabled: true, current: false) == "Tap to check")
        #expect(MusicLyricsSourceRowState.status(.unreachable, enabled: true, current: false) == "Unreachable · Try again")
        #expect(MusicLyricsSourceRowState.status(.found(kind: .wordSynced, translated: false), enabled: true, current: false) == "Word by word")
        #expect(MusicLyricsSourceRowState.status(.notFound, enabled: true, current: true) == "Showing now")
    }

    @Test func contributionEntry() {
        let synced = MusicLyrics(synced: [line(0, "a", words: [MusicLyricWord(text: "a", startMs: 0, endMs: 10)])])
        #expect(MusicLyricsContribution.entryTitle(lyrics: synced, draft: nil) == "Improve these lyrics")
        #expect(MusicLyricsContribution.entryTitle(lyrics: MusicLyrics(plain: "a"), draft: nil) == "Sync these lyrics")
        let d = MusicLyricsDraft(videoID: "abcdefghijk", lines: [MusicLyricsDraftLine(id: 1, words: [MusicLyricsDraftWord(text: "a", startMs: 0, endMs: 5)]), MusicLyricsDraftLine(id: 2)], nextID: 3)
        #expect(MusicLyricsContribution.entryTitle(lyrics: nil, draft: d).contains("1 of 2"))
    }

    @Test func translationControlStates() {
        typealias L = MusicLyricsToolbarLogic
        #expect(L.translationControl(hasSourceTranslation: true, deviceAvailable: false, state: .idle, languageName: "French") == .sourceProvided)
        #expect(L.translationControl(hasSourceTranslation: false, deviceAvailable: true, state: .idle, languageName: "French") == .translateOnDevice)
        #expect(L.translationControl(hasSourceTranslation: false, deviceAvailable: false, state: .idle, languageName: "French") == .unavailable)
        #expect(L.translationControl(hasSourceTranslation: false, deviceAvailable: true, state: .loading, languageName: "French").title == "Translating to French...")
        #expect(L.nudged(4950, by: 100) == 5000)
    }

    @Test func settingsReorderAndSwitches() {
        #expect(MusicLyricsSettingsLogic.moved(["a", "b", "c"], from: 0, toOffset: 3) == ["b", "c", "a"])
        #expect(MusicLyricsSettingsLogic.moved(["a", "b", "c"], from: 2, toOffset: 0) == ["c", "a", "b"])
        #expect(MusicLyricsSettingsLogic.switched(["a": true], id: "a", on: false)["a"] == false)
        #expect(MusicLyricsSettingsLogic.note(for: "lrclib", info: nil).contains("LRCLIB"))
    }

    @MainActor @Test func plainRows() {
        let rows = MusicLyricsPlainView.rows("[Chorus]\nhello\n\nworld")
        #expect(rows == [.header("Chorus"), .line("hello"), .gap, .line("world")])
    }
}

@Suite("Lyric editor model") struct LyricEditorTests {
    private func draft(_ text: String) -> MusicLyricsDraft { MusicLyricsDraft.plainDraft(videoID: "abcdefghijk", text: text) }

    @Test func wordSplitting() {
        #expect(MusicLyricsWordSplit.split("hello big world") == ["hello ", "big ", "world"])
        #expect(MusicLyricsWordSplit.split("danc|ing now") == ["danc", "ing ", "now"])
        #expect(MusicLyricsWordSplit.split("").isEmpty)
    }

    @Test func typoKeepsTimingsDifferentCountClearsThem() {
        var d = draft("hello world")
        let id = d.lines[0].id
        d.lines[0].words[0].startMs = 100; d.lines[0].words[0].endMs = 200
        d.setText("hallo world", line: id)
        #expect(d.lines[0].words[0].startMs == 100)
        d.setText("hallo big world", line: id)
        #expect(d.lines[0].words.allSatisfy { $0.startMs == nil })
    }

    @Test func tapPassTimesWordsAndNeverGoesBackwards() {
        var d = draft("one two three")
        let id = d.lines[0].id
        guard var pass = d.startPass(line: id, background: false) else { Issue.record("no pass"); return }
        for ms: Int64 in [1000, 1500, 1400, 2400] { MusicLyricsDraft.register(tap: ms, in: &pass) }
        #expect(pass.taps == [1000, 1500, 1500, 2400])
        #expect(pass.isComplete)
        let hoisted231 = d.commit(pass, lineEndHintMs: nil); #expect(hoisted231)
        let w = d.lines[0].words
        #expect(w[0].startMs == 1000 && w[0].endMs == 1500)
        #expect(w[1].startMs == 1500 && w[1].endMs == 1530)
        #expect(w[2].startMs == 1500 && w[2].endMs == 2400)
        #expect(d.lines[0].startMs == 1000 && d.lines[0].done)
    }

    @Test func lastWordEndIsClamped() {
        var d = draft("a b")
        let id = d.lines[0].id
        var pass = d.startPass(line: id, background: false)!
        MusicLyricsDraft.register(tap: 1000, in: &pass); MusicLyricsDraft.register(tap: 2000, in: &pass)
        let hoisted244 = d.commit(pass, lineEndHintMs: 9000); #expect(hoisted244)
        #expect(d.lines[0].words[1].endMs == 4500)
        var d2 = draft("a b")
        var p2 = d2.startPass(line: d2.lines[0].id, background: false)!
        MusicLyricsDraft.register(tap: 1000, in: &p2); MusicLyricsDraft.register(tap: 2000, in: &p2)
        let hoisted249 = d2.commit(p2, lineEndHintMs: 2050); #expect(hoisted249)
        #expect(d2.lines[0].words[1].endMs == 2200)
    }

    @Test func halfPassNeverReplacesTimings() {
        var d = draft("a b c")
        let id = d.lines[0].id
        d.lines[0].words[0].startMs = 5; d.lines[0].words[0].endMs = 9
        var pass = d.startPass(line: id, background: false)!
        MusicLyricsDraft.register(tap: 100, in: &pass)
        let hoisted259 = d.commit(pass, lineEndHintMs: nil); #expect(!hoisted259)
        #expect(d.lines[0].words[0].startMs == 5)
    }

    @Test func backgroundWordsAreTimedInTheirOwnPass() {
        var d = draft("lead words back")
        let id = d.lines[0].id
        d.toggleBackground(line: id, word: 2)
        #expect(d.startPass(line: id, background: true)?.wordIndices == [2])
        #expect(d.startPass(line: id, background: false)?.wordIndices == [0, 1])
    }

    @Test func splitJoinDeleteAndBreaks() {
        var d = draft("one two\nthree")
        let a = d.lines[0].id
        d.split(line: a, atWord: 1)
        #expect(d.lines.count == 3 && d.lines[1].text == "two")
        d.joinWithNext(line: a)
        #expect(d.lines.count == 2 && d.lines[0].text == "one two")
        let b = d.addBreak(below: a)
        #expect(d.lines[1].id == b && d.lines[1].isBreak)
        d.delete(line: b)
        #expect(d.lines.count == 2)
        var one = draft("only")
        one.delete(line: one.lines[0].id)
        #expect(one.lines.count == 1)
    }

    @Test func edgeEditingRules() {
        var d = draft("a b")
        let id = d.lines[0].id
        d.lines[0].words[0].startMs = 1000; d.lines[0].words[0].endMs = 1500
        d.lines[0].words[1].startMs = 1500; d.lines[0].words[1].endMs = 2000
        d.setStart(1400, line: id, word: 1, songLengthMs: 10_000)
        #expect(d.lines[0].words[0].endMs == 1400)
        d.setStart(1990, line: id, word: 1, songLengthMs: 10_000)
        #expect(d.lines[0].words[1].startMs == 1970)
        d.setEnd(99_999, line: id, word: 1, songLengthMs: 10_000)
        #expect(d.lines[0].words[1].endMs == 10_000)
        d.setEnd(1000, line: id, word: 0, songLengthMs: 10_000)
        #expect(d.lines[0].words[0].endMs == 1030)
    }

    @Test func untouchedLinesGoOutAsLoadedEditedOnesAreRebuilt() {
        let words = [MusicLyricWord(text: "hi ", startMs: 1000, endMs: 1400), MusicLyricWord(text: "you", startMs: 1400, endMs: 2000)]
        var src = MusicLyricLine(timeMs: 1000, text: "hi you", endMs: 2000, words: words, voice: "v2", translation: "salut", romanized: "hi you")
        src.voice = "v2"
        var d = MusicLyricsDraft(videoID: "abcdefghijk", from: MusicLyrics(synced: [src, line(5000, "next")]))
        #expect(d.improving)
        var out = d.buildLines()
        #expect(out[0].translation == nil && out[0].voice == "v2" && out[0].words?.count == 2)
        d.setText("hi them", line: d.lines[0].id)
        d.setVoice("bad", line: d.lines[0].id)
        out = d.buildLines()
        #expect(out[0].text == "hi them" && out[0].romanized == nil && out[0].voice == "v2")
    }

    @Test func readinessGate() {
        var d = draft("a b")
        #expect(d.readiness != .ready)
        d.lines[0].words[0].startMs = 0; d.lines[0].words[0].endMs = 10
        d.lines[0].words[1].startMs = 10; d.lines[0].words[1].endMs = 20
        #expect(d.readiness == .ready)
        let long = MusicLyricsDraft.plainDraft(videoID: "abcdefghijk", text: String(repeating: "w ", count: 120))
        var l = long
        for k in l.lines[0].words.indices { l.lines[0].words[k].startMs = Int64(k); l.lines[0].words[k].endMs = Int64(k) + 1 }
        if case .blocked(let why) = l.readiness { #expect(why.contains("Line 1")) } else { Issue.record("should block") }
        #expect(MusicLyricsSubmissionBody.readiness(lines: []) == .blocked("Add at least one line of lyrics."))
    }

    @Test func tapTimeMath() {
        #expect(MusicLyricsTapMath.songTime(samplePositionSeconds: 10, sampleWall: 100.1, tapWall: 100.0, speed: 0.75, offsetMs: 0, paused: false) == 9925)
        #expect(MusicLyricsTapMath.songTime(samplePositionSeconds: 10, sampleWall: 100, tapWall: 100, speed: 1, offsetMs: -50, paused: false) == 9950)
        #expect(MusicLyricsTapMath.songTime(samplePositionSeconds: 10, sampleWall: 100, tapWall: 100, speed: 1, offsetMs: 0, paused: true) == nil)
        #expect(MusicLyricsTapMath.songTime(samplePositionSeconds: 0, sampleWall: 100, tapWall: 100, speed: 1, offsetMs: -50, paused: false) == 0)
        let r = MusicLyricsTapMath.loopRange(start: 5000, end: 8000, nextStart: 9000, songLengthMs: 8300)
        #expect(r == 3800...8300)
        #expect(MusicLyricsTapMath.loopRange(start: 500, end: nil, nextStart: nil, songLengthMs: 100_000) == 0...6100)
        #expect(MusicLyricsTapMath.clampTempo(0.77) == 0.75 && MusicLyricsTapMath.clampTempo(3) == 1 && MusicLyricsTapMath.clampTempo(0.1) == 0.5)
    }
}

@Suite("Lyric drafts and import") struct LyricDraftStoreTests {
    private func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("lyric-drafts-\(UUID().uuidString)", isDirectory: true) }

    @Test func draftRoundTripsAndOtherSongsAreIgnored() throws {
        let store = MusicLyricsDraftStore(directory: tempDir())
        var d = MusicLyricsDraft.plainDraft(videoID: "abcdefghijk", text: "one\ntwo")
        d.lines[0].words[0].startMs = 12; d.lines[0].words[0].endMs = 40
        try store.save(d)
        #expect(store.load(videoID: "abcdefghijk") == d)
        #expect(store.load(videoID: "zzzzzzzzzzz") == nil)
        store.delete(videoID: "abcdefghijk")
        #expect(store.load(videoID: "abcdefghijk") == nil)
    }

    @Test func corruptOrNewerVersionDraftIsIgnored() throws {
        let dir = tempDir()
        let store = MusicLyricsDraftStore(directory: dir)
        var d = MusicLyricsDraft.plainDraft(videoID: "abcdefghijk", text: "one")
        d.version = 99
        try store.save(d)
        #expect(store.load(videoID: "abcdefghijk") == nil)
        let file = dir.appendingPathComponent("lyrics_draft-abcdefghijk.json")
        try Data("{not json".utf8).write(to: file)
        #expect(store.load(videoID: "abcdefghijk") == nil)
    }

    @Test func importTextAndFileLimits() throws {
        let plain = try MusicLyricsImporter.draft(fromText: "one\n\n two \nthree", videoID: "abcdefghijk")
        #expect(plain.lines.map(\.text) == ["one", "two", "three"] && plain.doneCount == 0)
        let lrc = try MusicLyricsImporter.draft(fromText: "[00:01.00]first line\n[00:05.50]second line", videoID: "abcdefghijk")
        #expect(lrc.lines.count == 2 && lrc.lines[1].startMs == 5500)
        #expect(throws: MusicLyricsImportError.empty) { try MusicLyricsImporter.draft(fromText: "   ", videoID: "abcdefghijk") }
        let big = tempDir()
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        let f = big.appendingPathComponent("big.txt")
        try Data(repeating: 0x61, count: MusicLyricsImporter.maxBytes + 1).write(to: f)
        #expect(throws: MusicLyricsImportError.tooLarge) { try MusicLyricsImporter.draft(fromFile: f, videoID: "abcdefghijk") }
    }
}

@Suite("Lyrics submission") struct LyricsSubmissionTests {
    private func json(_ d: Data?) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: d ?? Data())) as? [String: Any]) ?? [:] }

    @Test func revisionBodyShape() {
        let l = MusicLyricLine(timeMs: 1000, text: "hi you", endMs: 2000,
                               words: [MusicLyricWord(text: "hi ", startMs: 1000, endMs: 1400), MusicLyricWord(text: "(oh)", startMs: 1500, endMs: 1900, background: true)],
                               voice: "v2", translation: "salut")
        let body = json(MusicLyricsSubmissionBody.revisionBody(lines: [l, MusicLyricLine(timeMs: 4000, text: "", words: [])], title: " Song ", artist: "Band", album: "", durationSeconds: 215, baseRevision: nil))
        #expect(body["title"] as? String == "Song" && body["artist"] as? String == "Band")
        #expect(body["album"] == nil && body["duration"] as? Int == 215)
        #expect(body["base_revision"] is NSNull)
        let lines = body["lines"] as? [[String: Any]] ?? []
        #expect(lines.count == 2)
        #expect(lines[0]["time_ms"] as? Int == 1000 && lines[0]["end_time_ms"] as? Int == 2000 && lines[0]["agent"] as? String == "v2")
        #expect(lines[0]["translation"] == nil)
        let words = lines[0]["words"] as? [[String: Any]] ?? []
        #expect(words[1]["bg"] as? Bool == true && words[0]["bg"] == nil && words[0]["start_ms"] as? Int == 1000)
        #expect((lines[1]["words"] as? [Any])?.isEmpty == true && lines[1]["text"] as? String == "")
        let again = json(MusicLyricsSubmissionBody.revisionBody(lines: [l], title: "t", artist: "a", album: "Alb", durationSeconds: nil, baseRevision: 7))
        #expect(again["base_revision"] as? Int == 7 && again["album"] as? String == "Alb" && again["duration"] == nil)
    }

    @Test func voteReportAndIds() {
        #expect(json(MusicLyricsSubmissionBody.voteBody(-1))["value"] as? Int == -1)
        #expect(json(MusicLyricsSubmissionBody.voteBody(5))["value"] as? Int == 1)
        let r = json(MusicLyricsSubmissionBody.reportBody(reason: .wrongSong, note: String(repeating: "é", count: 400)))
        #expect(r["reason"] as? String == "wrong_song")
        #expect((r["note"] as? String)?.utf8.count == 300)
        #expect(json(MusicLyricsSubmissionBody.reportBody(reason: .timing, note: "  "))["note"] == nil)
        #expect(MusicLyricsSubmissionBody.isValidFiledID("abcDEF_-123"))
        #expect(!MusicLyricsSubmissionBody.isValidFiledID("short") && !MusicLyricsSubmissionBody.isValidFiledID("abc/../1234"))
    }

    @Test func errorMapping() {
        func e(_ s: Int, _ b: String) -> MusicLyricsSubmissionError { .map(status: s, body: Data(b.utf8)) }
        #expect(e(401, "") == .unauthorized)
        #expect(e(429, "") == .rateLimited)
        #expect(e(409, #"{"error":"stale"}"#) == .stale)
        #expect(e(409, #"{"error":"unchanged","detail":"lrclib"}"#) == .unchanged("lrclib"))
        #expect(e(400, #"{"error":"invalid","detail":"too long"}"#) == .invalid("too long"))
        #expect(e(403, #"{"error":"banned"}"#) == .banned)
        #expect(e(500, #"{"error":"boom"}"#) == .unavailable)
        #expect(e(400, "") == .unavailable)
        #expect(MusicLyricsSubmissionError.unchanged("lrclib").message == "LRCLIB already has these lyrics word by word.")
    }

    @Test func firstSubmitMakesOneAnonymousAccountAndStoresTheToken() async throws {
        let rec = Recorder()
        let store = MusicLyricsMemoryStore()
        let stub = StubTransport(recorder: rec) { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/anonymous") { return (200, #"{"token":"tok-1"}"#) }
            if path.hasSuffix("/revisions") { return (201, #"{"revision":12,"status":"pending"}"#) }
            return (404, "")
        }
        let client = MusicLyricsSubmissionClient(transport: stub, store: store, base: URL(string: "https://lyrics.invalid")!, userAgent: "test")
        let line = MusicLyricLine(timeMs: 0, text: "a", words: [MusicLyricWord(text: "a", startMs: 0, endMs: 10)])
        let receipt = try await client.submit(filedID: "abcdefghijk", lines: [line], title: "T", artist: "A", album: nil, durationSeconds: 100, baseRevision: nil)
        #expect(receipt == MusicLyricsReceipt(revision: 12, status: .pending))
        #expect(store.load() == MusicLyricsSession(token: "tok-1", anonymous: true))
        let reqs = rec.all
        #expect(reqs.map { $0.url?.path ?? "" } == ["/v1/auth/anonymous", "/v1/lyrics/abcdefghijk/revisions"])
        #expect(reqs[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(reqs[1].value(forHTTPHeaderField: "Authorization") == "Bearer tok-1")
        _ = try await client.submit(filedID: "abcdefghijk", lines: [line], title: "T", artist: "A", album: nil, durationSeconds: nil, baseRevision: 12)
        #expect(rec.all.filter { $0.url?.path == "/v1/auth/anonymous" }.count == 1)
    }

    @Test func anonymousSessionRefusedOnceGetsOneFreshAccount() async throws {
        let rec = Recorder()
        let store = MusicLyricsMemoryStore(MusicLyricsSession(token: "old", anonymous: true))
        let stub = StubTransport(recorder: rec) { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/anonymous") { return (200, #"{"token":"new"}"#) }
            if req.value(forHTTPHeaderField: "Authorization") == "Bearer old" { return (401, "") }
            return (200, #"{"up":3,"down":1,"my_vote":1}"#)
        }
        let client = MusicLyricsSubmissionClient(transport: stub, store: store, base: URL(string: "https://lyrics.invalid")!, userAgent: "test")
        let r = try await client.vote(filedID: "abcdefghijk", value: 1)
        #expect(r.up == 3 && r.down == 1 && r.mine == 1)
        #expect(store.load()?.token == "new")
    }

    @Test func staleAnswerIsReportedAndNothingElseIsSent() async {
        let stub = StubTransport(recorder: Recorder()) { req in
            (req.url?.path ?? "").hasSuffix("/auth/anonymous") ? (200, #"{"token":"t"}"#) : (409, #"{"error":"stale"}"#)
        }
        let client = MusicLyricsSubmissionClient(transport: stub, store: MusicLyricsMemoryStore(), base: URL(string: "https://lyrics.invalid")!, userAgent: "test")
        do {
            _ = try await client.submit(filedID: "abcdefghijk", lines: [], title: "T", artist: "A", album: nil, durationSeconds: nil, baseRevision: 1)
            Issue.record("should throw")
        } catch { #expect((error as? MusicLyricsSubmissionError) == .stale) }
    }

    @Test func liveStateParsing() {
        let s = MusicLyricsSubmissionClient.parseState(Data(#"{"revision":4,"origin":"community","authors":["a"],"votes":{"up":5,"down":2},"my_vote":-1,"my_pending":true,"my_rejected":{"revision":3,"reason":"timing","at":"x"}}"#.utf8))
        #expect(s.revision == 4 && s.up == 5 && s.down == 2 && s.myVote == -1 && s.myPending && s.rejectedReason == "timing" && s.rejectedRevision == 3)
    }

    @Test func providersAvailabilityNeedsAnonymousFlag() async {
        let yes = StubTransport(recorder: Recorder()) { _ in (200, #"{"providers":["github"],"anonymous":true}"#) }
        let no = StubTransport(recorder: Recorder()) { _ in (200, #"{"providers":[],"anonymous":false}"#) }
        let base = URL(string: "https://lyrics.invalid")!
        #expect(await MusicLyricsSubmissionClient(transport: yes, store: MusicLyricsMemoryStore(), base: base, userAgent: "t").supportsAnonymous())
        #expect(await !MusicLyricsSubmissionClient(transport: no, store: MusicLyricsMemoryStore(), base: base, userAgent: "t").supportsAnonymous())
    }
}
