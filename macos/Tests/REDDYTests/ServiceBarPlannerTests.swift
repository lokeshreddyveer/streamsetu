import Testing
import Foundation
@testable import REDDY

@Suite("Service bar planner") struct ServiceBarPlannerTests {
    let all: [ProviderID] = [.netflix, .hulu, .youtube, .peacock, .hbomax]
    var widths: [ProviderID: CGFloat] { Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, 80) }) }
    private func plan(_ pinned: [ProviderID], active: ProviderID? = nil, budget: CGFloat, button: CGFloat = 40, spacing: CGFloat = 0) -> ServiceBarPlan {
        ServiceBarPlanner.plan(pinned: pinned, active: active, itemWidths: widths, servicesButtonWidth: button, budget: budget, spacing: spacing)
    }

    @Test func everythingFitsWhenThereIsRoom() {
        let p = plan(all, budget: 1000)
        #expect(p.inline == all && p.overflow.isEmpty && p.temporaryChip == nil && p.showsServicesButton)
    }

    @Test func itemsOverflowFromTheEndInPinnedOrderUsingTheRealBudget() {
        // 40 for the button + 80 each: 3 items need 280
        let p = plan(all, budget: 290)
        #expect(p.inline == [.netflix, .hulu, .youtube]); #expect(p.overflow == [.peacock, .hbomax])
        #expect(plan(all, budget: 279).inline == [.netflix, .hulu])
        #expect(plan(all, budget: 40).inline.isEmpty && plan(all, budget: 40).overflow == all)
        #expect(plan(all, budget: 0).inline.isEmpty && plan(all, budget: 0).showsServicesButton)
    }

    @Test func monotonicAsTheWindowShrinks() {
        var last = Int.max
        for b in stride(from: CGFloat(1000), through: 0, by: -10) {
            let p = plan(all, budget: b); #expect(p.inline.count <= last); #expect(p.inline + p.overflow == all); last = p.inline.count
        }
    }

    @Test func theActiveServiceIsNeverOverflowed() {
        let p = plan(all, active: .hbomax, budget: 130)          // button 40 + one item
        #expect(p.inline == [.hbomax]); #expect(p.overflow == [.netflix, .hulu, .youtube, .peacock])
        let q = plan(all, active: .hulu, budget: 210)
        #expect(q.inline == [.netflix, .hulu]); #expect(q.overflow == [.youtube, .peacock, .hbomax])
        #expect(plan(all, active: .hulu, budget: 1).inline == [.hulu])          // even when nothing fits
    }

    @Test func anActiveUnpinnedServiceGetsATemporaryChipAndMakesRoom() {
        let p = plan([.netflix, .hulu], active: .crunchyroll, budget: 1000)
        #expect(p.temporaryChip == .crunchyroll); #expect(p.inline == [.netflix, .hulu])
        let tight = plan([.netflix, .hulu, .youtube], active: .crunchyroll, budget: 210)          // 40 + chip 80 + one item
        #expect(tight.temporaryChip == .crunchyroll); #expect(tight.inline == [.netflix]); #expect(tight.overflow == [.hulu, .youtube])
        #expect(plan([.netflix], active: .netflix, budget: 1000).temporaryChip == nil)
        #expect(plan([], active: nil, budget: 100).inline.isEmpty)
    }

    @Test func spacingCountsAndDuplicatesAreIgnored() {
        let p = plan([.netflix, .netflix, .hulu], budget: 1000); #expect(p.inline == [.netflix, .hulu])
        // 2 items + button = 3 elements, 2 gaps of 10: 80+80+40+20 = 220
        #expect(plan([.netflix, .hulu], budget: 220, spacing: 10).inline.count == 2)
        #expect(plan([.netflix, .hulu], budget: 219, spacing: 10).inline.count == 1)
    }

    @Test func missingWidthsAreTreatedAsZeroNotACrash() {
        let p = ServiceBarPlanner.plan(pinned: [.netflix], active: nil, itemWidths: [:], servicesButtonWidth: 40, budget: 40)
        #expect(p.inline == [.netflix])
    }
}
