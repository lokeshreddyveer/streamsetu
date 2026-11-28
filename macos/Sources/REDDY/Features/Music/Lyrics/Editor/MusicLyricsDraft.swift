import Foundation
import NaturalLanguage

// The pure side of the lyric editor: the draft (lines, words, timings), every editing operation, the tap-to-time pass, and the conversion
// back to lyric lines for sending. No view code and no clock, so every rule runs in tests with plain values.

struct MusicLyricsDraftWord: Codable, Hashable, Sendable {
    /// Includes the trailing space when a space followed the word.
    var text: String
    var startMs: Int64?
    var endMs: Int64?
    var background = false
    var timed: Bool { startMs != nil && endMs != nil }
}

struct MusicLyricsDraftLine: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    var words: [MusicLyricsDraftWord] = []
    /// The line's own start. A break has only this.
    var startMs: Int64?
    var voice: String?
    var isBreak = false
    /// The line as loaded; kept while the line is left alone so it goes out exactly as it came.
    var original: MusicLyricLine?
    var romanized: String?
    /// The text the reading belongs to; the reading is dropped once the text changes.
    var romanizedSource: String?

    var text: String { words.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
    var timedWordCount: Int { words.filter(\.timed).count }
    var allWordsTimed: Bool { !words.isEmpty && words.allSatisfy(\.timed) }
    var needsStart: Bool { !isBreak && startMs == nil && !allWordsTimed }
    var done: Bool { isBreak ? startMs != nil : allWordsTimed }
    var firstStart: Int64? { words.compactMap(\.startMs).min() ?? startMs }
    var lastEnd: Int64? { words.compactMap(\.endMs).max() }
    func indices(background bg: Bool) -> [Int] { words.indices.filter { words[$0].background == bg } }
    var hasBackground: Bool { words.contains(where: \.background) }
}

struct MusicLyricsDraft: Codable, Hashable, Sendable {
    static let version = 1
    var version = MusicLyricsDraft.version
    var videoID: String
    var lines: [MusicLyricsDraftLine] = []
    var nextID = 1
    var baseRevision: Int?
    /// The starting lyric was already word-timed: the work is "improve", not "sync".
    var improving = false

    var doneCount: Int { lines.filter(\.done).count }
    var total: Int { lines.count }
    var allDone: Bool { !lines.isEmpty && lines.allSatisfy(\.done) }
    var nextToDo: Int? { lines.firstIndex { !$0.done } }
    var progressText: String { "\(doneCount) of \(total) lines timed" }
    func index(of id: Int) -> Int? { lines.firstIndex { $0.id == id } }

    mutating func newID() -> Int { defer { nextID += 1 }; return nextID }
}

// MARK: - words

enum MusicLyricsWordSplit {
    /// Words of a line of text. A space ends a word and stays on it; `|` splits a word into parts tapped separately without adding a space.
    /// Scripts written without spaces are segmented with the system word breaker, one word per character if it gives nothing.
    static func split(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        func flushPart() { if !current.isEmpty { out.append(current); current = "" } }
        for ch in text {
            if ch == "|" { flushPart(); continue }
            if ch == " " || ch == "\t" {
                if current.isEmpty, let last = out.last, !last.hasSuffix(" ") { out[out.count - 1] = last + " " } else if !current.isEmpty { out.append(current + " "); current = "" }
                continue
            }
            current.append(ch)
        }
        flushPart()
        return out.flatMap { unspaced($0) }
    }

    static func isUnspacedScript(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) || (0x0E00...0x0EFF).contains($0.value)
            || (0x0E80...0x0EFF).contains($0.value) || (0x1000...0x109F).contains($0.value) || (0x1780...0x17FF).contains($0.value) }
    }

    private static func unspaced(_ word: String) -> [String] {
        let core = word.trimmingCharacters(in: .whitespaces)
        guard core.contains(where: isUnspacedScript), core.count > 1 else { return [word] }
        let trailing = word.hasSuffix(" ")
        var parts: [String] = []
        let t = NLTokenizer(unit: .word)
        t.string = core
        t.enumerateTokens(in: core.startIndex..<core.endIndex) { r, _ in parts.append(String(core[r])); return true }
        if parts.count <= 1 || parts.joined().count != core.count { parts = core.map(String.init) }
        // Punctuation stays with the previous word.
        var merged: [String] = []
        for p in parts {
            if let last = merged.last, p.allSatisfy({ $0.isPunctuation || $0.isSymbol }) { merged[merged.count - 1] = last + p } else { merged.append(p) }
        }
        if trailing, let last = merged.last { merged[merged.count - 1] = last + " " }
        return merged
    }

    static func words(_ text: String) -> [MusicLyricsDraftWord] { split(text).map { MusicLyricsDraftWord(text: $0) } }
}

// MARK: - building a draft

extension MusicLyricsDraft {
    /// A draft from lyrics that are already on screen. Word-timed lines keep their words; line-timed ones get untimed words; plain text has no stamps.
    init(videoID: String, from lyrics: MusicLyrics, baseRevision: Int? = nil) {
        self.init(videoID: videoID)
        self.baseRevision = baseRevision
        improving = lyrics.isWordTimed
        if let synced = lyrics.synced, !synced.isEmpty {
            for l in synced { lines.append(Self.line(from: l, id: newID())) }
        } else if let plain = lyrics.plain {
            self = Self.plainDraft(videoID: videoID, text: plain, baseRevision: baseRevision)
        }
    }

    private static func line(from l: MusicLyricLine, id: Int) -> MusicLyricsDraftLine {
        if l.text.trimmingCharacters(in: .whitespaces).isEmpty && (l.words ?? []).isEmpty {
            return MusicLyricsDraftLine(id: id, startMs: l.timeMs, isBreak: true, original: l)
        }
        var d = MusicLyricsDraftLine(id: id, startMs: l.timeMs, voice: l.voice, original: l, romanized: l.romanized, romanizedSource: l.text)
        if let words = l.words, !words.isEmpty {
            d.words = words.map { MusicLyricsDraftWord(text: $0.text, startMs: $0.startMs, endMs: $0.endMs, background: $0.background) }
        } else {
            d.words = MusicLyricsWordSplit.words(l.text)
        }
        return d
    }

    /// One line per input line, blanks dropped, nothing timed.
    static func plainDraft(videoID: String, text: String, baseRevision: Int? = nil) -> MusicLyricsDraft {
        var d = MusicLyricsDraft(videoID: videoID)
        d.baseRevision = baseRevision
        for raw in text.split(whereSeparator: \.isNewline) {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            d.lines.append(MusicLyricsDraftLine(id: d.newID(), words: MusicLyricsWordSplit.words(s)))
        }
        return d
    }

    /// "{n} lines, already word by word. Fix the ones that are off." and its two siblings.
    static func startingText(for lyrics: MusicLyrics) -> String {
        let n = lyrics.synced?.count ?? (lyrics.plain?.split(whereSeparator: \.isNewline).count ?? 0)
        if lyrics.isWordTimed { return "\(n) lines, already word by word. Fix the ones that are off." }
        if lyrics.isSynced { return "\(n) lines, timed line by line. You only tap the words." }
        return "\(n) lines of text. You tap where each line starts, then its words."
    }
}

enum MusicLyricsImportError: Error, Equatable, Sendable {
    case tooLarge, unreadable, empty
    var message: String {
        switch self { case .tooLarge: "That file is too large (the limit is 1 MiB)."; case .unreadable: "That file could not be read as text."; case .empty: "There are no lyrics in that text." }
    }
}

enum MusicLyricsImporter {
    static let maxBytes = 1_048_576

    /// Pasted text goes through the same parsers as the sources (LRC, enhanced LRC, TTML, JSON); text with no stamps becomes plain lines.
    static func draft(fromText text: String, videoID: String, baseRevision: Int? = nil) throws -> MusicLyricsDraft {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MusicLyricsImportError.empty }
        if let parsed = MusicLyricsParsers.lyrics(from: trimmed, source: "Imported", provider: MusicLyricsSources.localOwn), parsed.isSynced {
            return MusicLyricsDraft(videoID: videoID, from: parsed, baseRevision: baseRevision)
        }
        let d = MusicLyricsDraft.plainDraft(videoID: videoID, text: trimmed, baseRevision: baseRevision)
        guard !d.lines.isEmpty else { throw MusicLyricsImportError.empty }
        return d
    }

    static func draft(fromFile url: URL, videoID: String, baseRevision: Int? = nil) throws -> MusicLyricsDraft {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maxBytes else { throw MusicLyricsImportError.tooLarge }
        guard let data = try? Data(contentsOf: url), data.count <= maxBytes else { throw MusicLyricsImportError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw MusicLyricsImportError.unreadable }
        return try draft(fromText: text, videoID: videoID, baseRevision: baseRevision)
    }
}

// MARK: - editing

extension MusicLyricsDraft {
    /// A typo fix keeps every timing; a different word count leaves the words untimed to be tapped again.
    mutating func setText(_ text: String, line id: Int) {
        guard let i = index(of: id) else { return }
        let fresh = MusicLyricsWordSplit.words(text)
        var l = lines[i]
        if fresh.count == l.words.count {
            for k in fresh.indices { l.words[k].text = fresh[k].text }
        } else {
            l.words = fresh
        }
        l.original = nil
        lines[i] = l
    }

    /// Splits at a word boundary (`wordIndex` words stay): timings are kept.
    mutating func split(line id: Int, atWord wordIndex: Int) {
        guard let i = index(of: id), wordIndex > 0, wordIndex < lines[i].words.count else { return }
        var a = lines[i], b = a
        a.words = Array(lines[i].words[..<wordIndex]); b.words = Array(lines[i].words[wordIndex...])
        a.original = nil; b.original = nil
        b.id = newID(); b.startMs = b.words.compactMap(\.startMs).min()
        a.startMs = a.words.compactMap(\.startMs).min() ?? a.startMs
        lines[i] = a
        lines.insert(b, at: i + 1)
    }

    /// Splits inside a word: two new untimed words.
    mutating func split(line id: Int, word wordIndex: Int, atCharacter offset: Int) {
        guard let i = index(of: id), lines[i].words.indices.contains(wordIndex) else { return }
        let w = lines[i].words[wordIndex]
        let chars = Array(w.text)
        guard offset > 0, offset < chars.count else { return }
        let a = MusicLyricsDraftWord(text: String(chars[..<offset]), background: w.background)
        let b = MusicLyricsDraftWord(text: String(chars[offset...]), background: w.background)
        lines[i].words.replaceSubrange(wordIndex...wordIndex, with: [a, b])
        lines[i].original = nil
    }

    /// Joins the line with the next one; timings are kept.
    mutating func joinWithNext(line id: Int) {
        guard let i = index(of: id), i + 1 < lines.count, !lines[i].isBreak, !lines[i + 1].isBreak else { return }
        var a = lines[i]
        if var last = a.words.last, !last.text.hasSuffix(" ") { last.text += " "; a.words[a.words.count - 1] = last }
        a.words += lines[i + 1].words
        a.original = nil
        lines[i] = a
        lines.remove(at: i + 1)
    }

    @discardableResult
    mutating func addLine(below id: Int?, text: String = "") -> Int {
        let new = MusicLyricsDraftLine(id: newID(), words: MusicLyricsWordSplit.words(text))
        if let id, let i = index(of: id) { lines.insert(new, at: i + 1) } else { lines.append(new) }
        return new.id
    }

    /// A break waits for a tap; added after a line it starts where that line's singing ends, if that is known.
    @discardableResult
    mutating func addBreak(below id: Int?) -> Int {
        var b = MusicLyricsDraftLine(id: newID(), isBreak: true)
        if let id, let i = index(of: id) { b.startMs = lines[i].lastEnd; lines.insert(b, at: i + 1) } else { lines.append(b) }
        return b.id
    }

    mutating func delete(line id: Int) {
        guard lines.count > 1, let i = index(of: id) else { return }
        lines.remove(at: i)
    }

    mutating func resplit(line id: Int) { setText(lines[safe: index(of: id)]?.words.map(\.text).joined() ?? "", line: id) }

    mutating func setVoice(_ voice: String?, line id: Int) {
        guard let i = index(of: id) else { return }
        if let v = voice, !MusicLyricsVoices.isValidAgent(v) { return }
        lines[i].voice = voice
        lines[i].original = nil
    }

    mutating func toggleBackground(line id: Int, word: Int) {
        guard let i = index(of: id), lines[i].words.indices.contains(word) else { return }
        lines[i].words[word].background.toggle()
        lines[i].original = nil
    }

    mutating func clearTimings(line id: Int) {
        guard let i = index(of: id) else { return }
        for k in lines[i].words.indices { lines[i].words[k].startMs = nil; lines[i].words[k].endMs = nil }
        lines[i].startMs = nil; lines[i].original = nil
    }

    // MARK: timing edges

    static let minWordMs: Int64 = 30

    /// Moves a word's start. Words keep their order and never overlap within a voice; the previous word's end follows when they touched or would overlap.
    mutating func setStart(_ ms: Int64, line id: Int, word: Int, songLengthMs: Int64?) {
        guard let i = index(of: id), lines[i].words.indices.contains(word), let end = lines[i].words[word].endMs else { return }
        let voice = lines[i].words[word].background
        let peers = lines[i].indices(background: voice)
        guard let pos = peers.firstIndex(of: word) else { return }
        var lo: Int64 = 0
        if pos > 0, let prevStart = lines[i].words[peers[pos - 1]].startMs { lo = prevStart + Self.minWordMs }
        let value = max(lo, min(ms, end - Self.minWordMs))
        if pos > 0, let prevEnd = lines[i].words[peers[pos - 1]].endMs {
            let oldStart = lines[i].words[word].startMs ?? value
            if prevEnd >= oldStart || prevEnd > value { lines[i].words[peers[pos - 1]].endMs = value }
        }
        lines[i].words[word].startMs = value
        lines[i].original = nil
        refreshStart(i)
    }

    /// Moves a word's end. It only opens or closes a gap, bounded by the next word's start; the last word is free up to the song length.
    mutating func setEnd(_ ms: Int64, line id: Int, word: Int, songLengthMs: Int64?) {
        guard let i = index(of: id), lines[i].words.indices.contains(word), let start = lines[i].words[word].startMs else { return }
        let voice = lines[i].words[word].background
        let peers = lines[i].indices(background: voice)
        guard let pos = peers.firstIndex(of: word) else { return }
        var hi = songLengthMs ?? Int64.max
        if pos + 1 < peers.count, let next = lines[i].words[peers[pos + 1]].startMs { hi = next }
        lines[i].words[word].endMs = max(start + Self.minWordMs, min(ms, hi))
        lines[i].original = nil
    }

    private mutating func refreshStart(_ i: Int) {
        if let s = lines[i].words.compactMap(\.startMs).min() { lines[i].startMs = s }
    }
}

private extension Array {
    subscript(safe i: Int?) -> Element? { guard let i, indices.contains(i) else { return nil }; return self[i] }
}

// MARK: - tapping

enum MusicLyricsTapMath {
    /// Song time of a tap: the position sampled from the player, moved back by how long ago the sample was read (at the playback speed), plus the
    /// person's tap offset (in song time). A paused song stamps nothing.
    static func songTime(samplePositionSeconds: Double, sampleWall: Double, tapWall: Double, speed: Double, offsetMs: Double, paused: Bool) -> Int64? {
        guard !paused else { return nil }
        let t = samplePositionSeconds * 1000 - (sampleWall - tapWall) * speed * 1000 + offsetMs * speed
        return max(0, Int64(t.rounded()))
    }

    /// The loop for a line: from 1.2 s before its start to 0.6 s after its end, inside the song. A line with no end ends at the next line's start (at most
    /// 15 s on), or 5 s on if it is the last.
    static func loopRange(start: Int64, end: Int64?, nextStart: Int64?, songLengthMs: Int64) -> ClosedRange<Int64> {
        let lineEnd = end ?? nextStart.map { min($0, start + 15_000) } ?? start + 5000
        let lo = max(0, start - 1200)
        let hi = min(songLengthMs > 0 ? songLengthMs : Int64.max, lineEnd + 600)
        return lo...max(lo, hi)
    }

    static let defaultTempo = 0.75
    static let tempoRange: ClosedRange<Double> = 0.5...1.0
    static func clampTempo(_ t: Double) -> Double { (min(1, max(0.5, t)) * 20).rounded() / 20 }
    static func clampTapOffset(_ ms: Double) -> Double { min(500, max(-500, ms)) }
}

struct MusicLyricsTapPass: Equatable, Sendable {
    var lineID: Int
    var background: Bool
    /// Indices into the line's words, in order, for the voice being timed.
    var wordIndices: [Int]
    var taps: [Int64] = []

    var expected: Int { wordIndices.count }
    /// One more tap than words: the extra one ends the last word.
    var isComplete: Bool { taps.count >= expected + 1 }
    var nextWord: Int? { taps.count < expected ? wordIndices[taps.count] : nil }
}

extension MusicLyricsDraft {
    func startPass(line id: Int, background: Bool) -> MusicLyricsTapPass? {
        guard let i = index(of: id), !lines[i].isBreak else { return nil }
        let idx = lines[i].indices(background: background)
        return idx.isEmpty ? nil : MusicLyricsTapPass(lineID: id, background: background, wordIndices: idx)
    }

    /// Tap times never go backwards.
    static func register(tap ms: Int64, in pass: inout MusicLyricsTapPass) {
        guard !pass.isComplete else { return }
        pass.taps.append(max(ms, pass.taps.last ?? 0))
    }

    /// Applies a finished pass. A pass that stopped halfway never replaces the line's timings (returns false). The last word, with no closing tap, ends at the
    /// line's end but no sooner than 200 ms and no later than 2500 ms after its start.
    @discardableResult
    mutating func commit(_ pass: MusicLyricsTapPass, lineEndHintMs: Int64?) -> Bool {
        guard let i = index(of: pass.lineID), pass.taps.count >= pass.expected, pass.expected > 0 else { return false }
        for (k, wi) in pass.wordIndices.enumerated() {
            let start = pass.taps[k]
            let end: Int64
            if k + 1 < pass.taps.count { end = max(start + Self.minWordMs, pass.taps[k + 1]) }
            else {
                let want = lineEndHintMs ?? (start + 800)
                end = start + min(2500, max(200, want - start))
            }
            lines[i].words[wi].startMs = start
            lines[i].words[wi].endMs = end
        }
        lines[i].original = nil
        if let s = lines[i].words.compactMap(\.startMs).min() { lines[i].startMs = s }
        return true
    }

    mutating func setLineStart(_ ms: Int64, line id: Int) {
        guard let i = index(of: id) else { return }
        lines[i].startMs = ms
        if !lines[i].isBreak { lines[i].original = nil }
    }
}

// MARK: - sending

extension MusicLyricsDraft {
    var untimedWordCount: Int { lines.filter { !$0.isBreak }.reduce(0) { $0 + $1.words.filter { !$0.timed }.count } }
    var untimedBreakCount: Int { lines.filter { $0.isBreak && $0.startMs == nil }.count }

    var readiness: MusicLyricsSubmissionBody.Readiness {
        MusicLyricsSubmissionBody.readiness(lines: buildLines(), untimedWords: untimedWordCount, untimedBreaks: untimedBreakCount)
    }

    /// Lines as they are sent. Untouched lines go out exactly as loaded; edited ones are rebuilt (whole milliseconds, starts never going backwards
    /// within a voice, line time at or before its first word). Empty lines are dropped and the result is sorted by start, stably.
    func buildLines() -> [MusicLyricLine] {
        var out: [(Int64, Int, MusicLyricLine)] = []
        for (n, l) in lines.enumerated() {
            if let o = l.original, l.startMs == o.timeMs { out.append((o.timeMs, n, Self.canonical(o))); continue }
            if l.isBreak {
                guard let s = l.startMs else { continue }
                out.append((s, n, MusicLyricLine(timeMs: s, text: "", words: [])))
                continue
            }
            guard !l.words.isEmpty, !l.text.isEmpty else { continue }
            var words: [MusicLyricWord] = []
            for bg in [false, true] {
                var prevStart: Int64 = 0
                for wi in l.indices(background: bg) {
                    let w = l.words[wi]
                    guard let s0 = w.startMs else { continue }
                    let s = max(prevStart, s0)
                    let e = max(s, w.endMs ?? s)
                    words.append(MusicLyricWord(text: w.text, startMs: s, endMs: e, background: bg))
                    prevStart = s
                }
            }
            words.sort { $0.startMs < $1.startMs }
            let firstWord = words.map(\.startMs).min()
            let time = min(l.startMs ?? firstWord ?? 0, firstWord ?? Int64.max)
            let end = max(words.map(\.endMs).max() ?? time, time)
            var line = MusicLyricLine(timeMs: time, text: l.text, endMs: end, words: words)
            if let v = l.voice, MusicLyricsVoices.isValidAgent(v) { line.voice = v }
            if let r = l.romanized, !r.isEmpty, let src = l.romanizedSource, MusicLyricsText.collapsed(src) == MusicLyricsText.collapsed(l.text) { line.romanized = r }
            out.append((time, n, line))
        }
        return out.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map(\.2)
    }

    /// Canonical form of a line left as loaded: text, words, time, end, a valid agent and readings; translations are dropped.
    static func canonical(_ l: MusicLyricLine) -> MusicLyricLine {
        var c = l
        c.translation = nil
        if let v = c.voice, !MusicLyricsVoices.isValidAgent(v) { c.voice = nil }
        return c
    }
}

// MARK: - drafts on disk

struct MusicLyricsDraftStore: Sendable {
    let directory: URL

    static func defaultDirectory() -> URL { MusicStorage.subfolder("LyricDrafts") }

    private func url(_ videoID: String) -> URL {
        let safe = videoID.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        return directory.appendingPathComponent("lyrics_draft-\(String(String.UnicodeScalarView(safe))).json")
    }

    func save(_ d: MusicLyricsDraft) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(d).write(to: url(d.videoID), options: .atomic)
    }

    /// A draft for this song, or nil when there is none, it is unreadable, of another version or of another song.
    func load(videoID: String) -> MusicLyricsDraft? {
        guard let data = try? Data(contentsOf: url(videoID)), let d = try? JSONDecoder().decode(MusicLyricsDraft.self, from: data),
              d.version == MusicLyricsDraft.version, d.videoID == videoID else { return nil }
        return d
    }

    func delete(videoID: String) { try? FileManager.default.removeItem(at: url(videoID)) }
}
