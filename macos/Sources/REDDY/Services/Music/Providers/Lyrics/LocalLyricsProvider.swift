import Foundation
import AVFoundation

/// Lyrics that live next to a local audio file (`song.lrc`, `song.ttml`) or inside it (ID3 synced and unsynced lyrics, MP4 lyrics).
/// Nothing leaves the device. Answers only for local files.
struct LocalLyricsProvider: MusicLyricsRequestProvider {
    static let maxFileBytes = 1_048_576
    static let name = MusicLyricsSources.name(MusicLyricsSources.localOwn)

    init() {}

    var info: MusicProviderInfo {
        MusicProviderInfo(id: MusicLyricsSources.localOwn, name: Self.name, summary: "Lyrics files next to your music files, and lyrics stored inside them.",
                          privacyNote: "Reads only the lyrics files and tags of local songs. Nothing is sent anywhere.")
    }
    var capabilities: MusicCapabilities { [.lyrics] }

    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics? {
        guard request.isLocal, let file = request.localFileURL else { return nil }
        return await Task.detached(priority: .utility) { await Self.read(file) }.value
    }

    static func read(_ file: URL) async -> MusicLyrics? {
        for ext in ["ttml", "lrc"] {
            if let side = sidecar(for: file, ext: ext), let l = parseFile(side) { return l }
        }
        if let l = ID3Lyrics.read(file) { return l }
        return await mp4Lyrics(file)
    }

    /// Any file with the same name and the extension, in any letter case.
    static func sidecar(for audio: URL, ext: String) -> URL? {
        let dir = audio.deletingLastPathComponent()
        let stem = audio.deletingPathExtension().lastPathComponent.lowercased()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.pathExtension.lowercased() == ext && $0.deletingPathExtension().lastPathComponent.lowercased() == stem }
    }

    /// A lyrics file the person picked (also used for the import action). Larger than 1 MiB is refused.
    static func parseFile(_ url: URL) -> MusicLyrics? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxFileBytes,
              let data = try? Data(contentsOf: url), let text = decode(data) else { return nil }
        return MusicLyricsParsers.lyrics(from: text, source: name, provider: MusicLyricsSources.localOwn)
    }

    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func mp4Lyrics(_ file: URL) async -> MusicLyrics? {
        let asset = AVURLAsset(url: file)
        guard let items = try? await asset.load(.metadata) else { return nil }
        for item in items where item.identifier == .iTunesMetadataLyrics {
            if let s = try? await item.load(.stringValue) {
                return MusicLyricsParsers.lyrics(from: s, source: name, provider: MusicLyricsSources.localOwn)
            }
        }
        return nil
    }
}

/// A small ID3v2 reader for the lyric frames only (USLT, SYLT; v2.2 names ULT, SLT).
enum ID3Lyrics {
    static func read(_ file: URL) -> MusicLyrics? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 10), head.count == 10 else { return nil }
        let size = synchsafe(head, 6)
        guard let body = try? handle.read(upToCount: min(size, 8 * 1_048_576)) else { return nil }
        return parse(header: head, body: body)
    }

    static func parse(header: Data, body: Data) -> MusicLyrics? {
        let h = [UInt8](header), b = [UInt8](body)
        guard h.count == 10, h[0] == 0x49, h[1] == 0x44, h[2] == 0x33 else { return nil }
        let major = Int(h[3])
        guard (2...4).contains(major) else { return nil }
        var pos = 0
        if h[5] & 0x40 != 0, major >= 3, b.count >= 4 {
            let n = major == 4 ? synchsafe(b, 0) : be32(b, 0) + 4
            pos = n
        }
        var unsynced: String?
        var synced: [MusicLyricLine]?
        let idLen = major == 2 ? 3 : 4, headLen = major == 2 ? 6 : 10
        while pos + headLen <= b.count {
            let idBytes = Array(b[pos..<pos + idLen])
            if idBytes.allSatisfy({ $0 == 0 }) { break }
            let id = String(decoding: idBytes, as: UTF8.self)
            let fsize: Int
            if major == 2 { fsize = Int(b[pos + 3]) << 16 | Int(b[pos + 4]) << 8 | Int(b[pos + 5]) }
            else if major == 4 { fsize = synchsafe(b, pos + 4) } else { fsize = be32(b, pos + 4) }
            let start = pos + headLen
            guard fsize >= 0, start + fsize <= b.count else { break }
            let frame = Array(b[start..<start + fsize])
            if id == "USLT" || id == "ULT", unsynced == nil { unsynced = unsyncedText(frame) }
            if id == "SYLT" || id == "SLT", synced == nil { synced = syncedLines(frame) }
            pos = start + fsize
        }
        let name = LocalLyricsProvider.name
        if let synced, !synced.isEmpty {
            return MusicLyricsNormalizer.normalize(MusicLyrics(synced: synced, plain: unsynced, sourceName: name, providerID: MusicLyricsSources.localOwn))
        }
        if let unsynced {
            return MusicLyricsParsers.lyrics(from: unsynced, source: name, provider: MusicLyricsSources.localOwn)
        }
        return nil
    }

    private static func synchsafe(_ d: Data, _ i: Int) -> Int { synchsafe([UInt8](d), i) }
    private static func synchsafe(_ b: [UInt8], _ i: Int) -> Int {
        guard i + 4 <= b.count else { return 0 }
        return Int(b[i] & 0x7F) << 21 | Int(b[i + 1] & 0x7F) << 14 | Int(b[i + 2] & 0x7F) << 7 | Int(b[i + 3] & 0x7F)
    }
    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        guard i + 4 <= b.count else { return 0 }
        return Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }

    /// Reads a terminated string; returns it and the index after the terminator.
    private static func string(_ b: [UInt8], from: Int, encoding: UInt8) -> (String, Int) {
        let wide = encoding == 1 || encoding == 2
        var end = from
        if wide {
            while end + 1 < b.count, !(b[end] == 0 && b[end + 1] == 0) { end += 2 }
        } else {
            while end < b.count, b[end] != 0 { end += 1 }
        }
        let next = min(b.count, end + (wide ? 2 : 1))
        return (decode(Array(b[from..<min(end, b.count)]), encoding: encoding), next)
    }

    private static func decode(_ bytes: [UInt8], encoding: UInt8) -> String {
        let data = Data(bytes)
        switch encoding {
        case 0: return String(data: data, encoding: .isoLatin1) ?? ""
        case 1:
            if bytes.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
            if bytes.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
            return String(data: data, encoding: .utf16) ?? ""
        case 2: return String(data: data, encoding: .utf16BigEndian) ?? ""
        default: return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private static func unsyncedText(_ f: [UInt8]) -> String? {
        guard f.count > 4 else { return nil }
        let enc = f[0]
        let (_, after) = string(f, from: 4, encoding: enc)
        guard after <= f.count else { return nil }
        let (text, _) = string(f, from: after, encoding: enc)
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func syncedLines(_ f: [UInt8]) -> [MusicLyricLine]? {
        guard f.count > 7 else { return nil }
        let enc = f[0], format = f[4]
        // Only millisecond stamps can be placed without the audio's frame table.
        guard format == 2 else { return nil }
        let (_, after) = string(f, from: 6, encoding: enc)
        var pos = after
        var out: [MusicLyricLine] = []
        while pos < f.count {
            let (text, next) = string(f, from: pos, encoding: enc)
            guard next + 4 <= f.count else { break }
            let ms = be32(f, next)
            out.append(MusicLyricLine(timeMs: Int64(ms), text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
            pos = next + 4
        }
        return out.isEmpty ? nil : out.sorted { $0.timeMs < $1.timeMs }
    }
}
