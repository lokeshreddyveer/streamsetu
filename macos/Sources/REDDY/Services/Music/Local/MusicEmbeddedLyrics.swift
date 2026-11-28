import Foundation
import AVFoundation

// Lyrics that travel inside the audio file. Two fields are written: the portable one every player reads (ID3 unsynced and synced lyric
// frames in an MP3, the lyrics atom in an M4A) and an app field that keeps word and syllable timing as enhanced LRC. Reading prefers
// the app field because it is richer. Everything that does not touch a file is pure and tested.

// MARK: - LRC text

enum MusicLRCText {
    /// `mm:ss.xx`, ASCII digits always, centiseconds rounded down. Minutes grow past two digits for long tracks.
    static func stamp(_ ms: Int64) -> String {
        let cs = max(0, ms) / 10
        return String(format: "%02d:%02d.%02d", Int(cs / 6000), Int((cs / 100) % 60), Int(cs % 100))
    }

    /// The portable form: one `[stamp]text` row per line, sorted, no header tags and no word timing; the background vocal stays on its
    /// lead's row. Lyrics with no timing are written as plain rows.
    static func portable(_ lyrics: MusicLyrics) -> String {
        if let lines = lyrics.synced, !lines.isEmpty {
            return lines.sorted { $0.timeMs < $1.timeMs }.map { "[\(stamp($0.timeMs))]\($0.text)" }.joined(separator: "\n")
        }
        return lyrics.plain ?? ""
    }

    /// The app field: enhanced LRC. Per line `[stamp]` then `<stamp>text` runs, one per syllable (none inside a word), words separated
    /// by one space, background words after the lead with their own stamps, stamps never going backwards, and a closing stamp at
    /// the line's end. Lines that are the answering side of a duet start with `<R>`. Nil when nothing is word-timed.
    static func enhanced(_ lyrics: MusicLyrics) -> String? {
        guard let lines = lyrics.synced?.sorted(by: { $0.timeMs < $1.timeMs }), lines.contains(where: \.isWordSynced) else { return nil }
        let far = MusicLyricsVoices.layout(lines, types: lyrics.voiceTypes)?.map(\.far) ?? Array(repeating: false, count: lines.count)
        var out: [String] = []
        for (i, l) in lines.enumerated() {
            var row = "[\(stamp(l.timeMs))]" + (far[i] ? "<R>" : "")
            guard let words = l.words, !words.isEmpty else { row += l.text; out.append(row); continue }
            let ordered = words.filter { !$0.background } + words.filter(\.background)
            var tokens: [(text: String, start: Int64)] = []
            var hasSyllables = false
            var lastBackground = ordered.lastIndex(where: \.background)
            let firstBackground = ordered.firstIndex(where: \.background)
            if let lb = lastBackground, lb != ordered.count - 1 { lastBackground = ordered.count - 1 }
            for (wi, w) in ordered.enumerated() {
                let text = MusicLyricsSyllables.trimmedEnd(w.text)
                var pieces: [(String, Int64)] = []
                if let s = w.syllables, s.count >= 2 {
                    hasSyllables = true
                    let chars = Array(text)
                    for syl in s {
                        let a = max(0, min(chars.count, syl.startChar)), b = max(a, min(chars.count, syl.endChar))
                        pieces.append((String(chars[a..<b]), syl.startMs))
                    }
                } else { pieces = [(text, w.startMs)] }
                if wi == firstBackground, !pieces.isEmpty, !pieces[0].0.hasPrefix("(") { pieces[0].0 = "(" + pieces[0].0 }
                if wi == lastBackground, !pieces.isEmpty, !(pieces[pieces.count - 1].0.hasSuffix(")")) { pieces[pieces.count - 1].0 += ")" }
                for (k, p) in pieces.enumerated() {
                    let isLastPiece = k == pieces.count - 1
                    tokens.append((p.0 + (isLastPiece && wi < ordered.count - 1 ? " " : ""), p.1))
                }
            }
            var previous = l.timeMs
            for t in tokens {
                let s = max(previous, t.start)
                row += "<\(stamp(s))>" + t.text
                previous = s
            }
            let end = max(words.map(\.endMs).max() ?? previous, previous)
            row += (hasSyllables ? " " : "") + "<\(stamp(end))>"
            out.append(row)
        }
        return out.joined(separator: "\n")
    }

    /// Reads the app field back. `<R>` lines become the second singer so the duet layout reproduces; syllables are glued from the
    /// per-syllable stamps; "( ... )" tails become background words again.
    static func parseEnhanced(_ text: String, source: String, provider: String) -> MusicLyrics? {
        var farTimes = Set<Int64>()
        var cleaned: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var row = String(raw)
            if let r = row.range(of: #"^(\[[^\]]+\])+<R>"#, options: .regularExpression) {
                let head = String(row[r]).dropLast(3)
                if let t = MusicLyricsParsers.stampMs(String(head.dropFirst().prefix { $0 != "]" })) { farTimes.insert(t) }
                row = String(head) + String(row[r.upperBound...])
            }
            cleaned.append(row)
        }
        var lines = MusicLyricsParsers.parseLRC(cleaned.joined(separator: "\n"))
        guard !lines.isEmpty else { return nil }
        lines = MusicLyricsSyllables.glueLines(lines, explicitSpacing: false)
        lines = MusicLyricsBackground.splitAll(lines)
        if !farTimes.isEmpty { for i in lines.indices { lines[i].voice = farTimes.contains(lines[i].timeMs) ? "v2" : "v1" } }
        return MusicLyricsNormalizer.normalize(MusicLyrics(synced: lines, sourceName: source, providerID: provider))
    }
}

// MARK: - ID3 frames

enum MusicID3LyricFrames {
    static let appFrameDescription = "STREAMSETU_LYRICS"

    private static func utf16(_ s: String) -> Data { Data([0xFF, 0xFE]) + (s.data(using: .utf16LittleEndian) ?? Data()) }
    private static let terminator = Data([0, 0])

    static func syncsafe(_ n: Int) -> [UInt8] { [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)] }

    /// A frame with a header for tag version 3 (plain sizes) or 4 (syncsafe sizes).
    static func frame(_ id: String, _ payload: Data, version: Int) -> Data {
        var out = Data(id.utf8)
        let n = payload.count
        if version >= 4 { out.append(contentsOf: syncsafe(n)) } else {
            out.append(contentsOf: [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        }
        out.append(contentsOf: [0, 0])
        return out + payload
    }

    static func uslt(_ text: String, language: String = "und") -> Data {
        Data([0x01]) + Data(language.utf8.prefix(3)) + terminator + utf16("") .dropFirst(0).prefix(0) + utf16(text)
    }

    /// Synced lyrics, millisecond stamps, content type "lyrics".
    static func sylt(_ lines: [MusicLyricLine], language: String = "und") -> Data {
        var d = Data([0x01]) + Data(language.utf8.prefix(3)) + Data([0x02, 0x01]) + utf16("") + terminator
        for l in lines.sorted(by: { $0.timeMs < $1.timeMs }) {
            d += utf16(l.text) + terminator
            let t = UInt32(clamping: max(0, l.timeMs))
            d += Data([UInt8((t >> 24) & 0xFF), UInt8((t >> 16) & 0xFF), UInt8((t >> 8) & 0xFF), UInt8(t & 0xFF)])
        }
        return d
    }

    /// A user text frame holding the enhanced LRC under our own description.
    static func appText(_ enhanced: String) -> Data { Data([0x01]) + utf16(appFrameDescription) + terminator + utf16(enhanced) }

    /// All lyric frames for a lyric, ready to append to a tag of `version`.
    static func frames(for lyrics: MusicLyrics, version: Int = 3) -> Data {
        var out = Data()
        let portable = MusicLRCText.portable(lyrics)
        if !portable.isEmpty { out += frame("USLT", uslt(portable), version: version) }
        if let s = lyrics.synced, !s.isEmpty { out += frame("SYLT", sylt(s), version: version) }
        if let e = MusicLRCText.enhanced(lyrics) { out += frame("TXXX", appText(e), version: version) }
        return out
    }

    // MARK: reading frames

    struct Frame { var id: String; var payload: [UInt8] }

    /// Every frame of a tag body (versions 3 and 4; version 2 is left to the older reader).
    static func frames(inTag tag: Data) -> (version: Int, frames: [Frame])? {
        let b = [UInt8](tag)
        guard b.count >= 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33, b[3] == 3 || b[3] == 4 else { return nil }
        let version = Int(b[3])
        let size = Int(b[6]) << 21 | Int(b[7]) << 14 | Int(b[8]) << 7 | Int(b[9])
        var pos = 10
        if b[5] & 0x40 != 0, b.count >= 14 {
            let n = version == 4 ? Int(b[10]) << 21 | Int(b[11]) << 14 | Int(b[12]) << 7 | Int(b[13]) : (Int(b[10]) << 24 | Int(b[11]) << 16 | Int(b[12]) << 8 | Int(b[13])) + 4
            pos += n
        }
        let end = min(b.count, 10 + size)
        var out: [Frame] = []
        while pos + 10 <= end {
            if b[pos] == 0 { break }
            let id = String(decoding: b[pos..<pos + 4], as: UTF8.self)
            let n = version == 4 ? Int(b[pos + 4]) << 21 | Int(b[pos + 5]) << 14 | Int(b[pos + 6]) << 7 | Int(b[pos + 7])
                : Int(b[pos + 4]) << 24 | Int(b[pos + 5]) << 16 | Int(b[pos + 6]) << 8 | Int(b[pos + 7])
            let start = pos + 10
            guard n >= 0, start + n <= end else { break }
            out.append(Frame(id: id, payload: Array(b[start..<start + n])))
            pos = start + n
        }
        return (version, out)
    }

    /// The enhanced LRC held in our own user text frame, if the tag has one.
    static func appText(inTag tag: Data) -> String? {
        guard let parsed = frames(inTag: tag) else { return nil }
        for f in parsed.frames where f.id == "TXXX" && f.payload.count > 1 {
            let enc = f.payload[0]
            let wide = enc == 1 || enc == 2
            let body = Array(f.payload.dropFirst())
            var i = 0
            if wide { while i + 1 < body.count, !(body[i] == 0 && body[i + 1] == 0) { i += 2 } } else { while i < body.count, body[i] != 0 { i += 1 } }
            let desc = decode(Array(body[0..<min(i, body.count)]), enc)
            guard desc == appFrameDescription else { continue }
            let rest = Array(body.dropFirst(min(body.count, i + (wide ? 2 : 1))))
            return decode(rest, enc)
        }
        return nil
    }

    private static func decode(_ bytes: [UInt8], _ enc: UInt8) -> String {
        let d = Data(bytes)
        switch enc {
        case 0: return String(data: d, encoding: .isoLatin1) ?? ""
        case 1:
            if bytes.starts(with: [0xFE, 0xFF]) { return String(data: d.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
            if bytes.starts(with: [0xFF, 0xFE]) { return String(data: d.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
            return String(data: d, encoding: .utf16) ?? ""
        case 2: return String(data: d, encoding: .utf16BigEndian) ?? ""
        default: return String(data: d, encoding: .utf8) ?? ""
        }
    }

    /// The tag with its lyric frames (USLT, SYLT and our TXXX) replaced by `lyrics`' frames and every other frame kept. Written in the
    /// version the tag already has. Nil for a tag this cannot rewrite safely (version 2, unsynchronised, or no tag handling at all).
    static func replacingLyrics(inTag tag: Data?, with lyrics: MusicLyrics) -> Data? {
        var version = 3
        var kept = Data()
        if let tag, !tag.isEmpty {
            guard let parsed = frames(inTag: tag) else { return nil }
            let flags = [UInt8](tag)[5]
            if flags & 0x80 != 0 { return nil }
            version = parsed.version
            for f in parsed.frames {
                if f.id == "USLT" || f.id == "SYLT" { continue }
                if f.id == "TXXX", appText(inTag: tagWith(f, version: version)) != nil { continue }
                kept += frame(f.id, Data(f.payload), version: version)
            }
        }
        let body = kept + frames(for: lyrics, version: version)
        var out = Data("ID3".utf8)
        out.append(contentsOf: [UInt8(version), 0, 0])
        out.append(contentsOf: syncsafe(body.count))
        return out + body
    }

    private static func tagWith(_ f: Frame, version: Int) -> Data {
        let body = frame(f.id, Data(f.payload), version: version)
        var out = Data("ID3".utf8)
        out.append(contentsOf: [UInt8(version), 0, 0])
        out.append(contentsOf: syncsafe(body.count))
        return out + body
    }
}

// MARK: - reading and writing files

enum MusicEmbeddedLyrics {
    static let sourceName = "Lyrics saved with this download"
    static let appMetadataKey = "com.streamsetu.lyrics"
    private static let maxTagRead = 8 * 1_048_576

    enum WriteResult: Equatable, Sendable { case written, unsupportedFormat, failed(String) }

    /// The lyrics stored in the file, if any: our app field first, then the portable frames.
    static func read(_ file: URL) async -> MusicLyrics? {
        let head = (try? FileHandle(forReadingFrom: file)).flatMap { h -> Data? in defer { try? h.close() }; return try? h.read(upToCount: 16) } ?? Data()
        if head.starts(with: Array("ID3".utf8)) { return readMP3(file) }
        return await readMP4(file)
    }

    static func readMP3(_ file: URL) -> MusicLyrics? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 10), head.count == 10, head.starts(with: Array("ID3".utf8)) else { return nil }
        let size = Int(head[6]) << 21 | Int(head[7]) << 14 | Int(head[8]) << 7 | Int(head[9])
        guard let body = try? h.read(upToCount: min(size, maxTagRead)) else { return nil }
        let tag = head + body
        if let text = MusicID3LyricFrames.appText(inTag: tag), let l = MusicLRCText.parseEnhanced(text, source: sourceName, provider: MusicLyricsSources.localOwn) { return l }
        return ID3Lyrics.parse(header: head, body: body)
    }

    private static func readMP4(_ file: URL) async -> MusicLyrics? {
        let asset = AVURLAsset(url: file)
        guard let items = try? await asset.load(.metadata) else { return nil }
        let custom = AVMetadataItem.identifier(forKey: appMetadataKey, keySpace: .quickTimeMetadata)
        for item in items where item.identifier == custom {
            if let s = try? await item.load(.stringValue), let l = MusicLRCText.parseEnhanced(s, source: sourceName, provider: MusicLyricsSources.localOwn) { return l }
        }
        for item in items where item.identifier == .iTunesMetadataLyrics {
            if let s = try? await item.load(.stringValue) { return MusicLyricsParsers.lyrics(from: s, source: sourceName, provider: MusicLyricsSources.localOwn) }
        }
        return nil
    }

    /// Stores the lyrics in the file in place (through a temporary file and an atomic swap; the file is never damaged on failure).
    static func write(_ lyrics: MusicLyrics, to file: URL) async -> WriteResult {
        let head = (try? FileHandle(forReadingFrom: file)).flatMap { h -> Data? in defer { try? h.close() }; return try? h.read(upToCount: 16) } ?? Data()
        let format = MusicTagWriter.detectFormat(head: head)
        switch format {
        case .mp3: return writeMP3(lyrics, to: file)
        case .mp4: return await writeMP4(lyrics, to: file)
        default: return .unsupportedFormat
        }
    }

    private static func writeMP3(_ lyrics: MusicLyrics, to file: URL) -> WriteResult {
        let fm = FileManager.default
        let temp = file.deletingLastPathComponent().appendingPathComponent(".lyrics-" + UUID().uuidString)
        do {
            let audio = try Data(contentsOf: file, options: .alwaysMapped)
            let skip = MusicTagWriter.existingTagLength(in: audio)
            let existing = skip > 0 ? Data(audio.prefix(skip)) : nil
            guard let tag = MusicID3LyricFrames.replacingLyrics(inTag: existing, with: lyrics) else { return .unsupportedFormat }
            guard fm.createFile(atPath: temp.path, contents: nil) else { return .failed("Could not create a temporary file.") }
            let out = try FileHandle(forWritingTo: temp)
            try out.write(contentsOf: tag)
            try out.write(contentsOf: audio.dropFirst(skip))
            try out.close()
            _ = try fm.replaceItemAt(file, withItemAt: temp)
            return .written
        } catch {
            try? fm.removeItem(at: temp)
            return .failed("Could not write the lyrics.")
        }
    }

    private final class ExportBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ s: AVAssetExportSession) { session = s }
    }

    private static func writeMP4(_ lyrics: MusicLyrics, to file: URL) async -> WriteResult {
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        let id = UUID().uuidString
        let source = dir.appendingPathComponent(".lyricsrc-" + id + ".m4a"), output = dir.appendingPathComponent(".lyrics-" + id + ".m4a")
        defer { try? fm.removeItem(at: source); try? fm.removeItem(at: output) }
        do {
            do { try fm.linkItem(at: file, to: source) } catch { try fm.copyItem(at: file, to: source) }
            let asset = AVURLAsset(url: source)
            let custom = AVMetadataItem.identifier(forKey: appMetadataKey, keySpace: .quickTimeMetadata)
            let existing = (try? await asset.load(.metadata)) ?? []
            var items = existing.filter { $0.identifier != .iTunesMetadataLyrics && $0.identifier != custom }
            let text = kCMMetadataBaseDataType_UTF8 as String
            func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
                let m = AVMutableMetadataItem()
                m.identifier = id; m.value = value as NSString; m.dataType = text; m.extendedLanguageTag = "und"
                return m
            }
            let portable = MusicLRCText.portable(lyrics)
            if !portable.isEmpty { items.append(item(.iTunesMetadataLyrics, portable)) }
            if let e = MusicLRCText.enhanced(lyrics), let custom { items.append(item(custom, e)) }
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return .failed("This file cannot be updated.") }
            session.metadata = items
            let box = ExportBox(session)
            if #available(macOS 15.0, iOS 18.0, *) { try await box.session.export(to: output, as: .m4a) } else {
                box.session.outputURL = output
                box.session.outputFileType = .m4a
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in box.session.exportAsynchronously { c.resume() } }
                guard box.session.status == .completed else { return .failed("Could not write the lyrics.") }
            }
            guard fm.fileExists(atPath: output.path) else { return .failed("Could not write the lyrics.") }
            _ = try fm.replaceItemAt(file, withItemAt: output)
            return .written
        } catch {
            return .failed("Could not write the lyrics.")
        }
    }

    /// A `lyrics.lrc` beside a downloaded package: portable LRC, at most 8 MiB.
    static func writeSidecar(_ lyrics: MusicLyrics, in folder: URL) -> Bool {
        let text = MusicLRCText.portable(lyrics)
        guard !text.isEmpty else { return false }
        return (try? text.write(to: folder.appendingPathComponent("lyrics.lrc"), atomically: true, encoding: .utf8)) != nil
    }
}
