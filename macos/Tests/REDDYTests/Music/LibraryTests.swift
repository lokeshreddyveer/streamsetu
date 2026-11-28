import Testing
import Foundation
@testable import REDDY

@MainActor
struct LibraryTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("music-lib-" + UUID().uuidString, isDirectory: true)
    }
    private func track(_ id: String, provider: String = "audius", artist: String = "a1") -> MusicTrack {
        MusicTrack(id: id, providerID: provider, title: "T" + id, durationMs: 180_000, artists: [MusicArtistRef(id: artist, name: "Artist")])
    }
    private func lib(_ dir: URL) -> MusicLibrary { MusicLibrary(directory: dir, debounce: .milliseconds(10)) }

    @Test func persistenceRoundTrip() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = lib(dir)
        a.toggleLike(track("1"))
        let p = a.createPlaylist(name: "Mix", tracks: [track("2"), track("3")])
        a.recordPlay(track("1"), playedMs: 5000)
        a.settings.audioQuality = .lossless
        a.settings.consentDone = true
        a.toggleBlacklist(track("9"))
        a.flush()
        let b = lib(dir)
        #expect(b.liked.map(\.uid) == ["audius:1"])
        #expect(b.playlists.first?.id == p.id)
        #expect(b.playlists.first?.tracks.count == 2)
        #expect(b.history.count == 1)
        #expect(b.settings.audioQuality == .lossless && b.settings.consentDone)
        #expect(b.blacklist.contains("audius:9"))
    }

    @Test func settingsLiveInTheirOwnFile() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = lib(dir)
        a.settings.scrobbleEnabled = true
        a.flush()
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.json").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("liked.json").path))
    }

    @Test func corruptFileIsQuarantined() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("liked.json")
        try Data("not json {".utf8).write(to: url)
        let a = lib(dir)
        #expect(a.liked.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("liked.json.bad").path))
        a.toggleLike(track("1")); a.flush()
        #expect(lib(dir).liked.count == 1)
    }

    @Test func loadDedupesByUid() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = lib(dir)
        a.toggleLike(track("1")); a.flush()
        let store = MusicJSONStore<[MusicTrack]>(url: dir.appendingPathComponent("liked.json"))
        store.save([track("1"), track("2"), track("1")]); store.flush()
        #expect(lib(dir).liked.map(\.uid) == ["audius:1", "audius:2"])
    }

    @Test func sameIDDifferentProviderIsDistinct() {
        let a = lib(tempDir())
        a.toggleLike(track("1", provider: "audius")); a.toggleLike(track("1", provider: "jiosaavn"))
        #expect(a.liked.count == 2)
        a.clearAll()
    }

    @Test func historyKeepsUpToFiftyThousandPlays() {
        #expect(MusicLibrary.historyLimit == 50_000)
        let a = lib(tempDir())
        for i in 0..<120 { a.recordPlay(track(String(i)), playedMs: 1000) }
        #expect(a.history.count == 120)
        #expect(a.history.first?.track.id == "119")
        #expect(a.recent.count == MusicLibrary.recentLimit)
        a.clearAll()
    }

    @Test func recentIsUniqueAndTopTracksCounts() {
        let a = lib(tempDir())
        a.recordPlay(track("1"), playedMs: 1); a.recordPlay(track("2"), playedMs: 1)
        a.recordPlay(track("1"), playedMs: 1); a.recordPlay(track("3"), playedMs: 1)
        #expect(a.recent.map(\.id) == ["3", "1", "2"])
        #expect(a.topTracks(limit: 1).first?.id == "1")
        a.clearAll()
    }

    @Test func likeToggle() {
        let a = lib(tempDir())
        let t = track("1")
        #expect(!a.isLiked(t))
        a.toggleLike(t); #expect(a.isLiked(t))
        a.toggleLike(t); #expect(!a.isLiked(t))
        a.clearAll()
    }

    @Test func playlistEditInvariants() {
        let a = lib(tempDir())
        let p = a.createPlaylist(name: "  ", tracks: [track("1"), track("1"), track("2")])
        #expect(p.name == "Untitled playlist")
        #expect(p.tracks.count == 2)
        #expect(a.add([track("2"), track("3")], to: p.id) == 1)
        a.rename(p.id, to: " Road ")
        #expect(a.playlist(id: p.id)?.name == "Road")
        a.move(from: IndexSet(integer: 0), to: 3, in: p.id)
        #expect(a.playlist(id: p.id)?.tracks.map(\.id) == ["2", "3", "1"])
        a.move(from: IndexSet(integer: 2), to: 0, in: p.id)
        #expect(a.playlist(id: p.id)?.tracks.map(\.id) == ["1", "2", "3"])
        a.remove(at: IndexSet([0, 99]), from: p.id)
        #expect(a.playlist(id: p.id)?.tracks.map(\.id) == ["2", "3"])
        #expect(a.add([track("4")], to: UUID()) == 0)
        a.delete(p.id)
        #expect(a.playlists.isEmpty)
        a.clearAll()
    }

    @Test func playlistOrdering() {
        let a = lib(tempDir())
        let x = a.createPlaylist(name: "Beta"); let y = a.createPlaylist(name: "alpha", tracks: [track("1")])
        #expect(a.sortedPlaylists(.name).map(\.name) == ["alpha", "Beta"])
        #expect(a.sortedPlaylists(.size).first?.id == y.id)
        a.movePlaylists(from: IndexSet(integer: 1), to: 0)
        #expect(a.playlists.map(\.id) == [y.id, x.id])
        a.clearAll()
    }

    @Test func blacklistByTrackAndArtist() {
        let a = lib(tempDir())
        let t = track("1", artist: "art9")
        a.toggleBlacklist(artist: MusicArtistRef(id: "art9", name: "X"))
        #expect(a.isBlacklisted(t))
        a.toggleBlacklist(artist: MusicArtistRef(id: "art9", name: "X"))
        #expect(!a.isBlacklisted(t))
        a.toggleBlacklist(t); #expect(a.isBlacklisted(t))
        a.clearAll()
    }

    @Test func exportImportMerges() throws {
        let src = lib(tempDir())
        src.toggleLike(track("1")); src.toggleLike(track("2"))
        let p = src.createPlaylist(name: "P", tracks: [track("5"), track("6")])
        src.recordPlay(track("1"), playedMs: 10)
        let data = src.exportJSON()

        let dst = lib(tempDir())
        dst.toggleLike(track("2")); dst.toggleLike(track("7"))
        dst.recordPlay(track("8"), playedMs: 10)
        let s = try dst.importJSON(data)
        #expect(s.likedAdded == 1)
        #expect(Set(dst.liked.map(\.id)) == ["1", "2", "7"])
        #expect(dst.history.count == 2)
        #expect(dst.playlists.count == 1)
        let again = try dst.importJSON(data)
        #expect(again == MusicImportSummary())
        #expect(dst.playlist(id: p.id)?.tracks.count == 2)
        #expect(throws: (any Error).self) { try dst.importJSON(Data("nope".utf8)) }
        src.clearAll(); dst.clearAll()
    }

    @Test func clearAllDeletesFiles() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = lib(dir)
        a.toggleLike(track("1")); a.settings.consentDone = true; a.flush()
        a.clearAll()
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(left.isEmpty)
        #expect(a.liked.isEmpty && !a.settings.consentDone)
        #expect(lib(dir).liked.isEmpty)
    }

    @Test func settingsDecodeToleratesMissingAndUnknown() throws {
        let json = Data(#"{"audioQuality":"ultra","futureField":1}"#.utf8)
        let s = try JSONDecoder().decode(MusicSettings.self, from: json)
        #expect(s.audioQuality == .high && !s.consentDone && s.crossfadeSeconds == 0)
    }
}
