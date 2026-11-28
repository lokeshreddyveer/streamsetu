import Foundation
import Testing
@testable import REDDY

private typealias F = CreditsFixtures

@Suite("Provider credit mappers (real trimmed replies)") struct CreditsMapperTests {
    // MARK: JioSaavn

    @Test func jioSaavnAwaaraSongCarriesEveryRoleItReturned() throws {
        let t = try #require(JioSaavnProvider.mapSong(F.songs("jiosaavn-album-awaara-1951.json")[0]))
        #expect(t.title == "Ek Do Teen")
        // Existing behaviour is unchanged: the artists are still the primary artists.
        #expect(t.artists.map(\.name) == ["Shankar-Jaikishan", "Shamshad Begum"])
        #expect(F.names(t, .primary) == ["Shankar-Jaikishan", "Shamshad Begum"])
        #expect(F.names(t, .music) == ["Shankar-Jaikishan"])
        #expect(F.names(t, .singer) == ["Shamshad Begum"])
        #expect(F.names(t, .lyricist) == ["Shailendra"])
        #expect(F.names(t, .starring) == ["Raj Kapoor", "Nargis", "Prithviraj Kapoor", "Leela Chitnis"])
        let lyricist = try #require(F.credits(t, .lyricist).first)
        #expect(lyricist.providerArtistID == "457181" && lyricist.level == .track)
        #expect(F.credits(t, .starring).allSatisfy { $0.level == .film }, "cast of the film, not of the song")
        #expect(F.credits(t, .singer).allSatisfy { $0.level == .track })
        #expect(t.hints?.language == "hindi" && t.hints?.year == 1951)
    }

    @Test func differentSongsKeepTheirOwnLyricists() throws {
        let songs = F.songs("jiosaavn-album-awaara-1951.json").compactMap(JioSaavnProvider.mapSong)
        #expect(songs.map { F.names($0, .lyricist) } == [["Shailendra"], ["Shailendra"], ["Hasrat Jaipuri"]])
        #expect(songs.map { F.names($0, .singer) } == [["Shamshad Begum"], ["Mukesh"], ["Lata Mangeshkar"]])
    }

    @Test func jioSaavnJailerSongKeepsTheNamesAsTheServiceSentThem() throws {
        let t = try #require(JioSaavnProvider.mapSong(F.songs("jiosaavn-album-jailer-2023.json")[0]))
        #expect(t.title == "Kaavaalaa")
        #expect(F.names(t, .primary) == ["Shilpa Rao", "Anirudh Ravichander", "Arunraja Kamaraj"])
        // The service itself filed these three under "music"; the mapper reports what it was told.
        #expect(Set(F.names(t, .music)) == ["Anirudh Ravichander", "Shilpa Rao", "Arunraja Kamaraj"])
        #expect(F.credits(t, .music).first?.providerArtistID == "455663")
        #expect(t.hints?.language == "tamil" && t.hints?.year == 2023)
    }

    @Test func jioSaavnAlbumGathersTheFilmsCastAndReadsNoRoleItWasNotGiven() throws {
        let a = try #require(JioSaavnProvider.mapAlbum(F.json("jiosaavn-album-awaara-1951.json")))
        let cast = (a.credits ?? []).filter { $0.role == .starring }
        #expect(cast.map(\.name) == ["Raj Kapoor", "Nargis", "Prithviraj Kapoor", "Leela Chitnis"])
        #expect(cast.allSatisfy { $0.level == .film })
        // The album's own artist map names nobody and sends no flat music list: no album-level people are invented.
        #expect((a.credits ?? []).filter { $0.level == .album }.isEmpty)
        #expect(a.hints?.year == 1951 && a.hints?.language == "hindi")
        let j = try #require(JioSaavnProvider.mapAlbum(F.json("jiosaavn-album-jailer-2023.json")))
        #expect((j.credits ?? []).filter { $0.role == .primary }.map(\.name) == ["Anirudh Ravichander"], "Various Artists is not a person; the leading space is trimmed")
        #expect((j.credits ?? []).filter { $0.role == .primary }.allSatisfy { $0.level == .album })
    }

    @Test func aSongWithNoArtistMapAndNoFlatRolesHasNoCredits() throws {
        let raw: [String: Any] = ["id": "x1", "title": "Plain", "more_info": ["primary_artists": "Somebody", "duration": "100"] as [String: Any]]
        let t = try #require(JioSaavnProvider.mapSong(raw))
        #expect(t.credits == nil && t.hints == nil)
        #expect(t.artists.map(\.name) == ["Somebody"])
    }

    // MARK: YouTube Music

    @Test func youTubeMusicAlbumHeaderGivesAlbumLevelPerformersWithChannelIDs() throws {
        let root = F.json("ytmusic-album-kaavaali-single-2023.json")
        let page = YTMPageParser.parseAlbum(root, browseID: "MPREb_GNbXdq2xGke")
        let credits = try #require(page.album.credits)
        #expect(credits.count >= 2 && credits.first?.name == "Anirudh Ravichander")
        #expect(credits.allSatisfy { $0.role == .primary && $0.level == .album && ($0.providerArtistID ?? "").hasPrefix("UC") })
        #expect(credits.first?.providerArtistID == "UCbRSywya_rl8YS15Lo9ttsA")
        #expect(page.album.hints?.year == 2023)
        #expect(page.album.artists.first?.id == "UCbRSywya_rl8YS15Lo9ttsA", "the existing artist refs are unchanged")
    }

    @Test func youTubeMusicSongCreditsPanelMapsTheTitlesItKnows() {
        let root = F.json("ytmusic-track-credits-awara-hoon.json")
        let credits = YouTubeMusicCreditMapper.parseCredits(root)
        #expect(credits.map(\.role) == [.performer, .writer])
        #expect(credits.map(\.name) == ["Mukesh", "Shankar-jaikishan"])
        #expect(!credits.contains { $0.role == .producer }, "\"N/a\" is a placeholder, not a producer")
        #expect(YouTubeMusicCreditMapper.role(forTitle: "作曲") == nil, "a title in a language it does not know is left out")
    }

    @Test func creditsPageIDComesOnlyFromTheEndpointThatSaysItIsTheCreditsPage() {
        let withCredits: [String: Any] = ["menu": ["items": [["browseEndpoint": ["browseId": "MPTCpToh0-oCCj8",
            "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_TRACK_CREDITS"]]]]]]]
        #expect(YouTubeMusicCreditMapper.creditsBrowseID(inNext: withCredits) == "MPTCpToh0-oCCj8")
        let lyricsOnly: [String: Any] = ["tabs": [["browseEndpoint": ["browseId": "MPLYt_abc",
            "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_TRACK_LYRICS"]]]]]]
        #expect(YouTubeMusicCreditMapper.creditsBrowseID(inNext: lyricsOnly) == nil)
    }

    // MARK: Apple, Deezer, Audius, Subsonic, local

    @Test func iTunesGivesTheSongsArtistTheGenreAndNoComposerWhenTheReplyHasNone() throws {
        let results = F.json("itunes-lookup-awaara-hoon.json").array("results")
        let first = try #require(results.first)
        let t = try #require(ITunesProvider.mapTrack(first))
        #expect(F.names(t, .primary) == ["Mukesh"] && F.credits(t, .primary).first?.providerArtistID == "18476802")
        #expect(F.credits(t, .composer).isEmpty, "the live reply carries no composer field; none is invented")
        #expect(t.hints?.genre == "Bollywood" && t.hints?.year == 2009)
        #expect(t.artists.map(\.name) == ["Mukesh"])
        // When a reply does carry composerName it is read, split on commas.
        var withComposer = first; withComposer["composerName"] = "Shankar-Jaikishan, Shailendra"
        let c = try #require(ITunesProvider.mapTrack(withComposer))
        #expect(F.names(c, .composer) == ["Shankar-Jaikishan", "Shailendra"])
    }

    @Test func deezerContributorsKeepTheirRoles() throws {
        let b = try #require(DeezerCreditMapper.trackBundle(F.json("deezer-track-beautiful-people.json")))
        #expect(b.credits.map(\.name) == ["Ed Sheeran", "Khalid"])
        #expect(b.credits.map(\.role) == [.primary, .featured])
        #expect(b.credits.map(\.providerArtistID) == ["384236", "362326"])
        #expect(b.hints?.year == 2019)
    }

    @Test func audiusFlagsBecomeVersionHintsOnlyWhenTheFieldsAreThere() throws {
        let remix: [String: Any] = ["id": "t1", "title": "Song", "user": ["id": "u1", "name": "Producer"] as [String: Any], "genre": "Electronic",
                                    "remix_of": ["tracks": [["parent_track_id": 7]]] as [String: Any]]
        let b = try #require(AudiusCreditMapper.trackBundle(remix))
        #expect(b.hints?.version == "remix" && b.credits.map(\.name) == ["Producer"] && b.credits.first?.providerArtistID == "u1")
        let cover: [String: Any] = ["id": "t2", "title": "Song", "user": ["id": "u2", "name": "Singer"] as [String: Any],
                                    "cover_original_song_title": "Original", "cover_original_artist": "Band"]
        #expect(AudiusCreditMapper.trackBundle(cover)?.hints?.version == "cover")
        #expect(AudiusCreditMapper.trackBundle(cover)?.hints?.versionOf == "Original - Band")
        let plain: [String: Any] = ["id": "t3", "title": "Song", "user": ["id": "u3", "name": "Solo"] as [String: Any], "remix_of": ["tracks": [Any]()] as [String: Any]]
        #expect(AudiusCreditMapper.trackBundle(plain)?.hints?.version == nil)
    }

    @Test func subsonicContributorsMapToRolesWithTheServerScopedIDs() throws {
        let raw = F.json("opensubsonic-song-contributors.json")
        let b = try #require(SubsonicCreditMapper.trackBundle(raw, id: { "srv~" + $0 }))
        func has(_ role: MusicCreditRole, _ name: String) -> Bool { b.credits.contains { $0.role == role && $0.name == name } }
        #expect(has(.primary, "Mukesh") && has(.albumArtist, "Shankar-Jaikishan") && has(.composer, "Shankar-Jaikishan") && has(.lyricist, "Shailendra"))
        let tabla = try #require(b.credits.first { $0.role == .performer })
        #expect(tabla.instrument == "tabla" && tabla.providerArtistID == "srv~ar-40")
        #expect(!b.credits.contains { $0.name == "Someone Else" }, "an engineer is not a credit this graph reads")
        #expect(b.credits.filter { $0.role == .composer }.count == 1, "displayComposer is only a fallback when no composer contributor exists")
        #expect(SubsonicCreditMapper.trackBundle(["id": "x", "title": "Bare"]) == nil)
    }

    @Test func subsonicDisplayComposerIsTheFallback() throws {
        let b = try #require(SubsonicCreditMapper.trackBundle(["id": "x", "title": "T", "displayComposer": "A One, B Two"]))
        #expect(b.credits.map(\.name) == ["A One", "B Two"] && b.credits.allSatisfy { $0.role == .composer })
    }

    @Test func localTagsGiveComposerLyricistConductorAndWork() throws {
        var e = LocalEntry(id: "l1", folderID: "f", path: "/m/a.flac", title: "Symphony", artist: "Orchestra", album: "Set", trackNumber: 1, durationMs: 1000,
                           modified: Date(), artworkFile: nil, ext: "flac")
        #expect(LocalTagCreditMapper.bundle(for: e) == nil, "an untagged file has no credits")
        e.composer = "Ludwig van Beethoven"; e.lyricist = "Schiller; Someone"; e.conductor = "Karajan"; e.work = "Symphony No. 9"; e.albumArtist = "Berlin Phil"
        let b = try #require(LocalTagCreditMapper.bundle(for: e))
        #expect(b.credits.map(\.role) == [.composer, .lyricist, .lyricist, .conductor, .albumArtist])
        #expect(b.hints?.work == "Symphony No. 9")
    }
}
