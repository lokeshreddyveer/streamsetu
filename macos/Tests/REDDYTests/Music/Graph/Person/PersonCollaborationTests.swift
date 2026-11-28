import Foundation
import Testing
@testable import REDDY

@Suite struct PersonCollaborationTests {
    private func id(_ k: MusicEntityKind, _ s: String) -> MusicEntityID { .derive(kind: k, aliasKey: s) }

    @Test func countsDistinctWorksAndOrdersStably() {
        let me = id(.person, "me"), a = id(.person, "a"), b = id(.person, "b")
        let w1 = id(.recording, "1"), w2 = id(.recording, "2"), w3 = id(.recording, "3")
        let obs = [
            MusicCreditObservation(work: w1, agent: a, role: .composer, level: .song, confidence: 0.9),
            MusicCreditObservation(work: w1, agent: a, role: .lyricist, level: .song, confidence: 0.9),   // same agent, same work: counts once
            MusicCreditObservation(work: w2, agent: a, role: .composer, level: .song, confidence: 0.9),
            MusicCreditObservation(work: w3, agent: b, role: .composer, level: .song, confidence: 0.9),
            MusicCreditObservation(work: w1, agent: me, role: .singer, level: .song, confidence: 1),
        ]
        let r = MusicCollaboration.rank(obs, excluding: [me])
        #expect(r.map(\.id) == [a, b] && r[0].workCount == 2 && r[0].roles == [.composer, .lyricist] && r[1].workCount == 1)
        #expect(MusicCollaboration.rank(obs, excluding: [me], minCount: 2).map(\.id) == [a])
        #expect(MusicCollaboration.rank(obs, excluding: [me], limit: 1).count == 1)
    }

    @Test func songLevelOutweighsFilmLevelOnATie() {
        let a = id(.person, "a"), b = id(.person, "b"), w = id(.recording, "w")
        let r = MusicCollaboration.rank([MusicCreditObservation(work: w, agent: a, role: .composer, level: .film, confidence: 0.9),
                                         MusicCreditObservation(work: w, agent: b, role: .composer, level: .song, confidence: 0.9)], excluding: [])
        #expect(r.map(\.id) == [b, a])
    }

    @Test func orderIsDeterministicAcrossInputOrder() {
        let ids = (0..<6).map { id(.person, "p\($0)") }
        let w = id(.recording, "w")
        let obs = ids.map { MusicCreditObservation(work: w, agent: $0, role: .singer, level: .song, confidence: 0.8) }
        #expect(MusicCollaboration.rank(obs, excluding: []).map(\.id) == MusicCollaboration.rank(obs.reversed(), excluding: []).map(\.id))
    }
}
