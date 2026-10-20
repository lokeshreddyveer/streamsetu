import Testing
import Foundation
@testable import REDDY

@Suite struct BestVersionTests {
    private struct Copy: Equatable { let title: String; let folder: String? }
    private let words: (Copy) -> [String?] = { [$0.title, $0.folder] }

    @Test func higherResolutionWinsAndHdrAndSoundBreakTies() {
        let sd = Copy(title: "Film (2024)", folder: "ENGLISH | SD"), plain = Copy(title: "Film (2024)", folder: nil), hd = Copy(title: "Film (2024) 720p", folder: nil)
        let fhd = Copy(title: "Film (2024)", folder: "ENGLISH | FHD"), uhd = Copy(title: "Film (2024) [4K HDR]", folder: nil), uhdDv = Copy(title: "Film (2024) 4K Dolby Vision Atmos", folder: nil)
        #expect(BestVersion.order([sd, plain, hd, fhd, uhd, uhdDv], words: words) == [uhdDv, uhd, fhd, hd, plain, sd])
    }

    @Test func aCinemaRecordingRanksBelowEverythingElse() {
        let cam = Copy(title: "Whalefall (2026) (English) (HDCAM)", folder: "ENGLISH | 1080p"), sd = Copy(title: "Whalefall (2026)", folder: "SD")
        #expect(BestVersion.score(words(cam)) < BestVersion.score(words(sd)))
        #expect(BestVersion.order([cam, sd], words: words).first == sd)
    }

    @Test func copiesThatScoreTheSameKeepTheirOrder() {
        let x = Copy(title: "A", folder: nil), y = Copy(title: "B", folder: nil), z = Copy(title: "C", folder: nil)
        #expect(BestVersion.order([x, y, z], words: words) == [x, y, z])
    }

    @Test func aWordInsideAnotherWordIsNotARipOrAResolution() {
        #expect(BestVersion.score(["Tsunami (2004)"]) == 100 && BestVersion.score(["Scream"]) == 100)
    }

    @Test func theLibraryFindsEveryCopyOfAFilmUnderTheSameName() throws {
        let db = try TestSupport.makeDB()
        let a = try TestSupport.makeSource(db, name: "A"), b = try TestSupport.makeSource(db, name: "B")
        let one = TestSupport.movie(a, "1", "Heat", year: 1995), two = TestSupport.movie(b, "9", "Heat", year: 1995), other = TestSupport.movie(a, "2", "Alien")
        let indexer = CatalogIndexer(db: db)
        try indexer.commitMovies(source: a, categories: [], movies: [one, other]); try indexer.commitMovies(source: b, categories: [], movies: [two])
        let copies = try SQLiteCatalogRepository(db: db).movieCopies(of: one)
        #expect(Set(copies.map(\.id)) == Set([one.id, two.id]))
    }
}
