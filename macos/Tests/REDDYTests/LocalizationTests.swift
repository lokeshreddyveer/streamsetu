import Testing
import Foundation
@testable import REDDY

@Suite("Hindi and Telugu wording") struct LocalizationTests {
    private func table(_ code: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localization/\(code).lproj/Localizable.strings")
        let dict = NSDictionary(contentsOf: url) as? [String: String]            // the .strings format is a property list
        return try #require(dict, "\(code) did not parse")
    }

    @Test func bothLanguagesHaveTheSameTextsAndNoneIsEmpty() throws {
        let hi = try table("hi"), te = try table("te")
        #expect(Set(hi.keys) == Set(te.keys))
        #expect(hi.count > 400)
        for (k, v) in hi { #expect(!v.isEmpty, "hi: \(k)") }
        for (k, v) in te { #expect(!v.isEmpty, "te: \(k)") }
    }

    @Test func theLanguagePickerKnowsItsLanguages() {
        #expect(AppLanguage.allCases.map(\.rawValue) == ["system", "en", "hi", "te"])
        #expect(AppLanguage.system.locale == nil && AppLanguage.hi.locale?.identifier == "hi")
        #expect(AppLanguage.te.label == "తెలుగు")
    }
}
