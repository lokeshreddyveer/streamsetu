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

    /// The wording of the app's main sidebar: menu entries, search box, playlist menu and every shortcut title, in both languages and translated.
    @Test func mainSidebarWordingHasHindiAndTelugu() throws {
        let hi = try table("hi"), te = try table("te")
        var keys = ["Move to Top", "Move Up", "Move Down", "Move to Bottom", "Hide Folder", "Unlock Folder", "Lock Folder with PIN", "Locked", "No matching folders", "Add playlist", "Clear folder search",
                    "Search sidebar folders", "Search folders", "none", "No playlist", "All Playlists", "Uncategorized", "Select playlist", "Playlists", "Remove…", "Expand sidebar", "Collapse sidebar", "Folders", "Groups"]
        keys += Shortcut.allCases.map(\.title)
        keys += AppTab.allCases.map(\.title)
        for k in keys { #expect(hi[k] != nil && te[k] != nil, "no Hindi/Telugu for: \(k)") }
        for k in keys { #expect(hi[k] != k && te[k] != k, "not translated: \(k)") }
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
                    "This service is used signed out."]
        keys += ["available", "unverified", "disabled", "registered"].map { StreamingServicesSettingsModel.badge(ServiceAvailability(rawValue: $0)!) }
        keys += CompatibilityResult.Check.allCases.map(StreamingServicesSettingsModel.passedWords) + CompatibilityResult.Check.allCases.map(StreamingServicesSettingsModel.failedWords)
        for k in keys { #expect(hi[k] != nil && te[k] != nil, "no Hindi/Telugu for: \(k)"); #expect(hi[k] != k && te[k] != k, "not translated: \(k)") }
    }

    /// The Podcasts destination and the redesigned top bar: every new fixed text, in both languages, translated.
    @Test func podcastsAndTopBarWordingHasHindiAndTelugu() throws {
        let hi = try table("hi"), te = try table("te")
        let keys = ["Podcasts", TopBarItem.collapsedLabel, "Icon and Name", "Icon Only", "Name Only", "Top bar", "Reset to Defaults",
                    "Choose how each item at the top of the window is shown. If the window is narrow, names turn into icons from the right.", "Home", "Live TV", "Movies", "Series", "TV Guide",
                    "Find a show", "Results", "Following", "Looking…", "Search shows, or paste a feed address", "Unfollow", "Follow", "%lld episodes",
                    "Search uses Apple's public podcast directory. Nothing about you is sent besides the words you search for.",
                    "Search Apple's public podcast directory, or paste a feed address, then follow a show to keep it here. Your place in each episode is remembered."]
        for k in keys { #expect(hi[k] != nil && te[k] != nil, "no Hindi/Telugu for: \(k)"); #expect(hi[k] != k && te[k] != k, "not translated: \(k)") }
        #expect(hi["StreamSetu, shows Home, Live TV, Movies, Series and TV Guide"] == nil, "the superseded label is gone")
    }
}
