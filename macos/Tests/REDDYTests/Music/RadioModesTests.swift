import Testing
import Foundation
@testable import REDDY

// The Pandora-style modes (newly released, deep cuts, crowd favourites, artist only) and the Thumbprint station, tested as behaviour on synthetic songs.

private enum MT {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)   // late 2027

    static func song(_ n: Int, artist: String, popularity: Int? = nil, released: String? = nil, fromSeed: Bool = false) -> RadioCandidate {
        var t = MusicTrack(id: "t\(n)", providerID: "p", title: "Song \(n)", durationMs: 200_000, artists: [MusicArtistRef(id: "a-" + artist, name: artist)])
        t.popularity = popularity
        if let released { t.album = MusicAlbumRef(id: "al\(n)", title: "Album \(n)", releaseDate: released) }
        return RadioCandidate(track: t, source: .provider, rank: n, fromSeed: fromSeed)
    }

    static func station(_ mode: RadioMode, artist: String = "Ada") -> RadioStation {
        let a = MusicArtist(id: "a-" + artist, providerID: "p", name: artist)
        return RadioStation(name: "T", seeds: [.artist(a)], createdAt: now, mode: mode)
    }

    static func picks(_ pool: [RadioCandidate], mode: RadioMode, want: Int = 6) -> [MusicTrack] {
        var c = RadioPickContext(station: station(mode))
        c.now = now
        return RadioSelector.select(pool, context: c, want: want).map(\.track)
    }
}

@Suite("Radio modes") struct RadioModesTests {
    @Test func everyModeHasAWordingAndOldSavedStationsStillLoad() throws {
        for m in RadioMode.allCases { #expect(!m.title.isEmpty && !m.blurb.isEmpty && m.familiarShare > 0 && m.familiarShare <= 1) }
        #expect(RadioMode.allCases.count == 7)
        let data = Data(#""discover""#.utf8)
        #expect(try JSONDecoder().decode(RadioMode.self, from: data) == .discover)
        let newer = try JSONEncoder().encode([RadioMode.deepCuts, .artistOnly])
        #expect(try JSONDecoder().decode([RadioMode].self, from: newer) == [.deepCuts, .artistOnly])
    }

    @Test func newlyReleasedPutsTheLatestSongsFirstAndAgesFadeTheBonus() {
        let pool = [MT.song(0, artist: "Ada", released: "2019-05-01"), MT.song(1, artist: "Bo", released: "2027-09-10"),
                    MT.song(2, artist: "Cy", released: "2027-02"), MT.song(3, artist: "Di", released: "2025")]
        let order = MT.picks(pool, mode: .newlyReleased, want: 4).map(\.id)
        #expect(order.first == "t1")
        #expect(order.firstIndex(of: "t2")! < order.firstIndex(of: "t0")!)
        // A song with no date gets no bonus and no penalty.
        let none = MT.song(9, artist: "Ed")
        #expect(RadioModeRules.bonus(for: none.track, mode: .newlyReleased, now: MT.now) == 0)
        let fresh = MT.song(8, artist: "Fay", released: "2027-10-01").track
        let old = MT.song(7, artist: "Gus", released: "2015").track
        #expect(RadioModeRules.bonus(for: fresh, mode: .newlyReleased, now: MT.now) > RadioModeRules.bonus(for: old, mode: .newlyReleased, now: MT.now))
    }

    @Test func crowdFavouritesFavourPopularSongsAndDeepCutsTheQuietOnes() {
        let pool = [MT.song(0, artist: "Ada", popularity: 95), MT.song(1, artist: "Bo", popularity: 10), MT.song(2, artist: "Cy", popularity: 55), MT.song(3, artist: "Di", popularity: 2)]
        // The source's own order is the same in both modes (rank 0...3): only the mode changes who comes first.
        #expect(MT.picks(pool, mode: .crowdFaves, want: 2).map(\.id).first == "t0")
        // Deep cuts: one of the quiet songs comes first (the source's own order still counts, so the quietest need not lead), and the best-known comes last.
        let deep = MT.picks(pool, mode: .deepCuts, want: 4).map(\.id)
        #expect(["t1", "t3"].contains(deep.first ?? "") && deep.last == "t0")
        // Without a popularity figure a song is neither rewarded nor punished in crowd favourites, and slightly preferred in deep cuts.
        let unknown = MT.song(5, artist: "Eve").track
        #expect(RadioModeRules.bonus(for: unknown, mode: .crowdFaves, now: MT.now) == 0)
        #expect(RadioModeRules.bonus(for: unknown, mode: .deepCuts, now: MT.now) > 0)
    }

    @Test func artistOnlyKeepsOnlyTheStationsOwnArtists() {
        let pool = [MT.song(0, artist: "Ada", fromSeed: true), MT.song(1, artist: "Bo"), MT.song(2, artist: "Ada"), MT.song(3, artist: "Cy"),
                    MT.song(4, artist: "Ada"), MT.song(5, artist: "Ada"), MT.song(6, artist: "Di")]
        let picks = MT.picks(pool, mode: .artistOnly, want: 6)
        #expect(!picks.isEmpty && picks.allSatisfy { $0.artists.first?.name == "Ada" })
        // Every other mode may bring other artists.
        let mixed = MT.picks(pool, mode: .mixed, want: 6)
        #expect(mixed.contains { $0.artists.first?.name != "Ada" })
    }

    @Test func artistOnlyNeverGoesQuietWhenTheSourceKnowsTooLittle() {
        // Only one song by the station's artist in the pool: fewer than three, so the seeds' own songs are used; with none of those the pool is left alone.
        let pool = [MT.song(0, artist: "Bo"), MT.song(1, artist: "Cy"), MT.song(2, artist: "Ada")]
        #expect(!MT.picks(pool, mode: .artistOnly, want: 3).isEmpty)
        let seeded = [MT.song(0, artist: "Bo"), MT.song(1, artist: "Ada", fromSeed: true), MT.song(2, artist: "Cy")]
        let shaped = RadioModeRules.shape(seeded, station: MT.station(.artistOnly))
        #expect(shaped.allSatisfy(\.fromSeed) && shaped.count == 1)
        // A genre station has no artists: nothing is filtered away.
        let genre = RadioStation(name: "G", seeds: [.genre("jazz")], createdAt: MT.now, mode: .artistOnly)
        #expect(RadioModeRules.shape(pool, station: genre).count == pool.count)
    }

    @Test func aReleaseDateReadsInThreeShapesAndRefusesNonsense() {
        func age(_ s: String?) -> Double? { RadioModeRules.ageDays(of: MT.song(1, artist: "A", released: s).track, now: MT.now) }
        #expect(age("2027") != nil && age("2027-03") != nil && age("2027-03-14") != nil)
        #expect(age(nil) == nil && age("") == nil && age("abc") == nil && age("12") == nil)
        #expect(age("2027-03-14")! < age("2020-03-14")!)
    }

    @Test func thumbsStillCountInEveryMode() {
        let liked = MT.song(0, artist: "Ada").track
        var s = MT.station(.deepCuts)
        s.feedback = [RadioFeedback(track: liked, kind: .up, at: MT.now), RadioFeedback(track: liked, kind: .up, at: MT.now)]
        var c = RadioPickContext(station: s); c.now = MT.now
        let pool = [MT.song(1, artist: "Bo", popularity: 5), MT.song(2, artist: "Ada", popularity: 60)]
        let first = RadioSelector.select(pool, context: c, want: 1).first?.track.artists.first?.name
        // Two thumbs up on Ada (weight 2 x 0.5) outweigh what deep cuts adds for the quieter song (0.76 against 0.32) and its better place in the list.
        #expect(first == "Ada")
    }
}

@Suite("Thumbprint station") struct ThumbprintStationTests {
    private func liked(_ plan: [(String, Int)]) -> [MusicTrack] {
        var out: [MusicTrack] = []; var n = 0
        for (artist, count) in plan { for _ in 0..<count { n += 1; out.append(MusicTrack(id: "l\(n)", providerID: "p", title: "L\(n)", durationMs: 1, artists: [MusicArtistRef(id: "a-" + artist, name: artist)])) } }
        return out
    }

    @Test func needsEnoughLikesAndEnoughDifferentArtists() {
        #expect(RadioDerived.thumbprint(liked: liked([("Ada", 4)])) == nil)               // too few likes
        #expect(RadioDerived.thumbprint(liked: liked([("Ada", 8)])) == nil)               // one artist is not a thumbprint
        #expect(RadioDerived.thumbprint(liked: []) == nil)
        #expect(RadioDerived.thumbprint(liked: liked([("Ada", 3), ("Bo", 3)])) != nil)
    }

    @Test func itIsSeededWithTheMostLikedArtistsAndStaysFamiliar() throws {
        let plan: [(String, Int)] = [("Ada", 9), ("Bo", 7), ("Cy", 5), ("Di", 4), ("Ed", 3), ("Fay", 2), ("Gus", 1)]
        let s = try #require(RadioDerived.thumbprint(liked: liked(plan)))
        #expect(s.mode == .familiar && s.derivedID == "thumbprint" && s.id == "thumbprint")
        #expect(s.seeds.count == RadioDerived.thumbprintArtists)
        let names = s.seeds.map(\.name)
        #expect(names == ["Ada", "Bo", "Cy", "Di", "Ed"])
        #expect(!names.contains("Gus"))
    }

    @Test func itLeadsMadeForYouAndIsNamedWithoutAnyArtist() throws {
        var input = RadioDerived.Input()
        input.liked = liked([("Ada", 4), ("Bo", 3), ("Cy", 3)])
        let r = RadioDerived.build(input)
        let t = try #require(r.thumbprint)
        #expect(r.all.first?.id == t.id && r.hasPersonal)
        #expect(!t.name.contains("Ada") && !t.name.contains("Bo"))
        // No likes: no thumbprint, and a new person still has only what they had before.
        #expect(RadioDerived.build(.init()).thumbprint == nil)
    }

    @Test func startingItTwiceFindsTheSameSavedStation() throws {
        let draft = try #require(RadioDerived.thumbprint(liked: liked([("Ada", 5), ("Bo", 5)])))
        var saved = draft; saved.id = "saved-id"
        #expect(RadioDerived.existing(for: draft, in: [saved])?.id == "saved-id")
    }
}
