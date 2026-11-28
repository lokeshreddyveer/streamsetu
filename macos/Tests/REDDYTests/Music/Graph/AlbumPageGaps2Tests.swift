import Testing
import Foundation
@testable import REDDY

@Suite("Album page gaps 2") struct AlbumPageGaps2Tests {
    private func track(_ id: String) -> MusicTrack {
        MusicTrack(id: id, providerID: "p", title: id, durationMs: 1000, trackNumber: nil, discNumber: nil, artists: [])
    }

    @Test func continuationQueuesOnlyTheSongsAfterTheCurrentOne() {
        let t = [track("a"), track("b"), track("c")]
        let uid0 = t[0].uid, uid1 = t[1].uid, uid2 = t[2].uid
        #expect(MusicAlbumPlayback.continuation(t, currentUID: uid0).map(\.uid) == [uid1, uid2])
        #expect(MusicAlbumPlayback.continuation(t, currentUID: uid1).map(\.uid) == [uid2])
    }

    @Test func continuationIsEmptyAtTheLastSongOrForAForeignSong() {
        let t = [track("a"), track("b")]
        let last = t[1].uid
        #expect(MusicAlbumPlayback.continuation(t, currentUID: last).isEmpty)
        #expect(MusicAlbumPlayback.continuation(t, currentUID: "nope").isEmpty)
    }
}
