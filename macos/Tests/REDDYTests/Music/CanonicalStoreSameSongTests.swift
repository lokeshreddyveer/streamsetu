import Foundation
import Testing
@testable import REDDY

/// Two different songs with one title (and no known singer) must never share a cached match: the second would be handed the first song's playable copy.
@Suite("Catalogue cache: one title is not one song") struct CanonicalStoreSameSongTests {
    private func tempFile() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("canon-\(UUID().uuidString).json") }
    private func row(_ title: String, ms: Int64, artist: String? = nil, id: String) -> MusicTrack {
        MusicTrack(id: id, providerID: "graph", title: title, durationMs: ms, artists: artist.map { [MusicArtistRef(id: "", name: $0)] } ?? [])
    }
    private func matched(_ t: MusicTrack, copy: String) -> MusicCanonicalTrack {
        var c = MusicCatalogCanon.make(from: t)
        c.twins = [MusicCanonicalTwin(providerID: "ytmusic", sourceID: copy, title: t.title, artist: nil, score: 0.9)]
        c.seenOn = [t.uid]
        return c
    }

    @Test func aRowWithNoSingerAndAnotherLengthDoesNotGetTheFirstSongsCopy() {
        let store = MusicCanonicalStore(file: tempFile())
        let a = row("Tere Bina", ms: 200_000, id: "a")
        let b = row("Tere Bina", ms: 310_000, id: "b")
        _ = store.put(matched(a, copy: "copyA"))
        let hit = store.canonical(for: b)
        #expect(hit == nil, "a different song of the same title is not the cached one")
        #expect(store.canonical(for: a)?.twins.first?.sourceID == "copyA", "the same row still finds its own copy")
    }

    @Test func aSecondSongUnderTheSameKeyReplacesTheEntryInsteadOfInheritingItsCopies() {
        let store = MusicCanonicalStore(file: tempFile())
        let a = row("Tere Bina", ms: 200_000, artist: "Singer", id: "a")
        let b = row("Tere Bina", ms: 310_000, artist: "Singer", id: "b")
        _ = store.put(matched(a, copy: "copyA"))
        var unmatchedB = MusicCatalogCanon.make(from: b)
        unmatchedB.seenOn = [b.uid]
        let merged = store.put(unmatchedB)
        #expect(merged.twins.isEmpty, "B must not inherit A's playable copy")
        #expect(store.canonical(for: a) == nil || store.canonical(for: a)?.twins.isEmpty == true)
    }

    @Test func theSameSongWithClosePlayingTimesIsStillTheSameEntry() {
        let store = MusicCanonicalStore(file: tempFile())
        let a = row("Tere Bina", ms: 200_000, artist: "Singer", id: "a")
        let again = row("Tere Bina", ms: 203_000, artist: "Singer", id: "a2")
        _ = store.put(matched(a, copy: "copyA"))
        #expect(store.canonical(for: again)?.twins.first?.sourceID == "copyA")
        #expect(MusicCanonicalStore.sameSong(MusicCatalogCanon.make(from: a), MusicCatalogCanon.make(from: again)))
    }
}
