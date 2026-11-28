import Testing
import Foundation
@testable import REDDY

@Suite("Soundtrack credits: one person, one chip") struct SoundtrackCreditsMergeTests {
    private func credit(_ name: String, _ role: MusicRole, token: String, songs: Int = 0, order: Int = 0) -> MusicSoundtrackCredit {
        MusicSoundtrackCredit(person: MusicSoundtrackPerson(id: MusicEntityID(kind: .person, token: token), name: name), role: role, songCount: songs, level: .song, status: .verified, order: order)
    }
    private func mergedAll(_ c: [MusicSoundtrackCredit]) -> (credits: [MusicSoundtrackCredit], also: [MusicEntityID: String]) {
        MusicSoundtrackDisambiguator.mergedByName(c, kind: { MusicSoundtrackBuild.kind(for: $0) }, roleName: { "\($0.rawValue)" }, also: { "also " + $0.joined(separator: ", ") })
    }
    private func merged(_ c: [MusicSoundtrackCredit]) -> [MusicSoundtrackCredit] { mergedAll(c).credits }

    @Test func theSamePersonAsComposerAndSingerIsOneChipWithTheOtherRoleNamed() {
        let r = mergedAll([credit("Vijai Bulganin", .composer, token: "A"), credit("Karthik", .singer, token: "B"), credit("Vijai Bulganin", .singer, token: "C", songs: 1)])
        #expect(r.credits.count == 2)
        let v = r.credits.first { $0.person.name == "Vijai Bulganin" }
        #expect(v?.role == .composer && v?.songCount == 1)
        #expect(r.also[MusicEntityID(kind: .person, token: "A")] == "also singer")
    }

    @Test func twoEntitiesOfOneNameInTheSameRoleAreOneChipWithoutAnExtraLine() {
        let out = merged([credit("Karthik", .singer, token: "A", songs: 2), credit("Karthik", .singer, token: "B", songs: 5)])
        #expect(out.count == 1 && out[0].songCount == 5)
        #expect(mergedAll([credit("Karthik", .singer, token: "A", songs: 2), credit("Karthik", .singer, token: "B", songs: 5)]).also.isEmpty)
    }

    @Test func differentPeopleAreNeverMerged() {
        let out = merged([credit("Karthik", .singer, token: "A"), credit("Vijai Bulganin", .composer, token: "B")])
        #expect(out.count == 2)
    }

    @Test func spellingVariantsOfOneNameMerge() {
        let out = merged([credit("Vijai Bulganin", .composer, token: "A"), credit("vijai  bulganin", .singer, token: "B")])
        #expect(out.count == 1)
    }

    @Test func twoPeopleWhoseDescriptionsDifferAreNeverMerged() {
        func person(_ token: String, _ detail: String?) -> MusicSoundtrackCredit {
            MusicSoundtrackCredit(person: MusicSoundtrackPerson(id: MusicEntityID(kind: .person, token: token), name: "Raj Kapoor", detail: detail), role: .singer, level: .song, status: .verified)
        }
        #expect(merged([person("A", "1924"), person("B", "playback singer")]).count == 2)
        #expect(merged([person("A", "1924"), person("B", nil)]).count == 2)             // one described, one not: not enough to say it is one person
        #expect(merged([person("A", "1924"), person("B", "1924")]).count == 1)          // the same description twice: one person
    }
}
