import Foundation
import Testing
@testable import REDDY

/// "More <language>" on Listen Now follows the language the person's songs are really in. Titles are mostly in Latin letters and say nothing, so the language comes from the graph (a source's statement,
/// or the song's film or album); and the shelf is not limited to songs already played: new songs in that language from the active source are mixed in. No language is named in the engine: every language the
/// app knows behaves the same, which is what these tests run through.
@Suite("Listen Now: the language shelf")
struct HomeLanguageShelfTests {
    private func persona(language: MusicLanguage?, played: Int = 160, discovered: Int = 0) -> HomeSignals {
        var s = HomeSignals()
        let tracks = (0..<played).map { HomePersona.track("m\($0)", "Song \($0)", artist: "Artist \($0 % 16)", album: "Album \($0 % 16)") }     // every title in Latin letters
        s.history = tracks.enumerated().map { HomePersona.play($1, daysAgo: Double($0 % 40)) }
        if let language {
            for t in tracks { s.trackLanguages[t.uid] = language.rawValue }
            let fresh = (0..<discovered).map { HomePersona.track("new\($0)", "Fresh \($0)", artist: "New Artist \($0)") }
            s.languageSongs[language.rawValue] = fresh.map { var i = HomeItem.make($0); i.bucket = language.rawValue; return i }
        }
        return s
    }

    @Test func latinTitlesAloneMakeNoLanguageShelf() {
        let feed = HomeEngine.compose(persona(language: nil), ctx: HomePersona.ctx(seed: 1))
        #expect(!feed.sections.contains { $0.kind == .languageMix })
    }

    @Test func theGraphsLanguageMakesTheShelfForEveryLanguageAlike() {
        for lang in MusicLanguage.pickable {
            let feed = HomeEngine.compose(persona(language: lang), ctx: HomePersona.ctx(seed: 3))
            let shelf = feed.sections.first { $0.kind == .languageMix }
            #expect(shelf?.id == "languageMix-" + lang.rawValue, "\(lang.englishName)")
            #expect(shelf?.title == "More " + lang.englishName, "\(lang.englishName)")
            #expect((shelf?.items.count ?? 0) >= 5, "\(lang.englishName)")
            #expect(feed.sections.filter { $0.kind == .languageMix }.count == 1, "only the one language the person plays")
        }
    }

    @Test func newSongsInTheLanguageAreMixedInSoTheShelfIsNotLimitedToWhatWasPlayed() {
        for lang in MusicLanguage.pickable {
            let feed = HomeEngine.compose(persona(language: lang, discovered: 12), ctx: HomePersona.ctx(seed: 5))
            let items = feed.sections.first { $0.kind == .languageMix }?.items ?? []
            let new = items.filter { $0.id.contains("new") }
            #expect(!new.isEmpty, "\(lang.englishName): no new song in the shelf")
            #expect(items.count > items.count - new.count)
            #expect(items.count <= 16)
        }
    }

    @Test func aSongAlreadyPlayedIsNotOfferedAgainAsNew() {
        let lang = MusicLanguage.pickable[0]
        var s = persona(language: lang)
        let played = s.history[0].track
        var dup = HomeItem.make(played); dup.bucket = lang.rawValue
        s.languageSongs[lang.rawValue] = [dup] + (0..<10).map { var i = HomeItem.make(HomePersona.track("n\($0)", "Fresh \($0)", artist: "New \($0)")); i.bucket = lang.rawValue; return i }
        let items = HomeEngine.compose(s, ctx: HomePersona.ctx(seed: 7)).sections.first { $0.kind == .languageMix }?.items ?? []
        #expect(items.filter { $0.id == dup.id }.count <= 1, "at most the one copy that is the person's own")
        #expect(items.filter { $0.id.contains("n") && $0.title.hasPrefix("Fresh") }.count >= 1)
    }
}
