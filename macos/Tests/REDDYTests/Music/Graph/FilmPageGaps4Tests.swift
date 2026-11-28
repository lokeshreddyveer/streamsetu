import Foundation
import Testing
@testable import REDDY

@Suite("Film page gaps 4") struct FilmPageGaps4Tests {
    private func song(_ rec: String, album: String = "a1", dub: String? = nil) -> MusicFilmSongItem {
        MusicFilmSongItem(recording: MusicEntityID(kind: .recording, token: rec), title: rec, durationMs: 60_000, imageRef: nil, album: MusicEntityID(kind: .album, token: album), albumName: album, dubLanguage: dub,
                          disc: nil, position: nil, singers: [], providerUID: nil, releaseProviderUID: nil, status: .verified)
    }

    private func album(_ id: String, dub: String? = nil) -> MusicFilmAlbumItem {
        MusicFilmAlbumItem(album: MusicEntityID(kind: .album, token: id), name: id, year: nil, imageRef: nil, lang: nil, dubLanguage: dub, status: .verified, confidence: 1,
                           matchEvidence: [], via: nil, film: nil, filmName: nil)
    }

    @Test func theSameRecordingOnTwoAlbumsIsOneSong() {
        let all = [song("r1"), song("r2"), song("r1", album: "a2")]
        let unique = MusicFilmSongRules.uniqueRecordings(all)
        #expect(unique.map(\.title) == ["r1", "r2"])
        let sum = MusicFilmSoundtrackSummary.make(songs: all, albums: [album("a1"), album("a2")])
        #expect(sum?.songs == 2)
    }

    @Test func aDubLanguageBeyondTheFirstAlbumsIsStillWalked() {
        var albums = (1...7).map { album("o\($0)") }
        albums.append(album("d1", dub: "te"))
        albums.append(album("d2", dub: "te"))
        let walked = MusicFilmGraphReading.walked(albums)
        #expect(walked.count == MusicFilmGraphReading.albumsWithSongs + 1)
        #expect(walked.last?.album == MusicEntityID(kind: .album, token: "d1"))
    }

    @Test func sectionKeyCoreIsTheLoadersList() {
        #expect(MusicFilmSectionKey.core == MusicFilmLoaders.core.map(\.key))
    }
}
