import Testing
import Foundation
@testable import REDDY

@Suite("Search says what state it is in") struct SearchPhaseTests {
    private func result(_ id: String, _ title: String, _ kind: SearchResultKind) -> SearchResult {
        SearchResult(id: id, kind: kind, title: title, subtitle: "", sourceID: nil, sourceName: nil, artworkURL: nil, destination: .movie(id: id), score: 1)
    }

    @Test func aBlankQueryIsIdleAndATypedOneIsLoading() {
        #expect(SearchPhase.begin(query: "") == .idle && SearchPhase.begin(query: "   ") == .idle)
        #expect(SearchPhase.begin(query: "heat") == .loading)
    }

    @Test func nothingFoundIsEmptyNotAFailure() {
        #expect(SearchPhase.finish(GlobalSearchResults()) == .empty)
        var r = GlobalSearchResults(); r.byKind[.movie] = [result("m", "Heat", .movie)]
        #expect(SearchPhase.finish(r) == .results)
        #expect(SearchPhase.empty != SearchPhase.failed, "a failed search is its own state")
    }

    @Test func theExactTitleGoesFirstWhateverTheCaseOrAccents() {
        var r = GlobalSearchResults()
        r.byKind[.movie] = [result("a", "Heat Wave", .movie), result("b", "Café Society", .movie)]
        r.byKind[.series] = [result("c", "HEAT", .series)]
        #expect(r.exactMatch(for: "heat")?.id == "c")
        #expect(r.exactMatch(for: "cafe  society")?.id == "b", "accents and extra spaces do not matter")
        #expect(r.exactMatch(for: "heat w") == nil, "a partial title is not an exact match")
        #expect(r.exactMatch(for: "  ") == nil)
    }

    @Test func aMovieBeatsAChannelWithTheSameName() {
        var r = GlobalSearchResults()
        r.byKind[.channel] = [result("ch", "Sky Sports", .channel)]
        r.byKind[.movie] = [result("mv", "Sky Sports", .movie)]
        #expect(r.exactMatch(for: "sky sports")?.id == "mv")
    }
}
