import Testing
import Foundation
@testable import REDDY

@Suite("Retention plan") struct RetentionPlanTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func used(_ pairs: [(ProviderID, Double)]) -> [ProviderID: Date] { Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, t0.addingTimeInterval($0.1)) }) }

    @Test func releasesTheLeastRecentlyUsedFirstAndNeverTheVisibleOne() {
        let live: [ProviderID] = [.netflix, .hulu, .youtube, .peacock]
        let u = used([(.netflix, 1), (.hulu, 4), (.youtube, 3), (.peacock, 2)])
        #expect(RetentionPlan.releaseList(live: live, lastUsed: u, visible: .hulu, budget: 2) == [.netflix, .peacock])
        #expect(RetentionPlan.releaseList(live: live, lastUsed: u, visible: .netflix, budget: 2) == [.peacock, .youtube], "the visible one stays even though it is the oldest")
    }

    @Test func theBudgetCountsTheVisibleViewAndShrinksOnPressure() {
        let live: [ProviderID] = [.netflix, .hulu, .youtube]
        let u = used([(.netflix, 1), (.hulu, 2), (.youtube, 3)])
        #expect(RetentionPlan.releaseList(live: live, lastUsed: u, visible: .youtube, budget: 2) == [.netflix])
        #expect(RetentionPlan.releaseList(live: live, lastUsed: u, visible: .youtube, budget: 1) == [.netflix, .hulu])
        #expect(RetentionPlan.releaseList(live: live, lastUsed: u, visible: .youtube, budget: 0) == [.netflix, .hulu], "the visible one is never released")
        #expect(RetentionPlan.releaseList(live: live, lastUsed: u, visible: nil, budget: 2) == [.netflix])
        #expect(RetentionPlan.releaseList(live: live, lastUsed: u, visible: nil, budget: 0) == [.netflix, .hulu, .youtube])
        #expect(RetentionPlan.releaseList(live: [], lastUsed: [:], visible: nil, budget: 2).isEmpty)
        #expect(RetentionPlan.releaseList(live: [.hulu], lastUsed: [:], visible: .hulu, budget: 2).isEmpty)
    }

    @Test func standardBudget() {
        #expect(MemoryBudget.standard.maxLiveWebViews == 2 && MemoryBudget.standard.warningMaxLive == 1)
        #expect(MemoryBudget.standard.hiddenTTL == .seconds(1800))
    }
}
