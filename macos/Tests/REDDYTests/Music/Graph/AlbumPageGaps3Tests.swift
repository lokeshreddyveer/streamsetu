import Foundation
import Testing
@testable import REDDY

@Suite struct AlbumPageGaps3Tests {
    @Test func theRawCreditsKeepEveryRoleOfEveryPerson() async throws {
        let g = try await SoundtrackFixtureGraph.build()
        let c = await MusicSoundtrackBuild.credits(MusicSoundtrackReader(g.graph), id: g.album)
        let mergedPairs = Set(c.groups.flatMap(\.credits).map { $0.person.id.rawValue + "|" + $0.role.rawValue })
        let rawPairs = Set(c.raw.map { $0.person.id.rawValue + "|" + $0.role.rawValue })
        #expect(rawPairs.isSuperset(of: mergedPairs))
        #expect(rawPairs.count == c.raw.count, "one credit per person and role")
        #expect(c.raw.contains { $0.role == .singer })
    }

    @Test func aSingleWithOneSongHasNoPills() {
        let f = MusicAlbumPillRules.Facts(subkind: MusicAlbumSubkind.single.rawValue, trackCount: 1, hasCredits: true, hasAbout: true)
        #expect(MusicAlbumPillRules.pills(f).isEmpty)
    }

    @Test func anAlbumWithCreditsOffersTheCreditsPill() {
        let f = MusicAlbumPillRules.Facts(subkind: nil, trackCount: 8, hasCredits: true)
        #expect(MusicAlbumPillRules.pills(f).contains(.credits))
    }

    @Test func noEditionMeansNoSwitchedOnSourceCouldBeAsked() {
        #expect(MusicAlbumPageLogic.isNoEdition(loadedCount: 0, failed: false, hadEdition: false))
        #expect(!MusicAlbumPageLogic.isNoEdition(loadedCount: 0, failed: false, hadEdition: true), "a source answered empty")
        #expect(!MusicAlbumPageLogic.isNoEdition(loadedCount: 0, failed: true, hadEdition: false))
        #expect(!MusicAlbumPageLogic.isNoEdition(loadedCount: 3, failed: false, hadEdition: false))
    }
}
