import Foundation
import Testing
@testable import REDDY

/// The search contract: what a person expects of music search, checked on the rules under it, for any language and any names.
private func song(_ id: String, _ title: String, artist: String = "Artist", ms: Int64 = 200_000, thumb: String? = nil) -> MusicTrack {
    var t = MusicTrack(id: id, providerID: "p", title: title, durationMs: ms, artists: [MusicArtistRef(id: "a-" + artist, name: artist)])
    if let thumb { t.thumbnails = [MusicThumbnail(url: thumb, width: 300, height: 300)] }
    return t
}
private func album(_ id: String, _ title: String, artist: String = "Artist", thumb: String? = nil) -> MusicAlbum {
    var a = MusicAlbum(id: id, providerID: "p", title: title, artists: [MusicArtistRef(id: "a-" + artist, name: artist)])
    if let thumb { a.thumbnails = [MusicThumbnail(url: thumb, width: 300, height: 300)] }
    return a
}

// 1. Universal search
@Suite("Search 1: universal search") struct UniversalSearchContract {
    @Test func theAllChipAsksForSongsArtistsAlbumsAndPlaylistsAndEachChipForOne() {
        #expect(MusicSearchKind.all.types.isSuperset(of: [.track, .artist, .album, .playlist]))
        #expect(MusicSearchKind.songs.types == [.track] && MusicSearchKind.artists.types == [.artist]
                && MusicSearchKind.albums.types == [.album] && MusicSearchKind.playlists.types == [.playlist])
        #expect(Set(MusicSearchKind.allCases.map(\.title)).count == MusicSearchKind.allCases.count)
    }
}

// 2. Instant suggestions
@Suite("Search 2: instant suggestions") struct SuggestionContract {
    @Test func suggestionsComeFromTheFirstTwoLettersStartWithPrefixMatchesAndNeedNoNetwork() async {
        let s = MusicLocalSuggestions()
        await s.add(["Arijit Singh", "Arctic Monkeys", "Adele", "Chikiri Chikiri"], kind: .artist, weight: 1)
        let one = await s.suggest("a"); #expect(one.suggestions.isEmpty)                      // one letter says nothing
        let r = await s.suggest("ar").suggestions
        #expect(r.contains { $0.text == "Arijit Singh" } && r.contains { $0.text == "Arctic Monkeys" } && !r.contains { $0.text == "Adele" })
        #expect(r.first?.how == .start)
    }
    @Test func theLimitIsRespected() async {
        let s = MusicLocalSuggestions()
        await s.add((0..<40).map { "Love Song \($0)" }, kind: .song, weight: 1)
        let many = await s.suggest("love", limit: 6); #expect(many.suggestions.count <= 6)
    }
}

// 3. Fuzzy search
@Suite("Search 3: spelling mistakes") struct FuzzyContract {
    @Test func aMisspelledWordIsCorrectedToAKnownOneWithinASmallDistance() async {
        let s = MusicLocalSuggestions()
        await s.add(["Shape of You", "Blinding Lights", "Believer", "Yesterday"], kind: .song, weight: 1)
        let d1 = await s.didYouMean("blinding lihgts"); #expect(d1 == "blinding lights")
        let d2 = await s.didYouMean("beleiver"); #expect(d2 == "believer")
        let d3 = await s.didYouMean("yesterday"); #expect(d3 == nil)                       // a correct query is left alone
    }
    @Test func theAllowedDistanceGrowsWithTheWordAndShortWordsAreNeverGuessed() {
        #expect(MusicSpellIndex.allowedDistance(forLength: 3) == 0)
        #expect(MusicSpellIndex.allowedDistance(forLength: 5) == 1 && MusicSpellIndex.allowedDistance(forLength: 9) == 2)
        #expect(MusicSpellIndex.distance("kitten", "sitting", limit: 5) == 3)
    }
    @Test func aSongTitleStillScoresForATypo() {
        let t = song("1", "Blinding Lights", artist: "The Weeknd")
        #expect(MusicSearchScoring.score(track: t, query: "blinding lihgts") > MusicSearchScoring.score(track: song("2", "Something Else Entirely"), query: "blinding lihgts"))
    }
}

// 4. Multilingual search
@Suite("Search 4: native and transliterated text") struct MultilingualContract {
    @Test func theSameNameInTwoScriptsLooksAlikeAndDifferentNamesDoNot() {
        let pairs: [(String, String)] = [("चिकिरी चिकिरी", "Chikiri Chikiri"), ("ఛిక్కిరి", "Chikkiri"), ("अरिजीत सिंह", "Arijit Singh")]
        for (native, latin) in pairs {
            #expect(MusicTransliterationKey.similarity(native, latin) > MusicTransliterationKey.similarity(native, "Taylor Swift"), "\(native) / \(latin)")
        }
    }
    @Test func aNativeScriptTitleIsFoundByItsRomanisedSpelling() {
        let native = song("1", "కృష్ణా నీ బేగనే", artist: "Singer"), other = song("2", "Completely Unrelated Title")
        let ranked = MusicSearchScoring.rankTracks([other, native], query: "krishna nee begane")
        #expect(ranked.first?.id == "1")
    }
    @Test func typingInANativeScriptMatchesNativeNames() async {
        let s = MusicLocalSuggestions()
        await s.add(["అల్లు అర్జున్", "ఏ ఆర్ రెహమాన్"], kind: .artist, weight: 1)
        let na = await s.suggest("అల్లు"); #expect(na.suggestions.contains { $0.text == "అల్లు అర్జున్" })
    }
}

// 6. Search history
@Suite("Search 6: history") struct HistoryContract {
    @Test func newestFirstNoDuplicatesCappedAndShortQueriesIgnored() {
        var h = MusicRecentSearches()
        for q in ["a", "love", "Love", "rain", "sad songs"] { h.add(q) }
        #expect(h.items == ["sad songs", "rain", "Love"])                    // "a" ignored; "love" and "Love" are one search, the newest spelling kept
        for i in 0..<30 { h.add("query \(i)") }
        #expect(h.items.count == MusicRecentSearches.limit && h.chips.count == MusicRecentSearches.chipLimit)
        h.remove(h.items[0]); #expect(h.items.count == MusicRecentSearches.limit - 1)
        h.clear(); #expect(h.items.isEmpty)
    }
    @Test func historySurvivesARestartAndClearingForgetsIt() {
        let d = UserDefaults(suiteName: "search.contract.\(UUID().uuidString)")!
        var h = MusicRecentSearches(); h.add("rain"); h.add("అల్లు అర్జున్"); h.save(to: d)
        #expect(MusicRecentSearches(defaults: d).items == ["అల్లు అర్జున్", "rain"])
        h.clear(); h.save(to: d)
        #expect(MusicRecentSearches(defaults: d).items.isEmpty)
    }
}

// 10. Contextual ranking
@Suite("Search 10: ranking") struct RankingContract {
    @Test func theExactTitleBeatsALongerTitleThatOnlyContainsIt() {
        let exact = song("1", "Believer", artist: "Imagine Dragons"), longer = song("2", "Believer (Slowed + Reverb Bass Boosted Remix 2024)", artist: "Random Channel")
        #expect(MusicSearchScoring.rankTracks([longer, exact], query: "believer").first?.id == "1")
    }
    @Test func noiseWordsAndUnofficialUploadsAreChargedNotRewarded() {
        let plain = song("1", "Shape of You", artist: "Ed Sheeran"), noisy = song("2", "Shape of You Official Video HD 4K Lyrics", artist: "xyz")
        #expect(MusicSearchScoring.score(track: plain, query: "shape of you") >= MusicSearchScoring.score(track: noisy, query: "shape of you"))
    }
    @Test func aQueryWithTheArtistNameFindsThatArtistsSongFirst() {
        let a = song("1", "Rain", artist: "Taylor Swift"), b = song("2", "Rain", artist: "Someone Else")
        #expect(MusicSearchScoring.rankTracks([b, a], query: "rain taylor swift").first?.id == "1")
    }
}

// 12. Duplicate detection
@Suite("Search 12: duplicates") struct DuplicateContract {
    @Test func theSameAlbumListedTwiceIsShownOnceAndAShareCoverGetsItsOwnDesignedOne() {
        let list = [album("1", "Divide", artist: "Ed Sheeran", thumb: "https://x/c.jpg?w=100"), album("2", "Divide", artist: "Ed Sheeran", thumb: "https://x/c.jpg?w=600"),
                    album("3", "Different Album", artist: "Ed Sheeran", thumb: "https://x/c.jpg=s300")]
        let out = MusicResultDedupe.albums(list)
        #expect(out.map(\.id) == ["1", "3"])
        #expect(out[0].thumbnails.count == 1 && out[1].thumbnails.isEmpty)          // two different albums never show one picture
    }
    @Test func coverAddressesComparedWithoutSizeOrCacheParts() {
        let a = [MusicThumbnail(url: "https://x/img.jpg?w=1", width: 1, height: 1)], b = [MusicThumbnail(url: "https://x/img.jpg=s900", width: 9, height: 9)]
        #expect(MusicResultDedupe.coverKey(a) == MusicResultDedupe.coverKey(b))
    }
    @Test func playlistsWithTheSameNameCollapse() {
        let p = { (id: String, n: String) in MusicPlaylist(id: id, providerID: "p", name: n) }
        #expect(MusicResultDedupe.playlists([p("1", "Top Hits"), p("2", "Top Hits"), p("3", "Chill")]).map(\.id) == ["1", "3"])
    }
}
