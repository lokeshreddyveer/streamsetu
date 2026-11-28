import Testing
import Foundation
@testable import REDDY

// Top-result scoring, artist relevance, song-row cells, the two-column balance, repeated covers, Home's genre tiles and the page frame's bottom room.

@Suite("Music search scoring and layout rules") struct SearchScoringTests {
    private let query = "ala vaikuntapuramlo"

    private func song(_ id: String, _ title: String, artists: [String] = ["Sid Sriram"], album: String? = nil, ms: Int64 = 200_000) -> MusicTrack {
        MusicTrack(id: id, providerID: "p", title: title, durationMs: ms, artists: artists.map { MusicArtistRef(id: $0, name: $0) },
                   album: album.map { MusicAlbumRef(id: "al", title: $0) })
    }
    private func album(_ id: String, _ title: String, artist: String = "Thaman S", covers: [MusicThumbnail] = []) -> MusicAlbum {
        MusicAlbum(id: id, providerID: "p", title: title, artists: [MusicArtistRef(id: artist, name: artist)], thumbnails: covers, totalTracks: 9)
    }
    private func artist(_ name: String, thumbs: [MusicThumbnail] = []) -> MusicArtist { MusicArtist(id: name, providerID: "p", name: name, thumbnails: thumbs) }
    private func playlist(_ id: String, _ name: String, cover: String) -> MusicPlaylist {
        MusicPlaylist(id: id, providerID: "p", name: name, thumbnails: [MusicThumbnail(url: cover, width: 300, height: 300)])
    }

    private var video: MusicTrack { song("v", "10 Max Full Episode | Ala Vaikuntapuramlo Remake", artists: ["10 Max"]) }
    private var film: MusicAlbum { album("a", "Ala Vaikunthapurramuloo") }
    private var samaja: MusicTrack { song("s", "Samajavaragamana", album: "Ala Vaikunthapurramuloo") }
    private var butta: MusicTrack { song("b", "Butta Bomma Song Making", artists: ["Thaman S"], album: "Ala Vaikunthapurramuloo") }

    // MARK: top result

    @Test func aMisspelledFilmTitleBeatsAnEpisodeVideo() {
        let pick = MusicTopResult.pick(query: query, tracks: [video, samaja, butta], artists: [], albums: [film], playlists: [])
        #expect(pick == .album(film))
        // Even without the album the song of the film is not outranked by the video.
        let ranked = MusicSearchScoring.rankTracks([video, butta, samaja], query: query)
        #expect(ranked.first?.id == "s")
        #expect(MusicSearchScoring.score(track: video, query: query) < MusicSearchScoring.score(album: film, query: query))
    }

    @Test func transliterationKeyBridgesTheSpelling() {
        #expect(MusicSearchScoring.similarity("vaikuntapuramlo", "Vaikunthapurramuloo") > 0.7)
        #expect(MusicSearchScoring.similarity("Ala Vaikuntapuramlo", "Ala Vaikuntapuramlo") == 1)
        #expect(MusicSearchScoring.similarity("ala vaikuntapuramlo", "Hello") < 0.4)
    }

    @Test func noiseWordsCountOnlyWhenTheQueryLacksThem() {
        #expect(MusicSearchScoring.noiseFound(query: query, title: "Butta Bomma Song Making") == ["making"])
        #expect(MusicSearchScoring.noiseFound(query: "butta bomma making", title: "Butta Bomma Song Making").isEmpty)
        for w in ["Full Episode", "Reaction", "Remake", "Lyrical Video", "Cover", "Jukebox", "Status", "Karaoke"] {
            #expect(!MusicSearchScoring.noiseFound(query: "song", title: "Song \(w)").isEmpty, Comment(rawValue: w))
        }
    }

    @Test func officialAndReleasedResultsGetALift() {
        let topic = song("t", "Samajavaragamana", artists: ["Sid Sriram - Topic"], album: "X")
        let plain = song("p", "Samajavaragamana", artists: ["Random Uploader"])
        #expect(MusicSearchScoring.score(track: topic, query: "samajavaragamana") > MusicSearchScoring.score(track: plain, query: "samajavaragamana"))
    }

    @Test func anExactArtistStillWinsOverAWeakSong() {
        let a = artist("Adele")
        let weak = song("1", "Something About Adele", artists: ["Cover Band"])
        #expect(MusicTopResult.pick(query: "adele", tracks: [weak], artists: [a], albums: [], playlists: []) == .artist(a))
        let hello = song("2", "Hello", artists: ["Adele"])
        #expect(MusicTopResult.pick(query: "hello", tracks: [hello], artists: [a], albums: [], playlists: []) == .track(hello))
    }

    // MARK: artists

    @Test func onlyCreditedOrSimilarArtistsRemain() {
        let all = ["AKLA", "Alan Gogoll", "Alan Salomon", "Thaman S", "Sid Sriram"].map { artist($0) }
        let shown = MusicArtistRelevance.relevant(all, query: query, tracks: [video, samaja, butta], albums: [film])
        #expect(shown.map(\.name) == ["Sid Sriram", "Thaman S"])
        #expect(MusicArtistRelevance.relevant(all, query: "zzzz qqqq", tracks: [], albums: []).isEmpty)
        #expect(MusicArtistRelevance.relevant([artist("Thaman S")], query: "thaman", tracks: [], albums: []).count == 1)
    }

    @Test func portraitsRejectPostersAndVideoFrames() {
        let wide = MusicThumbnail(url: "https://x.example/poster.jpg", width: 1280, height: 540)
        let frame = MusicThumbnail(url: "https://i.ytimg.com/vi/abc/hqdefault.jpg", width: 480, height: 480)
        let face = MusicThumbnail(url: "https://x.example/face.jpg", width: 400, height: 400)
        let unknown = MusicThumbnail(url: "https://x.example/u.jpg")
        #expect(MusicArtistPortrait.portraits([wide, frame, face, unknown]) == [face, unknown])
        #expect(MusicArtistPortrait.portraits([wide, frame]).isEmpty)
        #expect(MusicArtistPortrait.initials("Thaman S") == "TS")
        #expect(MusicArtistPortrait.initials("Adele") == "A")
    }

    // MARK: song row cells

    @Test func aDateOrCountIsNeverAnArtist() {
        for s in ["Jan 12, 2023", "12 Jan 2023", "2023-01-12", "3 years ago", "1.2M views", "12,345 views", "2.3M", "Premiered Jan 5, 2023"] {
            #expect(MusicTrackCells.looksLikeDateOrCount(s), Comment(rawValue: s))
        }
        for s in ["Adele", "1975", "Sid Sriram", "Thaman S", "The 2nd Law", "M.I.A."] {
            #expect(!MusicTrackCells.looksLikeDateOrCount(s), Comment(rawValue: s))
        }
        let t = song("x", "A video", artists: ["Jan 12, 2023", "Real Channel"], ms: 0)
        #expect(MusicTrackCells.artists(of: t).map(\.name) == ["Real Channel"])
        #expect(MusicTrackCells.artistLine(of: song("y", "v", artists: ["Jan 12, 2023"])) == "")
    }

    @Test func columnsAppearOnlyWhenARowHasData() {
        let rows = [song("1", "A", artists: ["1.2M views"], ms: 0), song("2", "B", artists: ["Jan 12, 2023"], ms: 0)]
        #expect(MusicTrackCells.data(for: rows) == MusicTrackCells.Data(artist: false, album: false, duration: false))
        let mixed = rows + [song("3", "C", artists: ["Adele"], album: "Z", ms: 120_000)]
        #expect(MusicTrackCells.data(for: mixed) == MusicTrackCells.Data(artist: true, album: true, duration: true))
        #expect(MusicTrackCells.durationText(ms: 0, columnShown: true) == "--:--")
        #expect(MusicTrackCells.durationText(ms: 0, columnShown: false) == nil)
        #expect(MusicTrackCells.durationText(ms: 125_000, columnShown: true) == "2:05")
        #expect(MusicTrackCells.data(for: []) == .all)
    }

    // MARK: two columns

    @Test func theLeftColumnContinuesUnderTheTopResult() {
        #expect(MusicSearchBalance.leftArtists(sideBySide: true, songRows: 8, artists: 5) == 4)
        #expect(MusicSearchBalance.leftArtists(sideBySide: true, songRows: 8, artists: 2) == 2)
        #expect(MusicSearchBalance.leftArtists(sideBySide: true, songRows: 3, artists: 5) == 0)
        #expect(MusicSearchBalance.leftArtists(sideBySide: false, songRows: 8, artists: 5) == 0)
        #expect(MusicSearchBalance.leftArtists(sideBySide: true, songRows: 8, artists: 0) == 0)
        #expect(MusicSearchLayout.sideBySide(.compact) == false && MusicSearchLayout.sideBySide(.medium) == false)
    }

    // MARK: covers

    @Test func repeatedCoversAreThinnedAndGetTheirOwnFallback() {
        let same = "https://img.example/pl.jpg?size=300"
        let list = [playlist("1", "Telugu Hits", cover: same), playlist("2", "Telugu Hits", cover: "https://img.example/other.jpg"),
                    playlist("3", "Melodies", cover: same), playlist("4", "Dance Mix", cover: "https://img.example/pl.jpg?size=600")]
        let out = MusicResultDedupe.playlists(list)
        #expect(out.map(\.id) == ["1", "3", "4"])           // the same title twice is one item
        #expect(!out[0].thumbnails.isEmpty)                 // the first keeps the picture
        #expect(out[1].thumbnails.isEmpty && out[2].thumbnails.isEmpty)   // the others show a designed cover each
        #expect(MusicResultDedupe.coverKey([MusicThumbnail(url: "https://a.example/x=w60-h60")]) == "https://a.example/x")
    }

    @Test func aMissingCoverHasAStableDistinctTint() {
        #expect(MusicCoverTint.hue(for: "Melodies|") == MusicCoverTint.hue(for: "Melodies|"))
        #expect(MusicCoverTint.hue(for: "Melodies|") != MusicCoverTint.hue(for: "Dance Mix|"))
    }

    // MARK: Home genre tiles


    // MARK: page frame

}
