import Testing
import Foundation
@testable import REDDY

@Suite("Album page gaps") struct AlbumPageGapsTests {
    private func item(_ id: String, disc: Int?) -> MusicAlbumTrackItem {
        MusicAlbumTrackItem(id: id, title: id, artistLine: "", disc: disc, number: 1, durationMs: 1000, isPlayable: true)
    }

    // MARK: discs

    @Test func songsWithNoDiscJoinDiscOneWhenNumberedDiscsStartAtTwo() {
        let items = [item("a", disc: 2), item("b", disc: nil), item("c", disc: 3)]
        let groups = MusicAlbumTrackView.discs(items, disc: \.disc)
        #expect(groups.map(\.disc) == [1, 2, 3])
        #expect(groups.flatMap(\.items).count == items.count)
        #expect(groups[0].items.map(\.id) == ["b"])
    }

    @Test func discNumbersAlwaysIncludeDiscOneForAnUnnumberedSong() {
        #expect(MusicAlbumTrackView.discNumbers([2, 3, nil]) == [1, 2, 3])
        #expect(MusicAlbumTrackView.discNumbers([2, 3]) == [2, 3])
        #expect(MusicAlbumTrackView.discNumbers([nil, nil]) == [1])
    }

    @Test func oneDiscIsNotGrouped() {
        let groups = MusicAlbumTrackView.discs([item("a", disc: 1), item("b", disc: nil)], disc: \.disc)
        #expect(groups.count == 1)
        #expect(groups[0].disc == nil)
        #expect(groups[0].items.count == 2)
    }

    @Test func discDurationSumsAndIgnoresNegatives() {
        #expect(MusicAlbumTrackView.totalDurationMs([1000, 2000, -5, 0]) == 3000)
    }

    // MARK: personal

    @Test func ratingIsOneToFiveOrNone() {
        #expect(MusicAlbumPersonal.clampRating(0) == nil)
        #expect(MusicAlbumPersonal.clampRating(-3) == nil)
        #expect(MusicAlbumPersonal.clampRating(3) == 3)
        #expect(MusicAlbumPersonal.clampRating(9) == 5)
    }

    @Test func tagsAreTrimmedDedupedAndBounded() {
        #expect(MusicAlbumPersonal.parseTags(" Road trip, road  trip ;Rainy, ,\nFocus") == ["Road trip", "Rainy", "Focus"])
        let many = (1...40).map { "t\($0)" }.joined(separator: ",")
        #expect(MusicAlbumPersonal.parseTags(many).count == MusicAlbumPersonal.maxTags)
        #expect(MusicAlbumPersonal.parseTags(String(repeating: "x", count: 100)).first?.count == MusicAlbumPersonal.maxTagLength)
    }

    @Test func oldSavedPrefsStillLoad() throws {
        let old = Data(#"{"preferred":{"a":"b"},"hidden":["x"]}"#.utf8)
        let p = try JSONDecoder().decode(MusicAlbumPrefs.self, from: old)
        #expect(p.preferred == ["a": "b"])
        #expect(p.hidden == ["x"])
        #expect(p.ratings.isEmpty && p.notes.isEmpty && p.tags.isEmpty)
    }

    @Test func prefsRoundTripKeepsPersonalChoices() throws {
        var p = MusicAlbumPrefs()
        p.ratings["k"] = 4; p.notes["k"] = "good"; p.tags["k"] = ["a", "b"]
        let back = try JSONDecoder().decode(MusicAlbumPrefs.self, from: JSONEncoder().encode(p))
        #expect(back == p)
    }

    // MARK: artwork index

    private let index = """
    {"images":[
      {"id":"3","types":["Booklet"],"front":false,"back":false,"approved":true,"image":"http://x/3.jpg","thumbnails":{"250":"http://x/3-250.jpg","500":"http://x/3-500.jpg","1200":"http://x/3-1200.jpg"}},
      {"id":"1","types":["Front"],"front":true,"back":false,"approved":true,"image":"http://x/1.jpg","thumbnails":{"small":"http://x/1-s.jpg","large":"http://x/1-l.jpg"}},
      {"id":"2","types":["Back"],"front":false,"back":true,"approved":true,"image":"http://x/2.jpg","thumbnails":{}},
      {"id":"4","types":["Medium"],"approved":false,"image":"http://x/4.jpg"},
      {"id":"5","types":["Medium"],"approved":true,"image":"http://x/5.jpg"},
      {"id":"6","types":["Tray"],"approved":true,"image":"http://x/6.jpg"}
    ]}
    """

    @Test func indexIsOrderedByWhatThePictureShowsAndSkipsUnapproved() {
        let imgs = MusicAlbumArtIndex.parse(Data(index.utf8))
        #expect(imgs.map(\.id) == ["1", "2", "3", "5", "6"])
        #expect(imgs.map(\.kind) == [.front, .back, .booklet, .medium, .other])
    }

    @Test func indexUsesLargeThumbnailsAndHttps() {
        let imgs = MusicAlbumArtIndex.parse(Data(index.utf8))
        let booklet = imgs.first { $0.id == "3" }
        #expect(booklet?.full == "https://x/3-1200.jpg")
        #expect(booklet?.thumb == "https://x/3-500.jpg")
        let front = imgs.first { $0.id == "1" }
        #expect(front?.full == "https://x/1.jpg")
        #expect(front?.thumb == "https://x/1-l.jpg")
    }

    @Test func badIndexIsEmpty() {
        #expect(MusicAlbumArtIndex.parse(Data("nope".utf8)).isEmpty)
        #expect(MusicAlbumArtIndex.parse(Data(#"{"images":[]}"#.utf8)).isEmpty)
    }

    @Test func indexAddressesTryTheReleaseFirst() {
        #expect(MusicAlbumArtIndex.indexAddresses(release: "r", releaseGroup: "g") == ["https://coverartarchive.org/release/r", "https://coverartarchive.org/release-group/g"])
        #expect(MusicAlbumArtIndex.indexAddresses(release: nil, releaseGroup: "g") == ["https://coverartarchive.org/release-group/g"])
        #expect(MusicAlbumArtIndex.indexAddresses(release: "", releaseGroup: nil).isEmpty)
    }
}
