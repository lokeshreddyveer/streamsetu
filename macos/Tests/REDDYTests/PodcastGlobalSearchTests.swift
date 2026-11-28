import Testing
import Foundation
@testable import REDDY

@Suite("Podcasts in the app-wide search", .serialized) struct PodcastGlobalSearchTests {
    private func show(_ t: String) -> PodcastSubscription { PodcastSubscription(feedURL: URL(string: "https://x.test/\(t).xml")!, title: t, author: "A") }

    @Test func rowsComeBackOnlyWhenConnectedAndLongEnough() async {
        PodcastGlobalSearch.uninstall()
        #expect(await PodcastGlobalSearch.rows(for: "history").isEmpty)
        PodcastGlobalSearch.installForTesting { q, _ in [PodcastGlobalSearch.row(self.show("History Hour"), query: q, position: 0)] }
        #expect(await PodcastGlobalSearch.rows(for: "h").isEmpty)
        let rows = await PodcastGlobalSearch.rows(for: "history")
        #expect(rows.count == 1 && rows[0].kind == .podcast && rows[0].title == "History Hour")
        PodcastGlobalSearch.uninstall()
    }

    @Test func theAllTabIncludesPodcastsAndTheyJoinTheResults() async {
        #expect(SearchTab.all.kinds.contains(.podcast))
        PodcastGlobalSearch.installForTesting { q, _ in [PodcastGlobalSearch.row(self.show("Tech Talk"), query: q, position: 0)] }
        let out = await GlobalSearchService.withExtras(GlobalSearchResults(), query: "tech", kinds: SearchTab.all.kinds, limit: 24)
        #expect(out.byKind[.podcast]?.count == 1)
        let movies = await GlobalSearchService.withExtras(GlobalSearchResults(), query: "tech", kinds: SearchTab.movies.kinds, limit: 24)
        #expect(movies.byKind[.podcast] == nil)
        PodcastGlobalSearch.uninstall()
    }
}
