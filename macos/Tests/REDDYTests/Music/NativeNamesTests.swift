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
