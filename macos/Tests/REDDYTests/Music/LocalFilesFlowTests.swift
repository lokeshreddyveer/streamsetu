import Foundation
import AVFoundation
import Testing
@testable import REDDY

// The Local files source end to end on a folder of tiny silent files made here: scan, tags, search, playing and matching a song from another source.

private func tempFolder() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("local-flow-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u.resolvingSymlinksInPath()
}

/// Silence as 16-bit mono PCM in a WAV file. The default is 31 seconds because the scanner leaves out anything under 30 (sound effects, memos).
private func writeSilentWAV(_ url: URL, seconds: Double = 31) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8000.0, AVNumberOfChannelsKey: 1,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
    let frames = AVAudioFrameCount(8000 * seconds)
    guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw MusicError.network("no buffer") }
    buffer.frameLength = frames
    try file.write(from: buffer)
}

private final class ExportBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ s: AVAssetExportSession) { session = s }
}

/// An AAC file with title, artist and album tags, made by exporting a silent WAV.
private func writeTaggedM4A(_ url: URL, title: String, artist: String, album: String) async throws {
    let wav = url.deletingPathExtension().appendingPathExtension("src.wav")
    try writeSilentWAV(wav, seconds: 31)
    defer { try? FileManager.default.removeItem(at: wav) }
    guard let session = AVAssetExportSession(asset: AVURLAsset(url: wav), presetName: AVAssetExportPresetAppleM4A) else { throw MusicError.network("no export") }
    func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let m = AVMutableMetadataItem()
        m.identifier = id; m.value = value as NSString; m.extendedLanguageTag = "und"
        return m
    }
    session.outputURL = url
    session.outputFileType = .m4a
    session.metadata = [item(.commonIdentifierTitle, title), item(.commonIdentifierArtist, artist), item(.commonIdentifierAlbumName, album)]
    let box = ExportBox(session)
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in box.session.exportAsynchronously { c.resume() } }
    guard box.session.status == .completed else { throw MusicError.network("export failed: \(String(describing: box.session.error))") }
}

@Suite struct LocalFilesFlowTests {
    private struct Fixture {
        let root: URL, store: LocalLibraryStore, provider: LocalFilesProvider
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func fixture() async throws -> Fixture {
        let root = tempFolder()
        let music = root.appendingPathComponent("music", isDirectory: true)
        try writeSilentWAV(music.appendingPathComponent("Band A - First Song.wav"))
        try writeSilentWAV(music.appendingPathComponent("Some Album/01 - Opening Track.wav"))
        try writeSilentWAV(music.appendingPathComponent("Some Album/02 - Closing Track.wav"))
        try await writeTaggedM4A(music.appendingPathComponent("Tagged.m4a"), title: "Tagged Song", artist: "Tag Artist", album: "Tag Album")
        try writeSilentWAV(music.appendingPathComponent("Beep.wav"), seconds: 1)
        try writeSilentWAV(music.appendingPathComponent("Ringtones/Marimba.wav"))
        FileManager.default.createFile(atPath: music.appendingPathComponent("notes.txt").path, contents: Data("not audio".utf8))
        FileManager.default.createFile(atPath: music.appendingPathComponent(".hidden.wav").path, contents: Data())
        let store = LocalLibraryStore(directory: root.appendingPathComponent("state", isDirectory: true))
        _ = await store.addFolder(music)
        await store.scan()
        return Fixture(root: root, store: store, provider: LocalFilesProvider(store: store))
    }

    @Test func scanIndexesOnlyMusicAndReadsNamesAndTags() async throws {
        let f = try await fixture(); defer { f.remove() }
        let idx = await f.store.currentIndex()
        #expect(idx.entries.count == 4)
        let byTitle = Dictionary(uniqueKeysWithValues: idx.entries.map { ($0.title, $0) })
        #expect(byTitle["First Song"]?.artist == "Band A")
        #expect(byTitle["Opening Track"]?.album == "Some Album" && byTitle["Opening Track"]?.trackNumber == 1 && byTitle["Closing Track"]?.trackNumber == 2)
        #expect(byTitle["Tagged Song"]?.artist == "Tag Artist" && byTitle["Tagged Song"]?.album == "Tag Album")
        #expect(byTitle["First Song"].map { $0.durationMs >= 30_900 && $0.durationMs <= 31_100 } == true)
        #expect(byTitle["Beep"] == nil && byTitle["Marimba"] == nil)
        let info = await f.store.snapshot()
        #expect(info.count == 1 && info[0].trackCount == 4 && info[0].lastScan != nil)
    }

    @Test func searchFindsTracksAlbumsAndArtists() async throws {
        let f = try await fixture(); defer { f.remove() }
        #expect(try await f.provider.searchTracks("closing", page: nil).items.map(\.title) == ["Closing Track"])
        #expect(try await f.provider.searchTracks("tag artist", page: nil).items.map(\.title) == ["Tagged Song"])
        #expect(try await f.provider.searchAlbums("some album", page: nil).items.first?.totalTracks == 2)
        #expect(try await f.provider.searchArtists("tag", page: nil).items.map(\.name) == ["Tag Artist"])
        #expect(try await f.provider.searchTracks("nothing like this", page: nil).items.isEmpty)
        let album = try #require(try await f.provider.searchAlbums("some album", page: nil).items.first)
        #expect(try await f.provider.albumTracks(id: album.id, page: nil).items.map(\.title) == ["Opening Track", "Closing Track"])
    }

    @Test func aLocalTrackPlaysFromItsOwnFile() async throws {
        let f = try await fixture(); defer { f.remove() }
        let t = try #require(try await f.provider.searchTracks("first song", page: nil).items.first)
        let stream = try #require(t.directStreams?.first)
        let url = try #require(URL(string: stream.url))
        #expect(url.isFileURL && FileManager.default.fileExists(atPath: url.path) && stream.container == "wav")
        let sources = try await f.provider.sources(for: t)
        #expect(sources.count == 1 && sources[0].confidence == 1 && sources[0].streams?.first?.url == stream.url)
        // The file really decodes: its length matches what the index recorded.
        let asset = AVURLAsset(url: url)
        let seconds = try await asset.load(.duration).seconds
        #expect(abs(seconds * 1000 - Double(t.durationMs)) < 50)
    }

    @Test func aSongFromAnotherSourceIsAnsweredByTheMatchingFile() async throws {
        let f = try await fixture(); defer { f.remove() }
        let spotify = MusicTrack(id: "sp1", providerID: "spotify", title: "First Song", durationMs: 1000, artists: [MusicArtistRef(id: "", name: "Band A")])
        let hits = try await f.provider.sources(for: spotify)
        #expect(hits.count == 1 && hits[0].confidence == 0.9 && hits[0].streams?.isEmpty == false)
        let other = MusicTrack(id: "sp2", providerID: "spotify", title: "First Song", durationMs: 1000, artists: [MusicArtistRef(id: "", name: "Someone Else")])
        #expect(try await f.provider.sources(for: other).isEmpty)
    }

    @Test func aRescanSeesNewAndDeletedFilesAndRemovedIDsAreReported() async throws {
        let f = try await fixture(); defer { f.remove() }
        let music = f.root.appendingPathComponent("music")
        try writeSilentWAV(music.appendingPathComponent("Band B - Late Addition.wav"))
        try FileManager.default.removeItem(at: music.appendingPathComponent("Band A - First Song.wav"))
        // A person changes a folder seconds after the last scan, not milliseconds. The scanner skips a directory whose modified time is within 5 ms of the one it
        // stored, so the change is stamped later explicitly instead of depending on how fast this test runs after the fixture's scan.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3)], ofItemAtPath: music.path)
        final class Removed: @unchecked Sendable { var ids: [String] = []; let lock = NSLock(); func add(_ x: [String]) { lock.withLock { ids += x } } }
        let removed = Removed()
        await f.store.scan(removed: { removed.add($0) })
        let titles = Set(await f.store.currentIndex().entries.map(\.title))
        #expect(titles == ["Late Addition", "Opening Track", "Closing Track", "Tagged Song"])
        #expect(removed.ids.count == 1)
    }

    @Test func aMissingFolderDegradesToAnEmptyLibraryNotAnError() async throws {
        let root = tempFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalLibraryStore(directory: root.appendingPathComponent("state"))
        let p = LocalFilesProvider(store: store)
        #expect(try await p.searchTracks("anything", page: nil).items.isEmpty)
        #expect(try await p.sources(for: MusicTrack(id: "x", providerID: "spotify", title: "T", durationMs: 1, artists: [])).isEmpty)
        await #expect(throws: MusicError.notFound) { _ = try await p.track(id: "nope") }
        #expect(p.capabilities.contains(.audio) && !p.capabilities.contains(.library) && p.info.requiresSignIn == false)
    }
}
