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

    /// New wording must come with Hindi and Telugu: the texts of the artwork settings, the status lines and the tile menu are checked by name, and everything in the "added" block must differ from English.
    @Test func newArtworkAndMenuWordingHasHindiAndTelugu() throws {
        let hi = try table("hi"), te = try table("te")
        var keys: [String] = [ArtworkSettingsModel.optionalNote, ArtworkSettingsModel.sentNote, ArtworkSettingsModel.switchNote, ArtworkSettingsModel.brokenBuiltIn,
                              ArtworkMatchStatus(state: .off).line, ArtworkMatchStatus(state: .noKey).line, ArtworkMatchStatus(state: .complete).line, MetadataMatchService.MatchError.noKey.errorDescription!, MetadataMatchService.MatchError.switchedOff.errorDescription!,
                              "Match now", "Match artwork in the background", "Use mobile data", "Test Key", "Using your key", "Using the built-in key", "Undo"]
        for entry in TileMenu.entries(.init(kind: .title)) + TileMenu.entries(.init(kind: .continueWatching)) + TileMenu.entries(.init(kind: .channel)) where !entry.title.contains(" of ") && !entry.title.contains("Favo") { keys.append(entry.title) }
        for k in keys { #expect(hi[k] != nil && te[k] != nil, "no Hindi/Telugu for: \(k)") }
        for k in keys where !k.hasPrefix("TMDB") { #expect(hi[k] != k && te[k] != k, "not translated: \(k)") }
        for (code, t) in [("hi", hi), ("te", te)] { #expect(t.values.filter { $0.contains("%@") }.allSatisfy { v in v.components(separatedBy: "%@").count == 2 }, "\(code): one placeholder each") }
    }

    /// Words built in code (durations, "left", the rating label) go through `Localized` and `Text` keys: both languages must have them.
    @Test func durationAndRatingWordsHaveHindiAndTelugu() throws {
        let hi = try table("hi"), te = try table("te")
        for k in ["%dh %dm", "%dh", "%dm", "%@ left", "Resume · %@ left", "almost done", "Rated %@"] {
            #expect(hi[k] != nil && te[k] != nil && hi[k] != k && te[k] != k, "missing or untranslated: \(k)")
        }
        #expect(DurationFormatter.short(7800) == "2h 10m" && DurationFormatter.short(59) == "1m")
        #expect(TitlePageLogic.remainingText(2700) == "45m left")
    }

    @Test func theLanguagePickerKnowsItsLanguages() {
        #expect(AppLanguage.allCases.map(\.rawValue) == ["system", "en", "hi", "te"])
        #expect(AppLanguage.system.locale == nil && AppLanguage.hi.locale?.identifier == "hi")
        #expect(AppLanguage.te.label == "తెలుగు")
    }

    /// The Streaming Services settings wording: every fixed text of the model and the section, in both languages, translated and with at most one placeholder.
    @Test func streamingServicesSettingsWordingHasHindiAndTelugu() throws {
        let hi = try table("hi"), te = try table("te")
        var keys = ["Streaming Services", "Pin to Top Bar", "Unpin from Top Bar", "Pin %@ to the top bar", "Unpin %@ from the top bar", "Move Left", "Move Right", "Move %@ left", "Move %@ right",
                    "Open %@", "Clear Data…", "Clear Data", "Clear data for %@", "Clear data for %@?", "Reset Order", "In top bar", "Not in top bar",
                    "Data cleared for %@.", "Could not clear all data for %@.", "Clearing data is not available yet.",
                    "Distribution permission: unresolved for every service", "Distribution permission: unresolved for %lld services",
                    "checked by you", "checked by you on %@",
                    "This signs you out of %@ and removes its saved data from this Mac. Your other services stay signed in.",
                    "Google sign-in is not supported in this view, so this service is used signed out."]
        keys += ["available", "unverified", "disabled", "registered"].map { StreamingServicesSettingsModel.badge(ServiceAvailability(rawValue: $0)!) }
        keys += CompatibilityResult.Check.allCases.map(StreamingServicesSettingsModel.passedWords) + CompatibilityResult.Check.allCases.map(StreamingServicesSettingsModel.failedWords)
        for k in keys { #expect(hi[k] != nil && te[k] != nil, "no Hindi/Telugu for: \(k)"); #expect(hi[k] != k && te[k] != k, "not translated: \(k)") }
    }
}
