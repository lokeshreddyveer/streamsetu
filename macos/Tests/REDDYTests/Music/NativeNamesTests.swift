import Foundation
import Testing
@testable import REDDY

@Suite struct NativeNamesTests {
    @Test func latinTextIsLatinAndOtherScriptsAreNot() {
        #expect(MusicNativeNames.isLatin("Mate Rani"))
        #expect(!MusicNativeNames.isLatin("మాటే రాణి"))
        #expect(!MusicNativeNames.isLatin("123"))
    }

    @Test func theAliasIsPickedByTheSongsLanguageNeverByTheFirstOneFound() {
        let picked = MusicNativeNames.pick(language: .telugu, from: ["Mate Rani", "மாதே ராணி", "మాటే రాణి"])
        #expect(picked == "మాటే రాణి")
        #expect(MusicNativeNames.pick(language: .korean, from: ["Mate Rani", "మాటే రాణి"]) == nil)
    }
}

@Suite struct NativeNamesFromListeningTests {
    @Test func aSongWithNoKnownLanguageUsesTheNameInALanguageThePersonListensTo() {
        let names = ["Mate Rani", "மாதே ராணி", "మాటే రాణి"]
        #expect(MusicNativeNames.pickPreferred([.telugu], from: names) == "మాటే రాణి")
        #expect(MusicNativeNames.pickPreferred([.tamil], from: names) == "மாதே ராணி")
        #expect(MusicNativeNames.pickPreferred([.telugu, .tamil], from: names) == "மாதே ராணி", "the order of the names decides between two the person listens to")
        #expect(MusicNativeNames.pickPreferred([.korean], from: names) == nil, "a language they do not listen to is never used")
        #expect(MusicNativeNames.pickPreferred([], from: names) == nil, "with no listening, nothing is guessed")
        #expect(MusicNativeNames.pickPreferred([.telugu], from: ["Mate Rani"]) == nil, "Latin names are not native names")
    }

    @Test func everyLanguageTheAppKnowsIsFoundByItsNameAndPlainLatinIsNotALanguageLabel() {
        for l in MusicLanguage.pickable { #expect(MusicLanguage(stated: l.englishName) == l, "\(l.englishName)") }
        #expect(MusicLanguage(stated: "Latin") == nil, "a genre called Latin stays a genre")
        #expect(MusicLanguage(stated: "Pop") == nil)
    }
}
