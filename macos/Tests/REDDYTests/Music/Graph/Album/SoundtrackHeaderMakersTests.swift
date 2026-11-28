import Testing
import Foundation
@testable import REDDY

@Suite("Soundtrack header makers") struct SoundtrackHeaderMakersTests {
    @Test func wikiTemplateWordsAndMarkupAreNotPeople() {
        for bad in ["Infobox", "infobox", "Infobox film", "Plainlist", "{{ubl", "a=b", "x|y", "N/A", "7", " "] {
            #expect(!MusicSoundtrackNameGuard.isPersonName(bad), "\(bad) is not a person")
        }
    }
    @Test func realNamesOfManyScriptsPass() {
        for good in ["G. V. Prakash Kumar", "Anirudh Ravichander", "A. R. Rahman", "ఎం. ఎం. కీరవాణి", "इलैयाराजा", "宇多田ヒカル", "Björk", "Jr. NTR", "O'Neil"] {
            #expect(MusicSoundtrackNameGuard.isPersonName(good), "\(good) is a person")
        }
    }
    private func credit(_ id: String, _ name: String, detail: String? = nil) -> MusicSoundtrackCredit {
        MusicSoundtrackCredit(person: MusicSoundtrackPerson(id: MusicEntityID(kind: .person, token: String(repeating: id, count: MusicEntityID.tokenLength)), name: name, detail: detail), role: .composer)
    }
    @Test func theSameNameWithNoDescriptionIsListedOnceAndADifferentDescriptionStays() {
        let list = MusicSoundtrackNameGuard.listable([credit("A", "G. V. Prakash Kumar"), credit("B", "G. V. Prakash Kumar"), credit("C", "Infobox"),
                                                      credit("D", "John Williams", detail: "b. 1932"), credit("E", "John Williams", detail: "b. 1951")])
        #expect(list.map { String($0.person.id.token.first!) } == ["A", "D", "E"])
    }
}

@Suite("Graph never shows a template word as a person") struct GraphJunkPersonTests {
    @Test func aPersonRowNamedLikeAWikiTemplateIsNotFoundByAnyPage() async throws {
        let g = MusicInMemoryGraph()
        let junk = try await g.upsert(MusicEntityDraft(kind: .person, name: "Infobox"))
        _ = junk
        #expect(MusicPersonNameGuard.isShowable(kind: .person, name: "Infobox") == false)
        #expect(MusicPersonNameGuard.isShowable(kind: .person, name: "A. R. Rahman"))
        #expect(MusicPersonNameGuard.isShowable(kind: .film, name: "Infobox"), "only person rows are filtered, a film may carry any title")
    }
}

@Suite("Infobox names") struct InfoboxNamesTests {
    /// A real Telugu Wikipedia film page (2026): empty child `{{Infobox | decat = yes | child = yes | label1 = ... | data1 = }}` rows sit after `music` and `producer`.
    @Test func aNestedInfoboxRowNeverBecomesAName() {
        let music = " [[జి. వి. ప్రకాష్ కుమార్]] \n{{Infobox | decat = yes | child = yes\n| label1= ఆర్ట్ డైరెక్టర్‌\n| data1 = }}\n{{Infobox | decat = yes | child = yes\n| label1= ఫైట్స్\n| data1 = }}"
        let names = MusicWikipediaParser.names(fromInfobox: music)
        #expect(names == ["జి. వి. ప్రకాష్ కుమార్"], "\(names)")
        #expect(!names.contains { $0.lowercased().contains("infobox") })
    }

    @Test func aPlainListWithTheSpacedNameStillGivesItsPeople() {
        let producer = "{{plain list|\n*  పి. కిరణ్ (జెమిని కిరణ్)\n*   }}\n{{Infobox | decat = yes | child = yes\n| label1= సహ రచయితలు\n| data1 = }}"
        #expect(MusicWikipediaParser.names(fromInfobox: producer) == ["పి. కిరణ్"])
        #expect(MusicWikipediaParser.names(fromInfobox: "{{Plainlist|\n* [[Mohan Babu]]\n* Rasha Thadani\n}}") == ["Mohan Babu", "Rasha Thadani"])
        #expect(MusicWikipediaParser.names(fromInfobox: "[[Ajay Bhupathi]], Ravi Kumar and Sita Devi") == ["Ajay Bhupathi", "Ravi Kumar", "Sita Devi"])
    }
}
