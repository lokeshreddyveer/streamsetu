import Testing
import Foundation
@testable import REDDY

@Suite("Page snapshot cache") @MainActor struct PageSnapshotCacheTests {
    @Test func aPageComesBackOnlyUnderTheRevisionItWasStoredUnder() {
        let c = PageSnapshotCache<String, [Int]>()
        c.put("movies|all", value: [1, 2, 3], cost: 3, revision: 7)
        #expect(c.get("movies|all", revision: 7) == [1, 2, 3])
        #expect(c.get("movies|all", revision: 8) == nil, "a changed catalog, profile or lock must never be answered from the cache")
        #expect(c.get("movies|all", revision: 7) == nil, "and the stale entry is gone, not kept")
        #expect(c.count == 0)
    }

    @Test func clearingForgetsEverythingAtOnce() {
        let c = PageSnapshotCache<String, [Int]>()
        for i in 0..<5 { c.put("k\(i)", value: [i], cost: 1, revision: 1) }
        c.clear()
        #expect(c.count == 0); #expect(c.totalCost == 0)
        for i in 0..<5 { #expect(c.get("k\(i)", revision: 1) == nil) }
    }

    @Test func theLeastRecentlyUsedPageIsDroppedFirstAndUseRefreshesIt() {
        let c = PageSnapshotCache<String, Int>(maxEntries: 3, maxCost: 100)
        c.put("a", value: 1, cost: 1, revision: 1); c.put("b", value: 2, cost: 1, revision: 1); c.put("c", value: 3, cost: 1, revision: 1)
        _ = c.get("a", revision: 1)                      // a is now the most recent
        c.put("d", value: 4, cost: 1, revision: 1)       // b is the oldest and goes
        #expect(c.get("b", revision: 1) == nil)
        #expect(c.get("a", revision: 1) == 1); #expect(c.get("c", revision: 1) == 3); #expect(c.get("d", revision: 1) == 4)
    }

    @Test func theTotalSizeIsBoundedNotJustTheNumberOfPages() {
        let c = PageSnapshotCache<String, Int>(maxEntries: 10, maxCost: 10)
        c.put("a", value: 1, cost: 6, revision: 1); c.put("b", value: 2, cost: 6, revision: 1)
        #expect(c.totalCost <= 10); #expect(c.get("a", revision: 1) == nil); #expect(c.get("b", revision: 1) == 2)
        c.put("huge", value: 3, cost: 11, revision: 1)
        #expect(c.get("huge", revision: 1) == nil, "a page bigger than the whole budget is not kept")
    }

    @Test func storingAKeyAgainReplacesItAndKeepsTheCostRight() {
        let c = PageSnapshotCache<String, Int>(maxEntries: 5, maxCost: 100)
        c.put("a", value: 1, cost: 10, revision: 1); c.put("a", value: 2, cost: 4, revision: 2)
        #expect(c.count == 1); #expect(c.totalCost == 4); #expect(c.get("a", revision: 2) == 2)
    }

    @Test func differentFoldersSortsAndFiltersAreDifferentPages() {
        struct Key: Hashable { let folder: String; let sort: String; let filter: String }
        let c = PageSnapshotCache<Key, [String]>()
        c.put(Key(folder: "Telugu", sort: "added", filter: ""), value: ["A"], cost: 1, revision: 1)
        #expect(c.get(Key(folder: "Telugu", sort: "name", filter: ""), revision: 1) == nil)
        #expect(c.get(Key(folder: "Hindi", sort: "added", filter: ""), revision: 1) == nil)
        #expect(c.get(Key(folder: "Telugu", sort: "added", filter: "4K"), revision: 1) == nil)
        #expect(c.get(Key(folder: "Telugu", sort: "added", filter: ""), revision: 1) == ["A"])
    }
}
