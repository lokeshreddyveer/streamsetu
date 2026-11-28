import Foundation
import AVFoundation
import ImageIO

/// What gets written into a downloaded file. Built from the track alone so it can be tested without a file.
struct MusicTagInfo: Equatable, Sendable {
    var title: String
    var artists: [String]
    var album: String?
    var albumArtist: String?
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var year: String?
    var isrc: String?
    var coverJPEG: Data?

    init(title: String, artists: [String] = [], album: String? = nil, albumArtist: String? = nil, trackNumber: Int? = nil,
         trackTotal: Int? = nil, discNumber: Int? = nil, year: String? = nil, isrc: String? = nil, coverJPEG: Data? = nil) {
        self.title = title; self.artists = artists; self.album = album; self.albumArtist = albumArtist
        self.trackNumber = trackNumber; self.trackTotal = trackTotal; self.discNumber = discNumber
        self.year = year; self.isrc = isrc; self.coverJPEG = coverJPEG
    }

    init(track: MusicTrack, coverJPEG: Data? = nil) {
        let albumArtists = track.album?.artists.map(\.name).filter { !$0.isEmpty } ?? []
        self.init(
            title: track.title,
            artists: track.artists.map(\.name).filter { !$0.isEmpty },
            album: track.album?.title,
            albumArtist: albumArtists.isEmpty ? nil : albumArtists.joined(separator: ", "),
            trackNumber: track.trackNumber,
            trackTotal: track.album?.totalTracks,
            discNumber: track.discNumber,
            year: Self.year(from: track.album?.releaseDate),
            isrc: track.isrc,
            coverJPEG: coverJPEG)
    }

    /// The four-digit year at the start of "2019", "2019-05" or "2019-05-17".
    static func year(from date: String?) -> String? {
        guard let date else { return nil }
        let digits = date.prefix(4)
        return digits.count == 4 && digits.allSatisfy({ $0.isASCII && $0.isNumber }) ? String(digits) : nil
    }
}

enum MusicAudioFormat: Equatable, Sendable { case mp3, mp4, ogg, flac, webm, wav, unknown }

enum MusicTagResult: Equatable, Sendable {
    case tagged
    case unsupportedFormat
    case failed(String)
}

enum MusicTagWriter {
    static let maxCoverBytes = 3 * 1024 * 1024
    static let maxCoverPixels = 1000

    // MARK: format detection (pure)

    /// Magic bytes decide; the stream's container and codec names only break a tie when the bytes say nothing.
    static func detectFormat(head: Data, container: String = "", codec: String = "") -> MusicAudioFormat {
        let b = [UInt8](head.prefix(16))
        let c = container.lowercased(), k = codec.lowercased()
        func ascii(_ at: Int, _ s: String) -> Bool {
            let u = Array(s.utf8)
            return b.count >= at + u.count && Array(b[at..<(at + u.count)]) == u
        }
        if ascii(4, "ftyp") { return .mp4 }
        if ascii(0, "OggS") { return .ogg }
        if ascii(0, "fLaC") { return .flac }
        if ascii(0, "RIFF") { return .wav }
        if b.count >= 4, b[0] == 0x1A, b[1] == 0x45, b[2] == 0xDF, b[3] == 0xA3 { return .webm }
        if ascii(0, "ID3") {
            // An ID3 header in front of something that is not MP3 audio is left alone.
            if ["aac", "opus", "flac", "vorbis"].contains(k) { return .unknown }
            return .mp3
        }
        // MPEG audio frame sync: 11 set bits, layer bits not 00 (00 would be ADTS AAC).
        if b.count >= 2, b[0] == 0xFF, b[1] & 0xE0 == 0xE0, b[1] & 0x06 != 0 { return .mp3 }
        if b.count >= 2, b[0] == 0xFF, b[1] & 0xF0 == 0xF0 { return .unknown }
        switch c {
        case "m4a", "mp4", "alac": return .mp4
        case "mp3": return .mp3
        case "ogg", "opus": return .ogg
        case "webm": return .webm
        case "flac": return .flac
        default: break
        }
        if k == "mp3" { return .mp3 }
        return .unknown
    }

    // MARK: ID3v2.3 (pure)

    static func syncsafe(_ n: Int) -> [UInt8] {
        [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)]
    }

    static func decodeSyncsafe(_ b: [UInt8]) -> Int? {
        guard b.count == 4, b.allSatisfy({ $0 < 0x80 }) else { return nil }
        return Int(b[0]) << 21 | Int(b[1]) << 14 | Int(b[2]) << 7 | Int(b[3])
    }

    /// Total bytes of the ID3v2 tag(s) at the start of `data`, including header, padding and footer. 0 when there is none.
    static func existingTagLength(in data: Data) -> Int {
        var offset = 0
        let bytes = data
        while bytes.count - offset >= 10 {
            let s = bytes.startIndex + offset
            guard bytes[s] == 0x49, bytes[s + 1] == 0x44, bytes[s + 2] == 0x33, bytes[s + 3] != 0xFF,
                  let size = decodeSyncsafe([bytes[s + 6], bytes[s + 7], bytes[s + 8], bytes[s + 9]]) else { break }
            let footer = (bytes[s + 5] & 0x10) != 0 ? 10 : 0
            let total = 10 + size + footer
            guard offset + total <= bytes.count else { break }
            offset += total
        }
        return offset
    }

    private static func textPayload(_ s: String) -> Data {
        if s.unicodeScalars.allSatisfy({ $0.value < 0x80 }) {
            return Data([0x00]) + Data(s.utf8) + Data([0x00])
        }
        return Data([0x01, 0xFF, 0xFE]) + s.data(using: .utf16LittleEndian)! + Data([0x00, 0x00])
    }

    private static func frame(_ id: String, _ payload: Data) -> Data {
        var out = Data(id.utf8)
        let n = payload.count
        out.append(contentsOf: [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        out.append(contentsOf: [0x00, 0x00])
        out.append(payload)
        return out
    }

    private static func numberPair(_ n: Int?, _ total: Int?) -> String? {
        guard let n, n > 0 else { return nil }
        if let total, total > 0 { return "\(n)/\(total)" }
        return "\(n)"
    }

    /// The attached-picture frame: front cover, JPEG, no description.
    static func apicPayload(jpeg: Data) -> Data {
        Data([0x00]) + Data("image/jpeg".utf8) + Data([0x00, 0x03, 0x00]) + jpeg
    }

    /// A complete ID3v2.3 tag with no padding and no unsynchronisation.
    static func id3Tag(for info: MusicTagInfo) -> Data {
        var frames = Data()
        func text(_ id: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            frames.append(frame(id, textPayload(value)))
        }
        text("TIT2", info.title)
        text("TPE1", info.artists.isEmpty ? nil : info.artists.joined(separator: ", "))
        text("TALB", info.album)
        text("TPE2", info.albumArtist)
        text("TRCK", numberPair(info.trackNumber, info.trackTotal))
        text("TPOS", numberPair(info.discNumber, nil))
        text("TYER", info.year)
        text("TSRC", info.isrc)
        if let cover = info.coverJPEG, !cover.isEmpty { frames.append(frame("APIC", apicPayload(jpeg: cover))) }
        var out = Data("ID3".utf8)
        out.append(contentsOf: [0x03, 0x00, 0x00])
        out.append(contentsOf: syncsafe(frames.count))
        out.append(frames)
        return out
    }

    /// The audio with any ID3v2 tag already at its start dropped and `tag` put in front.
    static func replacingID3(in audio: Data, with tag: Data) -> Data {
        tag + audio.dropFirst(existingTagLength(in: audio))
    }

    // MARK: cover art

    /// Re-encodes any image ImageIO can read as a JPEG no larger than 1000 px on its longest side.
    static func jpegCover(from data: Data) -> Data? {
        guard data.count <= maxCoverBytes, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let image: CGImage?
        if max(w, h) > maxCoverPixels {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxCoverPixels] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// The best thumbnail the provider already exposes for this track (its own, else its album's), as a JPEG. Nil on any problem.
    static func fetchCover(for track: MusicTrack, http: MusicHTTP) async -> Data? {
        let thumbs = track.thumbnails.isEmpty ? (track.album?.thumbnails ?? []) : track.thumbnails
        guard let s = thumbs.best(minSide: 600), let url = URL(string: s) else { return nil }
        guard let data = try? await http.get(url), data.count <= maxCoverBytes else { return nil }
        return jpegCover(from: data)
    }

    // MARK: writing

    /// Writes the tags into `file` in place (through a temporary file and an atomic swap). The file is never damaged on failure.
    static func write(_ info: MusicTagInfo, to file: URL, container: String = "", codec: String = "") async -> MusicTagResult {
        let head = readHead(file)
        switch detectFormat(head: head, container: container, codec: codec) {
        case .mp3: return writeMP3(info, to: file)
        case .mp4: return await writeMP4(info, to: file)
        default: return .unsupportedFormat
        }
    }

    private static func readHead(_ url: URL) -> Data {
        guard let h = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? h.close() }
        return (try? h.read(upToCount: 16)) ?? Data()
    }

    private static func writeMP3(_ info: MusicTagInfo, to file: URL) -> MusicTagResult {
        let fm = FileManager.default
        let temp = file.deletingLastPathComponent().appendingPathComponent(".tagged-" + UUID().uuidString)
        do {
            let audio = try Data(contentsOf: file, options: .alwaysMapped)
            let skip = existingTagLength(in: audio)
            guard fm.createFile(atPath: temp.path, contents: nil) else { return .failed("Could not create a temporary file.") }
            let out = try FileHandle(forWritingTo: temp)
            try out.write(contentsOf: id3Tag(for: info))
            try out.write(contentsOf: audio.dropFirst(skip))
            try out.close()
            _ = try fm.replaceItemAt(file, withItemAt: temp)
            return .tagged
        } catch {
            try? fm.removeItem(at: temp)
            return .failed("Could not write the tags.")
        }
    }

    // MARK: MP4 / M4A

    private final class ExportBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ s: AVAssetExportSession) { session = s }
    }

    private static func metadataItem(_ id: AVMetadataIdentifier, _ value: Any, type: String? = nil) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = id
        item.value = value as? NSCopying & NSObjectProtocol
        if let type { item.dataType = type }
        item.extendedLanguageTag = "und"
        return item
    }

    /// iTunes atoms for the same fields the MP3 path writes. trkn and disk are fixed binary layouts.
    static func mp4Metadata(for info: MusicTagInfo) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        let text = kCMMetadataBaseDataType_UTF8 as String
        items.append(metadataItem(.iTunesMetadataSongName, info.title, type: text))
        if !info.artists.isEmpty { items.append(metadataItem(.iTunesMetadataArtist, info.artists.joined(separator: ", "), type: text)) }
        if let a = info.album, !a.isEmpty { items.append(metadataItem(.iTunesMetadataAlbum, a, type: text)) }
        if let a = info.albumArtist, !a.isEmpty { items.append(metadataItem(.iTunesMetadataAlbumArtist, a, type: text)) }
        if let y = info.year { items.append(metadataItem(.iTunesMetadataReleaseDate, y, type: text)) }
        func be16(_ n: Int) -> [UInt8] { [UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] }
        let raw = kCMMetadataBaseDataType_RawData as String
        if let n = info.trackNumber, n > 0 {
            let d = Data([0, 0] + be16(n) + be16(info.trackTotal ?? 0) + [0, 0])
            items.append(metadataItem(.iTunesMetadataTrackNumber, d, type: raw))
        }
        if let n = info.discNumber, n > 0 {
            let d = Data([0, 0] + be16(n) + be16(0))
            items.append(metadataItem(.iTunesMetadataDiscNumber, d, type: raw))
        }
        if let c = info.coverJPEG, !c.isEmpty {
            items.append(metadataItem(.iTunesMetadataCoverArt, c, type: kCMMetadataBaseDataType_JPEG as String))
        }
        return items
    }

    private static func writeMP4(_ info: MusicTagInfo, to file: URL) async -> MusicTagResult {
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        let id = UUID().uuidString
        // The session wants a recognisable extension; the download itself has none, so work on a link to it.
        let source = dir.appendingPathComponent(".tagsrc-" + id + ".m4a")
        let output = dir.appendingPathComponent(".tagged-" + id + ".m4a")
        defer { try? fm.removeItem(at: source); try? fm.removeItem(at: output) }
        do {
            do { try fm.linkItem(at: file, to: source) } catch { try fm.copyItem(at: file, to: source) }
            let asset = AVURLAsset(url: source)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                return .failed("This file cannot be re-tagged.")
            }
            session.metadata = mp4Metadata(for: info)
            let box = ExportBox(session)
            if #available(macOS 15.0, iOS 18.0, *) {
                try await box.session.export(to: output, as: .m4a)
            } else {
                box.session.outputURL = output
                box.session.outputFileType = .m4a
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    box.session.exportAsynchronously { c.resume() }
                }
                guard box.session.status == .completed else { return .failed("Could not write the tags.") }
            }
            guard fm.fileExists(atPath: output.path) else { return .failed("Could not write the tags.") }
            _ = try fm.replaceItemAt(file, withItemAt: output)
            return .tagged
        } catch {
            return .failed("Could not write the tags.")
        }
    }
}
