import Foundation
import Testing
@testable import REDDY

@MainActor @Suite("Round 11 fixes") struct Round11FixesTests {
    private func tile(_ name: String, _ kind: MusicFillTileKind) -> MusicFillTile {
        MusicFillTile(entity: .provisional(kind: .person, providerUID: "t:\(name)"), kind: kind, title: name, subtitle: "")
    }

    @Test func aHiddenSetSavedBeforeNamesWereKeptStillReads() throws {
        let old = Data(#"{"tracks":["p:1"],"artists":["ar-1"]}"#.utf8)
        let set = try JSONDecoder().decode(MusicHiddenSet.self, from: old)
        #expect(set.tracks == ["p:1"] && set.artists == ["ar-1"] && set.names.isEmpty)
    }

    @Test func anArtistHiddenByIdIsAlsoHiddenFromTheGraphPeopleShelvesByName() {
        var hidden = MusicHiddenSet()
        hidden.artists = ["ar-arijit"]; hidden.names = [MusicText.normalize("Arijit Singh")]
        let shelf = MusicFillShelf(id: "fill.personal.singers", title: "Singers you play", reason: "", scope: .related,
                                   tiles: [tile("Arijit Singh", .singer), tile("Shreya Ghoshal", .singer), tile("Arijit Singh", .film)])
        let out = MusicConnectedHomeBlock.withoutHidden([shelf], hidden: hidden)
        #expect(out[0].tiles.map(\.title) == ["Shreya Ghoshal", "Arijit Singh"], "the singer tile goes, a film with that name stays")
    }

    @Test func endOfTrackWithNothingLoadedIsNotStarted() {
        final class Empty: MusicSleepPlayback {
            var isPlaying = false, isBuffering = false
            var volume: Float = 1
            var position: TimeInterval = 0, duration: TimeInterval = 0
            var currentUID: String? = nil
            func pause() {}
            func armStopAfterCurrentSong() -> Bool { false }
            func disarmStopAfterCurrentSong() {}
        }
        let timer = MusicSleepTimer(player: Empty(), autoTick: false)
        timer.start(.endOfTrack)
        #expect(timer.preset == nil, "no track, so there is none to end")
    }

    @Test func aBandNamedWithAnAmpersandIsOneArtistWhenTheSourceGaveAnId() {
        // The rule the Related tab uses: only a credit with no id is split into names.
        let withID = MusicArtistRef(id: "ar-hall", name: "Hall & Oates")
        let plain = MusicArtistRef(id: "", name: "Hall & Oates")
        #expect(!withID.id.isEmpty && MusicLyricsQueryBuilder.names(withID.name).count > 1)
        #expect(plain.id.isEmpty)
    }
}
