import Testing
import Foundation
@testable import REDDY

/// The three cleaning rules read one vocabulary. The identity lists are frozen subsets; the artwork cleaner reads every language word.
@Suite("Title vocabulary") struct TitleVocabularyTests {
    @Test func everyRuleDrawsFromTheOneVocabulary() {
        #expect(TitleVocabulary.identityLanguageWords.isSubset(of: TitleVocabulary.languageWords))
        #expect(Set(IdentityKey.languageNames.keys) == TitleVocabulary.identityLanguageWords)
        #expect(TitleVocabulary.languageWords.isSubset(of: ArtworkNameCleaner.languages), "a language the identity rule knows is also stripped from a search name")
        #expect(MetadataNormalizer.qualityTokens == TitleVocabulary.channelQualityTokens)
    }

    @Test func theFrozenIdentityKeyIsUnchanged() {
        #expect(IdentityKey.version == 1)
        #expect(IdentityKey.make("The Matrix (1999) Hindi Dubbed FHD") == "matrix")
        #expect(IdentityKey.make("Polish Wedding") == "polish wedding", "real title words stay in the key")
        #expect(IdentityKey.make("Dutch (2021)") == "dutch")
    }

    @Test func aTitleWordThatIsAlsoALanguageStaysInTheMiddleOfASearchName() {
        #expect(ArtworkNameCleaner.clean("Polish Wedding (2022)") == "Polish Wedding")
        #expect(ArtworkNameCleaner.clean("TELUGU | Pushpa The Rise (Telugu) FHD 2026") == "Pushpa The Rise")
    }
}
