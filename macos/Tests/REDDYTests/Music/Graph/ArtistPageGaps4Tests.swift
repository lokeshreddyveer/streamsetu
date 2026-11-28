import Foundation
import Testing
@testable import REDDY

@MainActor @Suite("Artist page gaps 4") struct ArtistPageGaps4Tests {
    @Test func twoRoleCollaboratorTakesTheFreeSlot() {
        let a = MusicEntityID.provisional(kind: .person, name: "A")
        let b = MusicEntityID.provisional(kind: .person, name: "B")
        var e = MusicPersonEntry(id: b, name: "B", kind: .person)
        e.roles = [.singer, .composer]
        let preset = MusicCombinePreset.make(person: a, personName: "A", view: .singer, other: e)
        #expect(preset.isPair)
        #expect(preset.composer?.id == b)
        #expect(preset.singer?.id == a)
    }

    @Test func twoRoleCollaboratorWithNoFreeSlotIsNotAPair() {
        let a = MusicEntityID.provisional(kind: .person, name: "A")
        let b = MusicEntityID.provisional(kind: .person, name: "B")
        var e = MusicPersonEntry(id: b, name: "B", kind: .person)
        e.roles = [.singer, .performer]
        let preset = MusicCombinePreset.make(person: a, personName: "A", view: .singer, other: e)
        #expect(!preset.isPair)
    }
}
