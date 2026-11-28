import Foundation
import Testing
@testable import REDDY

@Suite("Film page gaps 3") struct FilmPageGaps3Tests {
    private func person(_ name: String, _ token: String, order: Int? = nil, birth: Int? = nil) -> MusicFilmPersonItem {
        MusicFilmPersonItem(person: MusicEntityID(kind: .person, token: token), name: name, imageRef: nil, role: .actor, character: nil, order: order, status: .verified,
                            creditLevel: .film, nameOnly: false, attribution: nil, birthYear: birth)
    }

    private func album(film: MusicEntityID?) -> MusicFilmAlbumItem {
        MusicFilmAlbumItem(album: MusicEntityID(kind: .album, token: "a1"), name: "Songs", year: 2019, imageRef: nil, lang: nil, dubLanguage: nil, status: .verified,
                           confidence: 1, matchEvidence: [], via: nil, film: film, filmName: nil)
    }

    @Test @MainActor func onePersonWithTwoCreditsIsNotTwoOfOneName() {
        let a = person("Raj Kapoor", "p1", birth: 1924)
        let b = person("Raj Kapoor", "p1", birth: 1924)
        #expect(MusicFilmWording.disambiguators([a, b]).isEmpty)
        let other = person("Raj Kapoor", "p2", birth: 1980)
        let tags = MusicFilmWording.disambiguators([a, b, other])
        #expect(tags.count == 2)
    }

    @Test @MainActor func anOrdinaryAlbumIsNotCalledASoundtrack() {
        let plain = MusicFilmWording.albumCaption(album(film: nil), edition: nil)
        #expect(plain == "2019")
        let film = MusicFilmWording.albumCaption(album(film: nil), edition: .original)
        #expect(film?.contains(MusicFilmWording.editionTitle(.original)) == true)
    }

    @Test func leadAndSupportingCastComeFromBillingOrder() {
        let cast = (0..<8).map { person("Actor \($0)", "c\($0)", order: $0) }
        let split = MusicFilmCastRoles.split(cast)
        #expect(split?.lead.count == MusicFilmCastRoles.leadCount)
        #expect(split?.supporting.count == 3)
        #expect(MusicFilmCastRoles.split(cast.map { var p = $0; p.order = nil; return p }) == nil)
        #expect(MusicFilmCastRoles.split(Array(cast.prefix(3))) == nil)
    }

    @Test func theGalleryKeepsTextlessBackdropsAndPostersWithoutCaptions() throws {
        let json = """
        {"backdrops":[{"file_path":"/a.jpg","iso_639_1":null},{"file_path":"/b.jpg","iso_639_1":"en"},{"file_path":"/a.jpg","iso_639_1":null}],
         "posters":[{"file_path":"/p.jpg","iso_639_1":"hi"}]}
        """
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let images = MusicFilmGallery.parse(images: obj)
        #expect(images.map(\.path) == ["/a.jpg", "/p.jpg"])
        #expect(images.map(\.kind) == [.backdrop, .poster])
        let text = try #require(MusicFilmGallery.encode(images))
        #expect(MusicFilmGallery.decode(text) == images)
        #expect(MusicFilmGallery.parse(images: nil).isEmpty)
        #expect(MusicFilmGallery.encode([]) == nil)
        #expect(MusicFilmGallery.decode("x/bad|b/ok.jpg").map(\.path) == ["/ok.jpg"])
    }

    @Test func steppingWraps() {
        #expect(MusicFilmGallery.step(0, by: -1, count: 3) == 2)
        #expect(MusicFilmGallery.step(2, by: 1, count: 3) == 0)
        #expect(MusicFilmGallery.step(0, by: 1, count: 0) == nil)
    }

    @Test func theFilmFactsCarryTheGallery() throws {
        let json = """
        {"id":1,"title":"T","images":{"backdrops":[{"file_path":"/z.jpg","iso_639_1":null}],"posters":[]}}
        """
        let facts = TMDBGraphSource.facts(Data(json.utf8))
        #expect(MusicFilmGallery.decode(facts["gallery"]).map(\.path) == ["/z.jpg"])
    }
}
