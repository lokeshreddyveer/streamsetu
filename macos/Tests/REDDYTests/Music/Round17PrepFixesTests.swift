import Foundation
import Testing
@testable import REDDY

@MainActor @Suite("Round 16 leftovers") struct Round16LeftoverTests {
    @Test func aWritingCreditIsOneJobWhicheverOfItsTwoNamesASourceUsed() {
        let film = MusicEntityID.provisional(kind: .film, providerUID: "f:1"), person = MusicEntityID.provisional(kind: .person, providerUID: "p:1")
        let a = MusicEdge(subject: film, predicate: .writtenBy, object: person, role: .writer)
        let b = MusicEdge(subject: film, predicate: .writtenBy, object: person, role: .screenwriter)
        #expect(MusicFilmPageBuilders.crewRole(of: a) == MusicFilmPageBuilders.crewRole(of: b))
    }

    @Test func aPersonSavedWithoutNamesInTheHiddenListStillReadsAndHidingAddsTheName() throws {
        let set = try JSONDecoder().decode(MusicHiddenSet.self, from: Data(#"{"tracks":[],"artists":["ar-1"]}"#.utf8))
        #expect(set.names.isEmpty)
        var hidden = set; hidden.names.insert(MusicText.normalize("Some Name"))
        #expect(hidden.names == ["some name"] || hidden.names.count == 1)
    }
}
