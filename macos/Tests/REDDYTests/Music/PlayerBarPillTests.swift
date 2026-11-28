import Foundation
import Testing
@testable import REDDY

@MainActor @Suite("Player bar pill layout") struct PlayerBarPillTests {
    @Test func theButtonsBudgetFitsInsideEveryPill() {
        for cls in [MusicLayoutClass.medium, .expanded, .wide] {
            let inner = MusicPlayerBar.pillWidth(for: cls) - 2 * MusicSpace.lg
            let budget = MusicPlayerBar.pillBudget(for: cls)
            // The fixed parts alone must leave real room: a clamp at zero would hide an overflowing layout.
            let fixed = 180 + MusicPlayerBar.pillCentreWidth(for: cls) + 2 * MusicSpace.md + MusicBarMetrics.moreWidth
            #expect(inner - fixed > 0, "\(cls): song zone + middle + gaps + more button overflow the pill (\(fixed) of \(inner))")
            #expect(abs(budget - (inner - fixed)) < 0.5, "\(cls): the budget is exactly what the pill has left")
            #expect(budget >= 0)
            let head = MusicBarCollapse.resolve(available: budget, present: Set(MusicBarCollapse.displayOrder)).shown
            #expect(head == Array(MusicBarCollapse.priority.prefix(head.count)), "\(cls): the pill shows the head of the priority list")
            // The buttons that are really drawn (plus the "..." button) must fit the budget, whatever the pill.
            let all = Set(MusicBarCollapse.displayOrder)
            let shown = MusicBarCollapse.resolve(available: budget, present: all).shown
            let width = shown.reduce(CGFloat(0)) { $0 + MusicBarMetrics.width(of: $1) } + MusicBarMetrics.moreWidth
            #expect(width <= budget + 0.5 || shown.isEmpty, "\(cls): the shown buttons (\(width)) must fit the budget (\(budget))")
        }
    }

    @Test func aWiderPillNeverShowsFewerButtons() {
        let present: Set<MusicBarControl> = [.queue, .lyrics, .output, .volume]
        func shown(_ cls: MusicLayoutClass) -> Int { MusicBarCollapse.resolve(available: MusicPlayerBar.pillBudget(for: cls), present: present).shown.count }
        #expect(shown(.wide) >= shown(.expanded))
        #expect(shown(.expanded) >= shown(.medium))
    }
}
