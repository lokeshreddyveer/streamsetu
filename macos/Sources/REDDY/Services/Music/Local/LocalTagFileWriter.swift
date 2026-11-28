import Foundation
import AVFoundation

// Writing a person's own edits into their audio files: title, artist, album, album artist, genre, year and (MP3) track and disc numbers. Unlike the writer for
// downloads, this one KEEPS everything it is not asked to change (cover art, lyrics, comments, replay gain), changes only the fields that were edited, and
// goes through a temporary file with an atomic swap, so a failure never damages the file. MP3 (ID3v2.3 and v2.4) and M4A are supported; other formats say so.

enum LocalTagFileWriter {
    // MARK: ID3

    private static func textPayload(_ s: String) -> Data { Data([0x01, 0xFF, 0xFE]) + (s.data(using: .utf16LittleEndian) ?? Data()) + Data([0x00, 0x00]) }

    private static func text(of f: MusicID3LyricFrames.Frame) -> String {
        guard let enc = f.payload.first else { return "" }
        let body = Array(f.payload.dropFirst())
        switch enc {
        case 0: return String(decoding: body, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        case 1:
            let d = Data(body)
            if body.starts(with: [0xFE, 0xFF]) { return (String(data: d.dropFirst(2), encoding: .utf16BigEndian) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\0")) }
            if body.starts(with: [0xFF, 0xFE]) { return (String(data: d.dropFirst(2), encoding: .utf16LittleEndian) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\0")) }
            return (String(data: d, encoding: .utf16) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        case 2: return (String(data: Data(body), encoding: .utf16BigEndian) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        default: return String(decoding: body, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
    }

    /// "3/12" with a new number n becomes "n/12": the total stays.
    static func numberPair(setting n: Int, existing: String?) -> String {
        let total = existing?.split(separator: "/").dropFirst().first.map(String.init)
        return total.map { "\(n)/\($0)" } ?? "\(n)"
    }

    /// The tag with the edited fields replaced and every other frame kept. Nil for a tag this cannot rewrite safely (v2.2, or unsynchronisation).
    static func replacingText(inTag tag: Data?, with p: LocalEntryPatch) -> Data? {
        var version = 3
        var frames: [MusicID3LyricFrames.Frame] = []
        if let tag, !tag.isEmpty {
            guard let parsed = MusicID3LyricFrames.frames(inTag: tag) else { return nil }
            if [UInt8](tag)[5] & 0x80 != 0 { return nil }
            version = parsed.version
            frames = parsed.frames
        }
        func existing(_ id: String) -> String? { frames.first { $0.id == id }.map(text(of:)) }
        var set: [String: String] = [:]
        func put(_ id: String, _ v: String?) { if let v = v?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { set[id] = v } }
        put("TIT2", p.title); put("TPE1", p.artist); put("TALB", p.album); put("TPE2", p.albumArtist); put("TCON", p.genre)
        var drop = Set(set.keys)
        if let y = p.year, (1000...2999).contains(y) { set[version >= 4 ? "TDRC" : "TYER"] = String(y); drop.formUnion(["TYER", "TDRC", "TDAT"]) }
        if let n = p.trackNumber, n > 0 { set["TRCK"] = numberPair(setting: n, existing: existing("TRCK")); drop.insert("TRCK") }
        if let n = p.discNumber, n > 0 { set["TPOS"] = numberPair(setting: n, existing: existing("TPOS")); drop.insert("TPOS") }
        guard !set.isEmpty else { return tag }
        var body = Data()
        for f in frames where !drop.contains(f.id) { body += MusicID3LyricFrames.frame(f.id, Data(f.payload), version: version) }
        for (id, v) in set.sorted(by: { $0.key < $1.key }) { body += MusicID3LyricFrames.frame(id, textPayload(v), version: version) }
        var out = Data("ID3".utf8)
        out.append(contentsOf: [UInt8(version), 0, 0])
        out.append(contentsOf: MusicID3LyricFrames.syncsafe(body.count))
        return out + body
    }

    // MARK: files

    static func write(_ p: LocalEntryPatch, to file: URL) async -> MusicTagResult {
        guard !p.isEmpty else { return .tagged }
        let head = (try? FileHandle(forReadingFrom: file)).flatMap { h -> Data? in defer { try? h.close() }; return try? h.read(upToCount: 16) } ?? Data()
        switch MusicTagWriter.detectFormat(head: head, container: file.pathExtension) {
        case .mp3: return writeMP3(p, to: file)
        case .mp4: return await writeMP4(p, to: file)
        default: return .unsupportedFormat
        }
    }

    private static func writeMP3(_ p: LocalEntryPatch, to file: URL) -> MusicTagResult {
        let fm = FileManager.default
        let temp = file.deletingLastPathComponent().appendingPathComponent(".tags-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        do {
            let audio = try Data(contentsOf: file, options: .alwaysMapped)
            let skip = MusicTagWriter.existingTagLength(in: audio)
            let existing = skip > 0 ? Data(audio.prefix(skip)) : nil
            guard let tag = replacingText(inTag: existing, with: p) else { return .unsupportedFormat }
            guard fm.createFile(atPath: temp.path, contents: nil) else { return .failed("Could not create a temporary file.") }
            let out = try FileHandle(forWritingTo: temp)
            try out.write(contentsOf: tag)
            try out.write(contentsOf: audio.dropFirst(skip))
            try out.close()
            _ = try fm.replaceItemAt(file, withItemAt: temp)
            return .tagged
        } catch { return .failed("Could not write the tags.") }
    }

    private final class ExportBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ s: AVAssetExportSession) { session = s }
    }

    private static func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let m = AVMutableMetadataItem()
        m.identifier = id; m.value = value as NSString; m.dataType = kCMMetadataBaseDataType_UTF8 as String; m.extendedLanguageTag = "und"
        return m
    }

    /// The identifiers an edit replaces (the iTunes ones and their common twins), so no duplicate is left beside the new value.
    static func identifiers(replacedBy p: LocalEntryPatch) -> Set<AVMetadataIdentifier> {
        var s = Set<AVMetadataIdentifier>()
        if p.title != nil { s.formUnion([.iTunesMetadataSongName, .commonIdentifierTitle]) }
        if p.artist != nil { s.formUnion([.iTunesMetadataArtist, .commonIdentifierArtist]) }
        if p.album != nil { s.formUnion([.iTunesMetadataAlbum, .commonIdentifierAlbumName]) }
        if p.albumArtist != nil { s.insert(.iTunesMetadataAlbumArtist) }
        if p.genre != nil { s.formUnion([.iTunesMetadataUserGenre, .quickTimeMetadataGenre]) }
        if p.year != nil { s.formUnion([.iTunesMetadataReleaseDate, .commonIdentifierCreationDate]) }
        return s
    }

    private static func writeMP4(_ p: LocalEntryPatch, to file: URL) async -> MusicTagResult {
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        let id = UUID().uuidString
        let source = dir.appendingPathComponent(".tagsrc-" + id + ".m4a"), output = dir.appendingPathComponent(".tagged-" + id + ".m4a")
        defer { try? fm.removeItem(at: source); try? fm.removeItem(at: output) }
        do {
            do { try fm.linkItem(at: file, to: source) } catch { try fm.copyItem(at: file, to: source) }
            let asset = AVURLAsset(url: source)
            let existing = (try? await asset.load(.metadata)) ?? []
            let drop = identifiers(replacedBy: p)
            var items = existing.filter { i in i.identifier.map { !drop.contains($0) } ?? true }
            func add(_ id: AVMetadataIdentifier, _ v: String?) { if let v = v?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { items.append(item(id, v)) } }
            add(.iTunesMetadataSongName, p.title); add(.iTunesMetadataArtist, p.artist); add(.iTunesMetadataAlbum, p.album)
            add(.iTunesMetadataAlbumArtist, p.albumArtist); add(.iTunesMetadataUserGenre, p.genre)
            if let y = p.year, (1000...2999).contains(y) { add(.iTunesMetadataReleaseDate, String(y)) }
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return .failed("This file cannot be re-tagged.") }
            session.metadata = items
            let box = ExportBox(session)
            if #available(macOS 15.0, iOS 18.0, *) { try await box.session.export(to: output, as: .m4a) } else {
                box.session.outputURL = output
                box.session.outputFileType = .m4a
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in box.session.exportAsynchronously { c.resume() } }
                guard box.session.status == .completed else { return .failed("Could not write the tags.") }
            }
            guard fm.fileExists(atPath: output.path) else { return .failed("Could not write the tags.") }
            _ = try fm.replaceItemAt(file, withItemAt: output)
            return .tagged
        } catch { return .failed("Could not write the tags.") }
    }
}
