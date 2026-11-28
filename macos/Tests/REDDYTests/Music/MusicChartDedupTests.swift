import Foundation
import Testing
@testable import REDDY

@Suite("Chart de-duplication and scope") struct MusicChartDedupTests {
    private func t(_ id: String, _ title: String, _ artists: String, ms: Int64 = 0, provider: String = "youtube-music", video: Bool? = nil, album: String? = nil, isrc: String? = nil) -> MusicTrack {
        var x = MusicTrack(id: id, providerID: provider, title: title, durationMs: ms,
                           artists: MusicLyricsQueryBuilder.names(artists).map { MusicArtistRef(id: $0, name: $0) })
        x.isVideo = video
        x.isrc = isrc
        if let album { x.album = MusicAlbumRef(id: "a", title: album, artists: [], thumbnails: []) }
        return x
    }
    private let irumudi = "Ananthu, Shiva Nirvana, G. V. Prakash Kumar & Kalyan Chakravarthy"

    // MARK: the real Telugu chart

    @Test func irumudiKattuAppearsOnceInTheRecordedTeluguChart() {
        let tracks = ChartFixtures.telugu.enumerated().map { t("v\($0.offset)", $0.element.0, $0.element.1, ms: 200_000) }
        let r = MusicSongIdentity.collapse(tracks)
        let rows = r.groups.filter { MusicSongIdentity.titleKey($0.best.track.title) == MusicSongIdentity.titleKey("Irumudi Kattu") }
        #expect(rows.count == 1)
        #expect(rows[0].versionCount == 7)
        #expect(rows[0].rank == 19)          // the best-ranked copy keeps its chart rank
        #expect(r.groups.count < 100)
        // ranks stay the chart's own, strictly rising, with gaps where copies were folded in
        let ranks = r.groups.map(\.rank)
        #expect(ranks == ranks.sorted() && Set(ranks).count == ranks.count)
        // Mallepoola Pallaki (three video uploads) and Yaalalo Yaalalo (three) each collapse to one row
        for name in ["Mallepoola Pallaki", "Yaalalo Yaalalo"] {
            let g = r.groups.filter { MusicSongIdentity.titleKey($0.best.track.title) == MusicSongIdentity.titleKey(name) }
            #expect(g.count == 1, "\(name)")
            #expect(g.first.map { $0.versionCount >= 3 } == true, "\(name)")
        }
        // same-name different people (Neno Butterfly by two singers) are kept apart
        let neno = r.groups.filter { MusicSongIdentity.titleKey($0.best.track.title) == MusicSongIdentity.titleKey("Neno Butterfly") }
        #expect(neno.count == 2)
    }

    @Test func irumudiKattuThreeRowsExactCase() {
        let rows = [t("a", "Irumudi Kattu", irumudi, ms: 210_000), t("b", "Irumudi Kattu", irumudi, ms: 212_000, video: true),
                    t("c", "Irumudi Kattu", "Ananthu, G. V. Prakash Kumar, Shiva Nirvana & Kalyan Chakravarthy", ms: 215_000)]
        let r = MusicSongIdentity.collapse(rows)
        #expect(r.groups.count == 1)
        #expect(r.groups[0].versionCount == 3)
        #expect(r.groups[0].rank == 1)
    }

    @Test func preferenceOrderPicksTheAudioThenAlbumThenLyricThenVideo() {
        let video = t("v", "Aeroplane Official Video", "Rajpriyan", ms: 200_000, video: true)
        let lyric = t("l", "Aeroplane Lyric Video", "Rajpriyan", ms: 200_000)
        let album = t("s", "Aeroplane", "Rajpriyan", ms: 200_000, album: "SCENE")
        let topic = t("t", "Aeroplane", "Rajpriyan - Topic", ms: 200_000)
        for order in [[video, lyric, album, topic], [topic, video, lyric, album], [lyric, video, album, topic]] {
            let g = MusicSongIdentity.collapse(order).groups
            #expect(g.count == 1)
            #expect(g[0].best.track.id == "t")
            #expect(g[0].members.map(\.kind) == [.officialAudio, .albumTrack, .lyricVideo, .officialVideo])
        }
        let noTopic = MusicSongIdentity.collapse([video, lyric, album]).groups[0]
        #expect(noTopic.best.track.id == "s")
        #expect(MusicSongIdentity.collapse([video, lyric]).groups[0].best.track.id == "l")
    }

    // MARK: never merge different recordings

    @Test func coversRemixesLiveAndRerecordingsStaySeparate() {
        let base = t("o", "Tum Hi Ho", "Arijit Singh", ms: 262_000)
        let others = [t("r", "Tum Hi Ho (Remix)", "Arijit Singh", ms: 262_000), t("l", "Tum Hi Ho - Live at Wembley", "Arijit Singh", ms: 262_000),
                      t("k", "Tum Hi Ho Karaoke Version", "Arijit Singh", ms: 262_000), t("i", "Tum Hi Ho (Instrumental)", "Arijit Singh", ms: 262_000),
                      t("c", "Tum Hi Ho (Cover)", "Arijit Singh", ms: 262_000), t("rr", "Tum Hi Ho (Re-recorded)", "Arijit Singh", ms: 262_000),
                      t("f", "Tum Hi Ho (Female Version)", "Arijit Singh", ms: 262_000), t("re", "Tum Hi Ho (Reprise)", "Arijit Singh", ms: 262_000),
                      t("u", "Tum Hi Ho (Unplugged)", "Arijit Singh", ms: 262_000)]
        let r = MusicSongIdentity.collapse([base] + others)
        #expect(r.groups.count == 1 + others.count)
        // a different artist's song with the same title is a different song
        #expect(MusicSongIdentity.collapse([base, t("x", "Tum Hi Ho", "Someone Else", ms: 262_000)]).groups.count == 2)
        // a much longer or shorter recording of the same title and artists is not the same recording
        #expect(MusicSongIdentity.collapse([base, t("d", "Tum Hi Ho", "Arijit Singh", ms: 150_000)]).groups.count == 2)
        #expect(MusicSongIdentity.collapse([base, t("e", "Tum Hi Ho", "Arijit Singh", ms: 262_000 + 25_000)]).groups.count == 1)
    }

    @Test func spellingVariantsOfAnIndianTitleMeet() {
        let g = MusicSongIdentity.collapse([t("1", "Zinda", "Arijit Singh", ms: 200_000), t("2", "Jinda Official Audio", "Arijit Singh", ms: 201_000)])
        #expect(g.groups.count == 1)
    }

    @Test func hundredEntriesWithThirtyDuplicates() {
        var rows: [MusicTrack] = []
        for i in 0..<70 { rows.append(t("s\(i)", "Song Number \(i) Zed", "Artist \(i)", ms: 200_000 + Int64(i) * 1000)) }
        // 30 extra uploads of earlier songs, spread through the list
        for j in 0..<30 { let src = rows[j * 2]; rows.insert(t("dup\(j)", src.title + " (Official Video)", src.artistLine, ms: src.durationMs + 3000, video: true), at: 5 + j * 3) }
        #expect(rows.count == 100)
        let r = MusicSongIdentity.collapse(rows)
        #expect(r.groups.count == 70)
        #expect(r.removedCount == 30)
        #expect(r.groups.map { $0.versionCount }.reduce(0, +) == 100)
        // play and queue use one entry per song
        #expect(Set(r.groups.map { $0.best.track.uid }).count == 70)
    }

    // MARK: albums are not merged

    @Test func albumTracksWithRepeatedTitlesAreMarkedNotMerged() {
        let album = [t("1", "Kashmeeru", "Raghav Chaitanya", ms: 250_000, provider: "itunes", album: "Animal"),
                     t("2", "Yaalo Yaalaa", "Jaani", ms: 190_000, provider: "itunes", album: "Animal"),
                     t("3", "Kashmeeru", "Raghav Chaitanya", ms: 250_000, provider: "itunes", album: "Animal"),
                     t("4", "Yaalo Yaalaa", "Jaani", ms: 190_000, provider: "itunes", album: "Animal"), t("5", "Hua Main", "Raghav", ms: 280_000, provider: "itunes", album: "Animal")]
        let marks = MusicSongIdentity.repeatedTitleMarkers(inAlbum: album)
        #expect(marks == ["itunes:1", "itunes:3", "itunes:2", "itunes:4"])
        // no album code path calls collapse; the list is untouched
        #expect(album.count == 5)
    }

    @Test func sameTitleKeptApartIsMarkedInACharts() {
        let r = MusicSongIdentity.collapse([t("1", "Kashmeeru", "Raghav", ms: 250_000), t("2", "Kashmeeru", "Raghav", ms: 120_000)])
        #expect(r.groups.count == 2)
        #expect(r.sameTitleDifferentRecording.count == 2)
    }

    // MARK: scope labelling and composition

    private func sec(_ id: String, _ title: String, _ scope: MusicSectionScope, items: Int = 3) -> MusicBrowseSection {
        MusicBrowseSection(id: id, title: title, items: (0..<items).map { .track(t("\(id)\($0)", "S\($0)", "A", provider: "itunes")) }, scope: scope)
    }
    private func parts(_ region: String, deezerRegional: Bool) -> [MusicChartArrangement.Part] {
        [.init(providerID: "discover-deezer", sourceFollowsRegion: deezerRegional,
               sections: deezerRegional ? [sec("deezer-top-" + region, "Deezer's top songs", .regional(region))] : [sec("deezer-tracks", "Top songs right now", .global), sec("deezer-albums", "Top albums", .global)]),
         .init(providerID: "discover-itunes-charts", sourceFollowsRegion: true, sections: [sec("itunes-songs-" + region, "Top songs", .regional(region)), sec("itunes-albums-" + region, "Top albums", .regional(region))]),
         .init(providerID: "discover-audius", sourceFollowsRegion: false, sections: [sec("audius-trending-week", "Trending now", .global)]),
         .init(providerID: "discover-jiosaavn", sourceFollowsRegion: region == "in", sections: region == "in" ? [sec("jiosaavn-top-hindi", "India Superhits", .regional("in"))] : [])]
    }

    @Test func indiaShowsOnlyIndiaListsUnderTheCountryAndWorldwideAfter() {
        let a = MusicChartArrangement.arrange(parts("in", deezerRegional: false) + [.init(providerID: "ytm", sourceFollowsRegion: true, sections: [sec("ytm-chart-videos", "Video charts in India", .regional("in"))])], region: "in")
        #expect(a.regional.map(\.id) == ["ytm-chart-videos", "itunes-songs-in", "jiosaavn-top-hindi", "itunes-albums-in"])
        #expect(a.worldwide.map(\.title) == ["Top worldwide", "Top albums worldwide", "Trending now"])
        #expect(!a.regional.contains { $0.id.hasPrefix("deezer") || $0.id.hasPrefix("audius") })
    }

    @Test func unitedStatesAppleFirstAndDeezerWorldwide() {
        let a = MusicChartArrangement.arrange(parts("us", deezerRegional: false), region: "us")
        #expect(a.regional.first?.id == "itunes-songs-us")
        #expect(a.worldwide.map(\.title).contains("Top worldwide"))
    }

    @Test func franceUsesDeezersOwnTopFranceAsRegional() {
        let a = MusicChartArrangement.arrange(parts("fr", deezerRegional: true), region: "fr")
        #expect(a.regional.map(\.id) == ["itunes-songs-fr", "deezer-top-fr", "itunes-albums-fr"])
        #expect(a.worldwide.map(\.title) == ["Trending now"])
    }

    @Test func aCountryWithNoRegionalSourceHasNoCountryShelfAtAll() {
        let only = [MusicChartArrangement.Part(providerID: "discover-deezer", sourceFollowsRegion: false, sections: [sec("deezer-tracks", "Top songs right now", .global)]),
                    .init(providerID: "discover-audius", sourceFollowsRegion: false, sections: [sec("audius-trending-week", "Trending", .global)])]
        let a = MusicChartArrangement.arrange(only, region: "xx")
        #expect(a.regional.isEmpty)
        #expect(a.worldwide.count == 2)
    }

    @Test func aListFromAnotherCountryOrWithNoScopeIsNeverTheCountrys() {
        let a = MusicChartArrangement.arrange([.init(providerID: "p", sourceFollowsRegion: false, sections: [sec("x", "Top songs", .other), sec("y", "French", .regional("fr"))])], region: "in")
        #expect(a.regional.isEmpty)
        #expect(a.other.count == 2)
        // old saved lists (scope .other) from a source that follows the country keep working
        let b = MusicChartArrangement.arrange([.init(providerID: "p", sourceFollowsRegion: true, sections: [sec("x", "Top songs", .other)])], region: "in")
        #expect(b.regional.count == 1)
    }

    @Test func sectionScopeRoundTrips() throws {
        let data = try JSONEncoder().encode([MusicSectionScope.regional("in"), .global, .other])
        #expect(try JSONDecoder().decode([MusicSectionScope].self, from: data) == [.regional("in"), .global, .other])
    }
}
