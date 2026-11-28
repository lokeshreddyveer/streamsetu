import Testing
import Foundation
import ImageIO
@testable import REDDY

struct TagWriterTests {
    private let info = MusicTagInfo(title: "Song", artists: ["A", "B"], album: "Album", albumArtist: "A", trackNumber: 3, trackTotal: 12,
                                    discNumber: 1, year: "2019", isrc: "USRC17607839", coverJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]))

    /// Splits a tag into (frame id, payload) pairs.
    private func frames(_ tag: Data) -> [(String, Data)] {
        var out: [(String, Data)] = []
        let b = [UInt8](tag)
        var i = 10
        while i + 10 <= b.count {
            let id = String(decoding: b[i..<(i + 4)], as: UTF8.self)
            let n = Int(b[i + 4]) << 24 | Int(b[i + 5]) << 16 | Int(b[i + 6]) << 8 | Int(b[i + 7])
            out.append((id, Data(b[(i + 10)..<(i + 10 + n)])))
            i += 10 + n
        }
        return out
    }

    @Test func syncsafeSizeEncoding() {
        #expect(MusicTagWriter.syncsafe(0) == [0, 0, 0, 0])
        #expect(MusicTagWriter.syncsafe(127) == [0, 0, 0, 0x7F])
        #expect(MusicTagWriter.syncsafe(128) == [0, 0, 1, 0])
        #expect(MusicTagWriter.syncsafe(257) == [0, 0, 2, 1])
        #expect(MusicTagWriter.decodeSyncsafe([0, 0, 2, 1]) == 257)
        #expect(MusicTagWriter.decodeSyncsafe([0, 0, 0x80, 1]) == nil)
    }

    @Test func headerAndFrameLayout() {
        let tag = MusicTagWriter.id3Tag(for: info)
        let b = [UInt8](tag)
        #expect(Array(b[0..<6]) == [0x49, 0x44, 0x33, 3, 0, 0])
        #expect(MusicTagWriter.decodeSyncsafe(Array(b[6..<10])) == b.count - 10)
        let f = frames(tag)
        #expect(f.map(\.0) == ["TIT2", "TPE1", "TALB", "TPE2", "TRCK", "TPOS", "TYER", "TSRC", "APIC"])
        #expect(f[0].1 == Data([0x00]) + Data("Song".utf8) + Data([0x00]))
        #expect(f[1].1 == Data([0x00]) + Data("A, B".utf8) + Data([0x00]))
        #expect(f[4].1 == Data([0x00]) + Data("3/12".utf8) + Data([0x00]))
        #expect(f[5].1 == Data([0x00]) + Data("1".utf8) + Data([0x00]))
        // Frame flags are zero.
        #expect(Array(b[18..<20]) == [0, 0])
    }

    @Test func emptyFieldsAreSkipped() {
        let tag = MusicTagWriter.id3Tag(for: MusicTagInfo(title: "Only"))
        #expect(frames(tag).map(\.0) == ["TIT2"])
    }

    @Test func nonAsciiUsesUTF16WithBOM() {
        let tag = MusicTagWriter.id3Tag(for: MusicTagInfo(title: "Café ♪"))
        let p = frames(tag)[0].1
        #expect(Array(p.prefix(3)) == [0x01, 0xFF, 0xFE])
        #expect(Array(p.suffix(2)) == [0x00, 0x00])
        let body = p.dropFirst(3).dropLast(2)
        #expect(String(data: body, encoding: .utf16LittleEndian) == "Café ♪")
    }

    @Test func apicStructure() {
        let jpeg = Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])
        let p = MusicTagWriter.apicPayload(jpeg: jpeg)
        #expect(p == Data([0x00]) + Data("image/jpeg".utf8) + Data([0x00, 0x03, 0x00]) + jpeg)
    }

    @Test func existingTagIsReplaced() {
        let old = MusicTagWriter.id3Tag(for: MusicTagInfo(title: "Old title that is long enough"))
        let audio = Data([0xFF, 0xFB, 0x90, 0x00, 1, 2, 3, 4])
        #expect(MusicTagWriter.existingTagLength(in: old + audio) == old.count)
        #expect(MusicTagWriter.existingTagLength(in: audio) == 0)
        let fresh = MusicTagWriter.id3Tag(for: info)
        let merged = MusicTagWriter.replacingID3(in: old + audio, with: fresh)
        #expect(merged == fresh + audio)
        #expect(MusicTagWriter.replacingID3(in: audio, with: fresh) == fresh + audio)
    }

    @Test func formatDetectionUsesMagicBytes() {
        func d(_ b: [UInt8]) -> Data { Data(b + [UInt8](repeating: 0, count: 16)) }
        #expect(MusicTagWriter.detectFormat(head: Data("ID3".utf8) + d([3, 0])) == .mp3)
        #expect(MusicTagWriter.detectFormat(head: d([0xFF, 0xFB, 0x90])) == .mp3)
        #expect(MusicTagWriter.detectFormat(head: d([0xFF, 0xF1, 0x50])) == .unknown)
        #expect(MusicTagWriter.detectFormat(head: Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8)) == .mp4)
        #expect(MusicTagWriter.detectFormat(head: Data("OggS".utf8) + d([0])) == .ogg)
        #expect(MusicTagWriter.detectFormat(head: Data("fLaC".utf8) + d([0])) == .flac)
        #expect(MusicTagWriter.detectFormat(head: d([0x1A, 0x45, 0xDF, 0xA3])) == .webm)
        // Magic beats a misleading extension-style hint.
        #expect(MusicTagWriter.detectFormat(head: Data("OggS".utf8) + d([0]), container: "mp3", codec: "mp3") == .ogg)
        // Hints only apply when the bytes say nothing.
        #expect(MusicTagWriter.detectFormat(head: Data(), container: "m4a") == .mp4)
        #expect(MusicTagWriter.detectFormat(head: Data(), container: "weird", codec: "weird") == .unknown)
    }

    @Test func yearFromReleaseDate() {
        #expect(MusicTagInfo.year(from: "2019-05-17") == "2019")
        #expect(MusicTagInfo.year(from: "1999") == "1999")
        #expect(MusicTagInfo.year(from: "n/a") == nil)
        #expect(MusicTagInfo.year(from: nil) == nil)
    }

    @Test func infoFromTrack() {
        let album = MusicAlbumRef(id: "al", title: "Album", artists: [MusicArtistRef(id: "x", name: "Main")], releaseDate: "2020-01-02", totalTracks: 9)
        let t = MusicTrack(id: "1", providerID: "p", title: "T", durationMs: 1000, trackNumber: 2, discNumber: 1,
                           artists: [MusicArtistRef(id: "x", name: "Main"), MusicArtistRef(id: "y", name: "Guest")], album: album, isrc: "ISRC1")
        let i = MusicTagInfo(track: t)
        #expect(i.artists == ["Main", "Guest"])
        #expect(i.albumArtist == "Main")
        #expect(i.trackTotal == 9)
        #expect(i.year == "2020")
        #expect(i.isrc == "ISRC1")
    }

    @Test func fakeMP3RoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tagwriter-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = Data([0xFF, 0xFB, 0x90, 0x00] + (0..<64).map { UInt8($0) })
        let old = MusicTagWriter.id3Tag(for: MusicTagInfo(title: "Old"))
        let file = dir.appendingPathComponent(".partial-test")
        try (old + audio).write(to: file)
        let result = await MusicTagWriter.write(info, to: file, container: "mp3", codec: "mp3")
        #expect(result == .tagged)
        let out = try Data(contentsOf: file)
        let tag = MusicTagWriter.id3Tag(for: info)
        #expect(out == tag + audio)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
    }

    @Test func unsupportedFormatLeavesFileUntouched() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tagwriter-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = Data("OggS".utf8) + Data(repeating: 7, count: 40)
        try bytes.write(to: file)
        let result = await MusicTagWriter.write(info, to: file, container: "opus", codec: "opus")
        #expect(result == .unsupportedFormat)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func coverIsReencodedAsJPEG() throws {
        // A minimal valid PNG (1x1).
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        let jpeg = try #require(MusicTagWriter.jpegCover(from: png))
        #expect(Array(jpeg.prefix(2)) == [0xFF, 0xD8])
        #expect(MusicTagWriter.jpegCover(from: Data([1, 2, 3])) == nil)
    }
}
