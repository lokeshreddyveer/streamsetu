import Foundation

// The word and syllable rules shared by every word-timed source: gluing timed runs into words, keeping each word's syllables,
// splitting "( ... )" background tails, and inserting instrumental gaps. Pure functions, no network.

extension MusicLyricLine {
    /// An empty line stands for an instrumental break.
    var isGap: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isWordSynced: Bool { !(words?.isEmpty ?? true) }
    /// True only when the source said where the line ends (words, or an explicit end). The distance to the next stamp proves nothing.
    var hasKnownEnd: Bool { isWordSynced || endMs != nil }
    /// Last word end, else the stated end, else the start. The background counts: the later of the two wins.
    var resolvedEndMs: Int64 { max(words?.map(\.endMs).max() ?? timeMs, endMs ?? timeMs, timeMs) }

    /// How many characters of `text` have been sung at `position`. Without word timing the line is all or nothing at its stamp.
    func revealedChars(at position: Int64) -> Int {
        let total = text.count
        guard let words, !words.isEmpty else { return position >= timeMs ? total : 0 }
        var cursor = text.startIndex
        var revealed = 0
        for (i, w) in words.enumerated() {
            let trimmed = MusicLyricsSyllables.trimmedEnd(w.text)
            guard !trimmed.isEmpty else { continue }
            guard let r = text.range(of: trimmed, range: cursor..<text.endIndex) else { continue }
            let before = text.distance(from: text.startIndex, to: r.lowerBound)
            if position < w.startMs { return max(revealed, min(before, revealed)) }
            let sung = w.charsSung(at: position)
            if position < w.endMs || i == words.count - 1 { return min(total, before + sung) }
            revealed = before + trimmed.count
            cursor = r.upperBound
            // The space after a word fills linearly over the pause before the next word.
            if i + 1 < words.count, w.text.last?.isWhitespace == true {
                let next = words[i + 1]
                if position >= next.startMs { revealed += 1 } else if next.startMs > w.endMs, position > w.endMs {
                    let f = Double(position - w.endMs) / Double(next.startMs - w.endMs)
                    if f >= 0.5 { revealed += 1 }
                }
            }
        }
        return min(total, revealed)
    }
}

extension MusicLyricWord {
    /// Characters of the word (trailing space excluded) sung at `position`: 0 before the start, all after the end. With syllables each
    /// one fills its own characters over its own time and a pause between two rests on the boundary; without, the fill is linear.
    func charsSung(at position: Int64) -> Int {
        let length = MusicLyricsSyllables.trimmedEnd(text).count
        if position <= startMs { return 0 }
        if position >= endMs { return length }
        guard let syllables, syllables.count >= 2 else {
            return Int((Double(position - startMs) / Double(max(1, endMs - startMs)) * Double(length)).rounded(.down))
        }
        var done = 0
        for s in syllables {
            if position >= s.endMs { done = s.endChar; continue }
            if position <= s.startMs { return min(length, done) }
            let f = Double(position - s.startMs) / Double(max(1, s.endMs - s.startMs))
            return min(length, s.startChar + Int((f * Double(s.endChar - s.startChar)).rounded(.down)))
        }
        return min(length, done)
    }
}

enum MusicLyricsSyllables {
    static func trimmedEnd(_ s: String) -> String {
        var x = s
        while let l = x.last, l.isWhitespace { x.removeLast() }
        return x
    }

    /// Han, kana, CJK and full-width punctuation, Hangul-free, and Thai are written without spaces, so each run stays a word of its own.
    static func isUnspaced(_ c: Character) -> Bool {
        c.unicodeScalars.contains { s in
            switch s.value {
            case 0x3000...0x303F, 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF,
                 0x20000...0x2FA1F, 0x0E00...0x0E7F: return true
            default: return false
            }
        }
    }

    /// Fills each syllable's character range and tidies the list: sorted, zero-width ones dropped, fewer than two means none, the first
    /// starts at character 0, each ends where the next starts, the last ends at the word's length.
    static func normalizeSyllables(_ raw: [MusicLyricSyllable], wordLength: Int) -> [MusicLyricSyllable]? {
        var s = raw.sorted { $0.startChar < $1.startChar }.filter { $0.endChar > $0.startChar }
        guard s.count >= 2 else { return nil }
        s[0].startChar = 0
        for i in 0..<(s.count - 1) { s[i].endChar = s[i + 1].startChar }
        s[s.count - 1].endChar = wordLength
        return s.filter { $0.endChar > $0.startChar }.count >= 2 ? s : nil
    }

    /// Joins timed runs into words. A run that ends without whitespace followed by a run that starts without it is the front of a word that
    /// continues; a blank run ends the word. Unspaced scripts never join. A line where no run has any whitespace stays one word per run
    /// unless the caller says the spacing is explicit (PaxSenix, LyricsPlus, Musixmatch), in which case it is believed.
    static func glue(_ runs: [MusicLyricWord], explicitSpacing: Bool = false) -> [MusicLyricWord] {
        guard runs.count > 1 else { return runs }
        let anySpace = runs.contains { $0.text.contains { $0.isWhitespace } }
        guard explicitSpacing || anySpace else { return runs }
        var out: [MusicLyricWord] = []
        var group: [MusicLyricWord] = []
        func flush() {
            guard !group.isEmpty else { return }
            if group.count == 1 { out.append(group[0]); group = []; return }
            var text = ""
            var syl: [MusicLyricSyllable] = []
            for g in group {
                let piece = trimmedEnd(g.text)
                let start = text.count
                text += piece
                syl.append(MusicLyricSyllable(startMs: g.startMs, endMs: g.endMs, startChar: start, endChar: start + piece.count))
            }
            let trailing = group.last.map { String($0.text.dropFirst(trimmedEnd($0.text).count)) } ?? ""
            let length = text.count
            text += trailing
            var w = MusicLyricWord(text: text, startMs: group[0].startMs, endMs: group.map(\.endMs).max() ?? group[0].endMs, background: group[0].background)
            w.syllables = normalizeSyllables(syl, wordLength: length)
            out.append(w)
            group = []
        }
        for r in runs {
            if let last = group.last {
                let joins = last.text.last.map { !$0.isWhitespace && !isUnspaced($0) } == true
                    && r.text.first.map { !$0.isWhitespace && !isUnspaced($0) } == true
                    && last.background == r.background
                if !joins { flush() }
            }
            group.append(r)
        }
        flush()
        return out
    }

    /// Glues every word-timed line of a lyric; line start becomes the earliest of the stamp and the first word.
    static func glueLines(_ lines: [MusicLyricLine], explicitSpacing: Bool = false) -> [MusicLyricLine] {
        lines.map { l in
            guard let w = l.words, !w.isEmpty else { return l }
            var x = l
            x.words = glue(w, explicitSpacing: explicitSpacing)
            return x
        }
    }

    /// Strips one pair of outer brackets from background text for display, shifting the syllable offsets with it.
    static func displayWord(_ w: MusicLyricWord) -> MusicLyricWord {
        var x = w
        var text = w.text
        var shift = 0
        if text.hasPrefix("(") || text.hasPrefix("（") { text.removeFirst(); shift = 1 }
        let core = trimmedEnd(text)
        let trailing = String(text.dropFirst(core.count))
        var body = core
        if body.hasSuffix(")") || body.hasSuffix("）") { body.removeLast() }
        x.text = body + trailing
        if shift > 0 || body.count != core.count, let s = w.syllables {
            let len = body.count
            x.syllables = normalizeSyllables(s.map {
                MusicLyricSyllable(startMs: $0.startMs, endMs: $0.endMs, startChar: max(0, $0.startChar - shift), endChar: min(len, max(0, $0.endChar - shift)))
            }, wordLength: len)
        }
        return x
    }

    static func displayBackground(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        if (t.hasPrefix("(") && t.hasSuffix(")")) || (t.hasPrefix("（") && t.hasSuffix("）")) { t.removeFirst(); t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: background tails

enum MusicLyricsBackground {
    /// A line that ends with a "( ... )" group (nesting aware, the group starting after the first character and holding a letter or
    /// digit) is split into lead and background. Word-timed: the split must fall on a word boundary and the lead keeps at least one word;
    /// the trailing words are flagged as background. Line-timed: the group goes to `backgroundText`. Lines that are fully bracketed, already
    /// have a background, or have a bracket in the middle of a word are returned unchanged.
    static func split(_ line: MusicLyricLine) -> MusicLyricLine {
        if line.backgroundText != nil || (line.words?.contains(where: \.background) ?? false) { return line }
        let t = line.text.trimmingCharacters(in: .whitespaces)
        guard let tail = tailGroup(t) else { return line }
        let lead = String(t[..<tail.start]).trimmingCharacters(in: .whitespaces)
        guard !lead.isEmpty else { return line }
        guard let words = line.words, !words.isEmpty else {
            var x = line
            x.backgroundText = String(t[tail.start...])
            return x
        }
        let collapsed = MusicLyricsText.collapsed(t)
        let pieces: [(index: Int, text: String)] = words.enumerated().compactMap { (i, w) in
            let p = MusicLyricsSyllables.trimmedEnd(w.text).trimmingCharacters(in: .whitespaces)
            return p.isEmpty ? nil : (i, p)
        }
        guard pieces.map(\.text).joined(separator: " ") == collapsed else { return line }
        let leadCount = MusicLyricsText.collapsed(lead).count
        var offset = 0
        var k: Int?
        for p in pieces {
            if offset == leadCount + 1 { k = p.index; break }
            offset += p.text.count + 1
            if offset > leadCount + 1 { return line }
        }
        guard let k, k > 0 else { return line }
        var x = line
        var out = words
        for i in k..<out.count { out[i].background = true }
        x.words = out
        return x
    }

    /// Where a closing bracket at the end of `t` has its opener; nil when there is no such group, the group opens at index 0, or holds
    /// no letter or digit.
    static func tailGroup(_ t: String) -> (start: String.Index, group: String)? {
        guard let last = t.last, last == ")" || last == "）" else { return nil }
        var depth = 0
        var i = t.endIndex
        while i > t.startIndex {
            i = t.index(before: i)
            let c = t[i]
            if c == ")" || c == "）" { depth += 1 } else if c == "(" || c == "（" {
                depth -= 1
                if depth == 0 {
                    guard i > t.startIndex else { return nil }
                    let group = String(t[i...])
                    guard group.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
                    return (i, group)
                }
            }
        }
        return nil
    }

    static func splitAll(_ lines: [MusicLyricLine]) -> [MusicLyricLine] { lines.map(split) }
}

// MARK: gaps

enum MusicLyricsGaps {
    static let minGapMs: Int64 = 4_000

    /// Word-timed sources: where a line with a KNOWN end is followed by at least 4 s of silence, an empty line is placed at its end;
    /// a first line that starts at 4 s or later gets one at 0. A marker never shares its stamp with a real line.
    static func insert(into lines: [MusicLyricLine]) -> [MusicLyricLine] {
        guard !lines.isEmpty else { return lines }
        var out: [MusicLyricLine] = []
        if let f = lines.first, f.timeMs >= minGapMs, !f.isGap { out.append(MusicLyricLine(timeMs: 0, text: "")) }
        for (i, l) in lines.enumerated() {
            out.append(l)
            guard i + 1 < lines.count, !l.isGap, l.hasKnownEnd else { continue }
            let end = l.resolvedEndMs
            let next = lines[i + 1].timeMs
            if next - end >= minGapMs, end > l.timeMs, !lines.contains(where: { $0.timeMs == end }) {
                out.append(MusicLyricLine(timeMs: end, text: ""))
            }
        }
        return out
    }

    /// Plain LRC: an empty stamp stays only if the next stamp is at least 4 s later (a trailing one always stays); a first line at 4 s or
    /// later gets an empty line at 0.
    static func pruneEmptyStamps(_ lines: [MusicLyricLine]) -> [MusicLyricLine] {
        var out: [MusicLyricLine] = []
        for (i, l) in lines.enumerated() {
            if l.isGap, i + 1 < lines.count, lines[i + 1].timeMs - l.timeMs < minGapMs { continue }
            out.append(l)
        }
        if let f = out.first, !f.isGap, f.timeMs >= minGapMs { out.insert(MusicLyricLine(timeMs: 0, text: ""), at: 0) }
        return out
    }
}

// MARK: instrumental notice

enum MusicLyricsNotice {
    /// "Pure music, please enjoy": some services answer with this instead of lyrics. Every non-empty line must match.
    static func isInstrumentalNotice(_ lines: [MusicLyricLine]) -> Bool {
        let texts = lines.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !texts.isEmpty else { return false }
        return texts.allSatisfy { $0.contains("纯音乐") && $0.contains("欣赏") }
    }
}
