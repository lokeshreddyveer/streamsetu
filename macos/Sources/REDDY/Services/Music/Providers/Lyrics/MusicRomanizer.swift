import Foundation

/// Latin-script readings for lyric lines, built from the platform's own transliteration (no dictionaries shipped).
/// Japanese: the system word tokenizer's reading, Hepburn without macrons, with particle fixes and glued inflections.
/// Chinese: Hanyu Pinyin with tone marks. Korean: Revised Romanization with the sound changes inside a word (our own rule set).
/// Cyrillic, Greek, Armenian, Georgian: generic transliteration. Indic scripts, Thai, Arabic and Hebrew are left alone on purpose:
/// a wrong reading is worse than none. Readings are never cached; they are applied on every answer.
enum MusicRomanizer {

    // MARK: whole lyric

    /// Adds a reading to each line that needs one. A song never mixes a source's own readings with ours: if any line already has one,
    /// nothing is added. Lines already in Latin script get none.
    static func apply(to lyrics: MusicLyrics) -> MusicLyrics {
        guard var lines = lyrics.synced, !lines.isEmpty, !lines.contains(where: { !($0.romanized ?? "").isEmpty }) else { return lyrics }
        let songJapanese = isJapanese(texts: lines.map(\.text))
        var changed = false
        for i in lines.indices {
            let text = lines[i].text
            let jp = songJapanese || lineLooksJapanese(text)
            guard let r = reading(of: text, japanese: jp) else { continue }
            lines[i].romanized = r
            if let words = lines[i].words, !words.isEmpty { lines[i].romanizedWords = timedReading(r, words: words, japanese: jp) }
            changed = true
        }
        guard changed else { return lyrics }
        var out = lyrics; out.synced = lines
        return out
    }

    /// Kana and Han are counted over the whole lyric: Japanese when there is kana and kana x 10 >= Han.
    static func isJapanese(texts: [String]) -> Bool {
        var kana = 0, han = 0
        for t in texts { for s in t.unicodeScalars { switch kind(of: s) { case .kana: kana += 1; case .han: han += 1; default: break } } }
        return kana > 0 && kana * 10 >= han
    }

    /// One line tested alone, so a Japanese verse in another language's song is read as Japanese; a single stylised kana in a Chinese
    /// song is not enough (three or more kana are needed).
    static func lineLooksJapanese(_ text: String) -> Bool {
        var kana = 0, han = 0
        for s in text.unicodeScalars { switch kind(of: s) { case .kana: kana += 1; case .han: han += 1; default: break } }
        return kana >= 3 && kana * 10 >= han
    }

    // MARK: one line

    enum Kind: Equatable { case hangul, kana, han, cyrillic, greek, armenian, georgian, unsupported, neutral }

    static func kind(of s: Unicode.Scalar) -> Kind {
        let v = s.value
        switch v {
        case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F: return .hangul
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return .kana
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2A6DF, 0x3005, 0x3007: return .han
        case 0x0400...0x052F, 0x1C80...0x1C8F: return .cyrillic
        case 0x0370...0x03FF, 0x1F00...0x1FFF: return .greek
        case 0x0530...0x058F: return .armenian
        case 0x10A0...0x10FF, 0x1C90...0x1CBF: return .georgian
        case 0x0590...0x08FF, 0x0900...0x0DFF, 0x0E00...0x0EFF, 0x0F00...0x109F, 0x1780...0x17FF: return .unsupported
        default: return .neutral
        }
    }

    private static func group(_ k: Kind) -> Kind { k == .kana || k == .han ? .han : k }

    /// The Latin reading of a line, or nil when nothing in it needs one.
    static func reading(of text: String, japanese: Bool) -> String? {
        var runs: [(Kind, String)] = []
        for s in text.unicodeScalars {
            let k = group(kind(of: s))
            if let last = runs.last, last.0 == k { runs[runs.count - 1].1.unicodeScalars.append(s) } else { runs.append((k, String(s))) }
        }
        var converted = false
        var out = ""
        var prevWasConverted = false
        for (k, run) in runs {
            var piece = run
            var isConv = false
            switch k {
            case .han: piece = cjk(run, japanese: japanese); isConv = true
            case .hangul: piece = koreanReading(run); isConv = true
            case .cyrillic, .greek, .armenian, .georgian: piece = generic(run); isConv = true
            case .unsupported: break
            case .neutral: piece = neutral(run)
            default: break
            }
            if isConv { converted = true }
            if !out.isEmpty {
                let a = out.last, b = piece.first
                let edgeA = (a.map { $0.isLetter || $0.isNumber || ",.!?;:".contains($0) } ?? false) && (prevWasConverted || isConv)
                let needSpace = edgeA && (b.map { $0.isLetter || $0.isNumber } ?? false)
                if needSpace { out += " " }
            }
            out += piece
            prevWasConverted = isConv
        }
        guard converted else { return nil }
        let result = out.split(whereSeparator: { $0 == " " }).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if result.isEmpty || result.lowercased() == MusicLyricsText.collapsed(text).lowercased() { return nil }
        return result
    }

    private static let punctuation: [Character: String] = [
        "。": ".", "、": ",", "，": ",", "．": ".", "！": "!", "？": "?", "：": ":", "；": ";", "（": "(", "）": ")",
        "「": "\"", "」": "\"", "『": "\"", "』": "\"", "【": "[", "】": "]", "・": " ", "〜": "~", "～": "~", "　": " ", "“": "\"", "”": "\"", "‘": "'", "’": "'"]

    private static func neutral(_ s: String) -> String {
        var t = ""
        for ch in s { t += punctuation[ch] ?? String(ch) }
        return t.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? t
    }

    private static func generic(_ s: String) -> String {
        let latin = s.applyingTransform(.toLatin, reverse: false) ?? s
        return latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
    }

    // MARK: Chinese and Japanese

    private static func cjk(_ run: String, japanese: Bool) -> String {
        japanese ? japaneseReading(run) : pinyin(run)
    }

    static func pinyin(_ s: String) -> String {
        let t = s.applyingTransform(.toLatin, reverse: false) ?? s
        return t.split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }

    private static let standalone: Set<String> = [
        "は", "が", "を", "に", "へ", "で", "と", "も", "の", "や", "か", "ね", "よ", "わ", "ぞ", "ぜ", "さ", "から", "まで", "より",
        "だ", "です", "なら", "ば", "って", "けど", "でも", "し", "など", "ので", "のに", "だけ", "しか", "ほど", "くらい", "ぐらい", "こそ"]
    private static let inflections: Set<String> = [
        "た", "て", "ない", "なかっ", "ます", "ませ", "ました", "ん", "れる", "られる", "せる", "させる", "たい", "ず", "ぬ", "ちゃ", "じゃ",
        "てる", "ちゃう", "たら", "だら", "ちゃっ", "ば"]

    private static func isHiragana(_ s: String) -> Bool { !s.isEmpty && s.unicodeScalars.allSatisfy { (0x3040...0x309F).contains($0.value) } }

    private static func japaneseReading(_ run: String) -> String {
        let cf = run as CFString
        let len = CFStringGetLength(cf)
        guard len > 0 else { return run }
        let tokenizer = CFStringTokenizerCreate(nil, cf, CFRangeMake(0, len), kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)
        var tokens: [(text: String, reading: String)] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let sub = (run as NSString).substring(with: NSRange(location: r.location, length: r.length))
            var rd = (CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String) ?? sub
            switch sub {
            case "は": rd = "wa"
            case "へ": rd = "e"
            case "を": rd = "o"
            default: break
            }
            tokens.append((sub, fixLongVowels(rd)))
        }
        // A word-final small tsu shows up as "~tsu": it doubles the next word's first consonant instead.
        var out: [(text: String, reading: String)] = []
        var pendingDouble = false
        for var t in tokens {
            if pendingDouble {
                if t.reading.hasPrefix("ch") { t.reading = "t" + t.reading } else if let f = t.reading.first, "bcdfghjklmnpqrstvwyz".contains(f) { t.reading = String(f) + t.reading }
                pendingDouble = false
            }
            if t.reading.hasSuffix("~tsu") {
                t.reading = String(t.reading.dropLast(4))
                pendingDouble = true
            }
            out.append(t)
        }
        var result = ""
        var prevText = ""
        for t in out {
            let glue = !result.isEmpty && isHiragana(t.text) && !standalone.contains(t.text)
                && (inflections.contains(t.text) || (prevText.unicodeScalars.last.map { (0x3040...0x309F).contains($0.value) } ?? false))
            if !result.isEmpty && !glue { result += " " }
            result += t.reading
            prevText = t.text
        }
        return result
    }

    private static func fixLongVowels(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0.value > 127 }) else { return s }
        var t = s
        for (a, b) in [("ā", "aa"), ("ī", "ii"), ("ū", "uu"), ("ē", "ee"), ("ō", "oo")] { t = t.replacingOccurrences(of: a, with: b) }
        return t
    }

    // MARK: Korean (Revised Romanization with sound changes inside a word)

    private static let onsets = ["ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]
    private static let onsetRoman: [String: String] = [
        "ㄱ": "g", "ㄲ": "kk", "ㄴ": "n", "ㄷ": "d", "ㄸ": "tt", "ㅁ": "m", "ㅂ": "b", "ㅃ": "pp", "ㅅ": "s", "ㅆ": "ss", "ㅇ": "",
        "ㅈ": "j", "ㅉ": "jj", "ㅊ": "ch", "ㅋ": "k", "ㅌ": "t", "ㅍ": "p", "ㅎ": "h"]
    private static let vowels = ["a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe", "yo", "u", "wo", "we", "wi", "yu", "eu", "ui", "i"]
    private static let codas: [[String]] = [
        [], ["ㄱ"], ["ㄲ"], ["ㄱ", "ㅅ"], ["ㄴ"], ["ㄴ", "ㅈ"], ["ㄴ", "ㅎ"], ["ㄷ"], ["ㄹ"], ["ㄹ", "ㄱ"], ["ㄹ", "ㅁ"], ["ㄹ", "ㅂ"], ["ㄹ", "ㅅ"],
        ["ㄹ", "ㅌ"], ["ㄹ", "ㅍ"], ["ㄹ", "ㅎ"], ["ㅁ"], ["ㅂ"], ["ㅂ", "ㅅ"], ["ㅅ"], ["ㅆ"], ["ㅇ"], ["ㅈ"], ["ㅊ"], ["ㅋ"], ["ㅌ"], ["ㅍ"], ["ㅎ"]]
    private static let codaRoman: [String: String] = ["ㄱ": "k", "ㄴ": "n", "ㄷ": "t", "ㄹ": "l", "ㅁ": "m", "ㅂ": "p", "ㅇ": "ng"]

    private struct Syllable { var onset: String; var vowel: Int; var coda: [String] }

    /// What a final consonant (or cluster) sounds like when nothing follows to change it.
    private static func neutralCoda(_ c: [String]) -> String? {
        guard let first = c.first else { return nil }
        if c.count == 2 {
            switch c.joined() { case "ㄹㄱ", "ㄹㅁ", "ㄹㅍ": return neutralCoda([c[1]]); default: return neutralCoda([first]) }
        }
        switch first {
        case "ㄱ", "ㄲ", "ㅋ": return "ㄱ"
        case "ㄴ": return "ㄴ"
        case "ㄷ", "ㅅ", "ㅆ", "ㅈ", "ㅊ", "ㅌ", "ㅎ": return "ㄷ"
        case "ㄹ": return "ㄹ"
        case "ㅁ": return "ㅁ"
        case "ㅂ", "ㅍ": return "ㅂ"
        case "ㅇ": return "ㅇ"
        default: return nil
        }
    }

    /// Romanises a run of Hangul. Spaces split words, so the sound changes only act inside the run given.
    static func koreanReading(_ run: String) -> String {
        var syl: [Syllable?] = []
        var raw: [String] = []
        for s in run.unicodeScalars {
            if (0xAC00...0xD7A3).contains(s.value) {
                let i = Int(s.value) - 0xAC00
                syl.append(Syllable(onset: onsets[i / 588], vowel: (i % 588) / 28, coda: codas[i % 28]))
            } else { syl.append(nil) }
            raw.append(String(s))
        }
        for i in 0..<max(0, syl.count - 1) {
            guard var a = syl[i], var b = syl[i + 1] else { continue }
            guard !a.coda.isEmpty else { continue }
            if b.onset == "ㅇ" {
                guard a.coda.last != "ㅇ" else { continue }
                let moved = a.coda.removeLast()
                if moved != "ㅎ" {
                    var o = moved
                    if b.vowel == 20 { if o == "ㄷ" { o = "ㅈ" } else if o == "ㅌ" { o = "ㅊ" } }
                    b.onset = o
                }
            } else if a.coda.last == "ㅎ", ["ㄱ", "ㄷ", "ㅈ"].contains(b.onset) {
                a.coda.removeLast()
                b.onset = ["ㄱ": "ㅋ", "ㄷ": "ㅌ", "ㅈ": "ㅊ"][b.onset] ?? b.onset
            } else if b.onset == "ㅎ", let n = neutralCoda(a.coda), ["ㄱ", "ㄷ", "ㅂ"].contains(n) {
                b.onset = a.coda.last == "ㅈ" ? "ㅊ" : ["ㄱ": "ㅋ", "ㄷ": "ㅌ", "ㅂ": "ㅍ"][n] ?? "ㅎ"
                a.coda = []
            } else if var n = neutralCoda(a.coda) {
                if a.coda == ["ㄹ", "ㄱ"], b.onset == "ㄱ" { n = "ㄹ" }
                let nasal = ["ㄱ": "ㅇ", "ㄷ": "ㄴ", "ㅂ": "ㅁ"]
                if nasal[n] != nil, b.onset == "ㄴ" || b.onset == "ㅁ" { n = nasal[n] ?? n }
                else if let m = nasal[n], b.onset == "ㄹ" { n = m; b.onset = "ㄴ" }
                else if (n == "ㅁ" || n == "ㅇ"), b.onset == "ㄹ" { b.onset = "ㄴ" }
                else if n == "ㄴ", b.onset == "ㄹ" { n = "ㄹ" }
                else if n == "ㄹ", b.onset == "ㄴ" { b.onset = "ㄹ" }
                a.coda = [n]
            }
            syl[i] = a; syl[i + 1] = b
        }
        var out = ""
        var prevCodaL = false
        for (i, s) in syl.enumerated() {
            guard let s else { out += raw[i]; prevCodaL = false; continue }
            if s.onset == "ㄹ" { out += prevCodaL ? "l" : "r" } else { out += onsetRoman[s.onset] ?? "" }
            out += vowels[s.vowel]
            if let n = neutralCoda(s.coda) { out += codaRoman[n] ?? ""; prevCodaL = n == "ㄹ" } else { prevCodaL = false }
        }
        return out
    }

    // MARK: timing the reading

    /// Cuts `reading` at each word's end by matching letters only (spaces and punctuation fall to the word before). Words that do not
    /// spell the reading leave it untimed, except Japanese, where each word takes its share by length (a kanji reads by context).
    static func timedReading(_ reading: String, words: [MusicLyricWord], japanese: Bool) -> [MusicLyricWord]? {
        guard !words.isEmpty else { return nil }
        func letters(_ s: String) -> Int { s.filter { $0.isLetter || $0.isNumber }.count }
        let total = letters(reading)
        guard total > 0 else { return nil }
        let own = words.map { w -> Int in
            let t = w.text.trimmingCharacters(in: .whitespaces)
            return letters(Self.reading(of: t, japanese: japanese) ?? t)
        }
        let sum = own.reduce(0, +)
        guard sum > 0 else { return nil }
        var cuts: [Int] = []
        if sum == total {
            var c = 0; for n in own { c += n; cuts.append(c) }
        } else if japanese {
            var c = 0
            for (i, n) in own.enumerated() { c += n; cuts.append(i == own.count - 1 ? total : min(total, Int((Double(c) / Double(sum) * Double(total)).rounded()))) }
        } else { return nil }
        var pieces = Array(repeating: "", count: words.count)
        var seen = 0, k = 0
        for ch in reading {
            let isL = ch.isLetter || ch.isNumber
            if isL {
                while k < words.count - 1, seen >= cuts[k] { k += 1 }
                seen += 1
            }
            pieces[k].append(ch)
        }
        var out: [MusicLyricWord] = []
        for (i, w) in words.enumerated() where !pieces[i].isEmpty {
            var p = pieces[i]
            if i < words.count - 1, !p.hasSuffix(" ") { p += " " }
            out.append(MusicLyricWord(text: p, startMs: w.startMs, endMs: w.endMs, background: w.background))
        }
        if var last = out.last { while last.text.last == " " { last.text.removeLast() }; out[out.count - 1] = last }
        return out.isEmpty ? nil : out
    }
}
