import Testing
@testable import REDDY

@Suite("Album page gaps 4")
struct AlbumPageGaps4Tests {
    @Test func aFailedRefreshKeepsTheSongsOnScreen() {
        let keeps = MusicAlbumPageLogic.keepsCurrentSongs(failed: true, loadedCount: 0, currentCount: 9)
        #expect(keeps)
    }

    @Test func aFailedFirstLoadStillShowsTheError() {
        let keeps = MusicAlbumPageLogic.keepsCurrentSongs(failed: true, loadedCount: 0, currentCount: 0)
        #expect(!keeps)
    }

    @Test func aSuccessfulLoadAlwaysReplacesTheList() {
        let keeps = MusicAlbumPageLogic.keepsCurrentSongs(failed: false, loadedCount: 0, currentCount: 9)
        #expect(!keeps)
    }
}
