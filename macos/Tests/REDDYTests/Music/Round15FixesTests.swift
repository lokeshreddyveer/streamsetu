import Foundation
import Testing
@testable import REDDY

@MainActor @Suite("Round 15 fixes") struct Round15FixesTests {
    private func library() -> MusicLibrary {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
        return MusicLibrary(directory: dir, debounce: .milliseconds(10))
    }

    @Test func blockingAnArtistWithNoIdBlocksNobody() {
        let lib = library()
        let plain = MusicArtistRef(id: "", name: "Some Singer")
        lib.toggleBlacklist(artist: plain)
        #expect(!lib.isBlacklisted(artist: plain), "an empty id is nobody: nothing was stored")
        let other = MusicTrack(id: "1", providerID: "p", title: "T", durationMs: 1000, artists: [MusicArtistRef(id: "", name: "Another")])
        #expect(!lib.isBlacklisted(other), "a song with a plain-text credit is not blocked by it")
        let real = MusicArtistRef(id: "ar-1", name: "Real")
        lib.toggleBlacklist(artist: real)
        #expect(lib.isBlacklisted(artist: real))
        #expect(lib.isBlacklisted(MusicTrack(id: "2", providerID: "p", title: "U", durationMs: 1000, artists: [real])))
    }

    @Test func aBlockedPersonIsTakenOutOfTheGraphShelvesByName() {
        func tile(_ name: String, _ kind: MusicFillTileKind) -> MusicFillTile { MusicFillTile(entity: .provisional(kind: .person, providerUID: "t:\(name)"), kind: kind, title: name, subtitle: "") }
        var blocked = MusicHiddenSet(); blocked.names = [MusicText.normalize("Blocked Singer")]
        let shelf = MusicFillShelf(id: "s", title: "Singers", reason: "", scope: .related, tiles: [tile("Blocked Singer", .singer), tile("Fine Singer", .singer)])
        #expect(MusicConnectedHomeBlock.withoutHidden([shelf], hidden: blocked)[0].tiles.map(\.title) == ["Fine Singer"])
    }

    @Test func theWipeKeysCoverTheHiddenListAndTheBecauseMemory() {
        #expect(MusicDefaultsKeys.activity.contains("music.hiddenRecommendations"))
        #expect(MusicDefaultsKeys.activity.contains("music.home.becauseRecent"))
    }
}
