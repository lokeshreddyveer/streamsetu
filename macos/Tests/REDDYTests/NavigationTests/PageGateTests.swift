import Testing
@testable import REDDY

@Suite("Paging keeps working after the query changes") struct PageGateTests {
    @Test func onePageAtATime() {
        var g = PageGate()
        let first = g.begin()
        #expect(first != nil && g.loading)
        let second = g.begin()
        #expect(second == nil, "a second read for the same query is refused")
        let used = g.end(first!)
        #expect(used && !g.loading)
        let next = g.begin()
        #expect(next != nil, "the next page can be asked for")
    }

    @Test func aQueryChangeDuringAReadDoesNotDisablePagingForever() {
        var g = PageGate()
        let stale = g.begin()!
        g.reset()                                   // source, folder, favourites, list or search changed while the page was being read
        #expect(!g.loading, "the flag is cleared by the change itself")
        let staleUsed = g.end(stale)
        #expect(!staleUsed, "the old read's rows are dropped")
        let fresh = g.begin()
        #expect(fresh != nil, "pages can be read again for the new query")
        let freshUsed = g.end(fresh!)
        #expect(freshUsed)
    }

    @Test func aStaleReadCannotClearTheNewerReadsFlag() {
        var g = PageGate()
        let stale = g.begin()!
        g.reset()
        let fresh = g.begin()!
        let staleUsed = g.end(stale)
        #expect(!staleUsed)
        #expect(g.loading, "the newer read is still in progress")
        let duplicate = g.begin()
        #expect(duplicate == nil, "so a duplicate read is still refused")
        let freshUsed = g.end(fresh)
        #expect(freshUsed && !g.loading)
    }

    @Test func everyKindOfChangeCanHappenMidRead() {
        for _ in ["source", "folder", "favourites", "list", "search"] {
            var g = PageGate()
            let s = g.begin()!
            g.reset()
            _ = g.end(s)
            let again = g.begin()
            #expect(again != nil)
        }
    }
}
