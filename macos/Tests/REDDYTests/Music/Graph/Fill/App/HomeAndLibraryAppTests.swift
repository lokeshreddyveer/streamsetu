import Foundation
import Testing
@testable import REDDY

// App-level tests (they need the app target: MusicLibrary, MusicHub). They are not part of the throwaway package; they run with the
// app's own test target after the patches are applied.

@MainActor
@Suite struct HomeAndLibraryAppTests {
    private func lib() throws -> (MusicLibrary, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fill-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (MusicLibrary(directory: dir, debounce: .milliseconds(10)), dir)
    }
    private func track(_ n: Int) -> MusicTrack { MusicTrack(id: "t\(n)", providerID: "p", title: "Song \(n)", durationMs: 1000, artists: []) }

    @Test func topTracksMemoMatchesAFreshRankingAndTracksChanges() throws {
        let (l, dir) = try lib(); defer { try? FileManager.default.removeItem(at: dir) }
        for _ in 0..<3 { l.recordPlay(track(1), playedMs: 40_000) }
        for _ in 0..<5 { l.recordPlay(track(2), playedMs: 40_000) }
        l.recordPlay(track(3), playedMs: 40_000)
        #expect(l.topTracks(limit: 2).map(\.uid) == ["p:t2", "p:t1"])
        #expect(l.topTracks(limit: 1).map(\.uid) == ["p:t2"])           // from the memo
        for _ in 0..<4 { l.recordPlay(track(3), playedMs: 40_000) }       // history changed: the memo must not serve the old ranking
        #expect(l.topTracks(limit: 1).map(\.uid) == ["p:t3"])
        #expect(l.topTracks(limit: 0).isEmpty)
    }

    @Test func replaceTracksRestoresAPlaylistExactly() throws {
        let (l, dir) = try lib(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = l.createPlaylist(name: "Mine", tracks: (1...5).map(track))
        let before = l.playlist(id: p.id)!.tracks
        l.remove(at: IndexSet([1, 3]), from: p.id)
        #expect(l.playlist(id: p.id)!.tracks.count == 3)
        l.replaceTracks(before, in: p.id)
        #expect(l.playlist(id: p.id)!.tracks.map(\.uid) == before.map(\.uid))
        l.move(from: IndexSet(integer: 0), to: 5, in: p.id)
        #expect(l.playlist(id: p.id)!.tracks.map(\.uid) != before.map(\.uid))
        l.replaceTracks(before, in: p.id)
        #expect(l.playlist(id: p.id)!.tracks.map(\.uid) == before.map(\.uid))
    }

    @Test func fillTileMergeKeepsPositionsAndAppendsNew() {
        func tile(_ n: String, art: String? = nil) -> MusicFillTile {
            MusicFillTile(entity: .provisional(kind: .person, name: n), kind: .singer, title: n, subtitle: "", imageRef: art, role: .singer, year: nil)
        }
        let old = [MusicFillShelf(id: "a", title: "A", reason: "r", scope: .starter, tiles: [tile("x"), tile("y")])]
        let new = [MusicFillShelf(id: "a", title: "A", reason: "r", scope: .starter, tiles: [tile("z"), tile("y", art: "u"), tile("x", art: "v")]), MusicFillShelf(id: "b", title: "B", reason: "r", scope: .related, tiles: [tile("q")])]
        let merged = MusicFillModel.merge(old: old, new: new)
        #expect(merged.map(\.id) == ["a", "b"])
        #expect(merged[0].tiles.map(\.title) == ["x", "y", "z"])
        #expect(merged[0].tiles[0].imageRef == "v" && merged[0].tiles[1].imageRef == "u")
    }

    @Test func linkMenuItemsNeverContainVariousArtists() {
        var t = MusicTrack(id: "1", providerID: "p", title: "S", durationMs: 1, artists: [MusicArtistRef(id: "va", name: "Various Artists"), MusicArtistRef(id: "a1", name: "Mukesh")])
        t.album = MusicAlbumRef(id: "al", title: "Awaara", artists: [])
        let items = MusicTrackLinkItems.goTo(track: t, context: nil)
        #expect(items.contains { $0.title == "Go to Mukesh" } && !items.contains { $0.title.contains("Various") })
        #expect(items.first?.title == "Go to Song")
        #expect(items.contains { $0.title == "Go to Awaara" })
    }
}
