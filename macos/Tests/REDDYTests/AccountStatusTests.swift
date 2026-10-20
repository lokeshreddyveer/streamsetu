import Testing
import Foundation
@testable import REDDY

@Suite struct AccountStatusTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func st(_ days: Double?, _ status: String = "Active") -> AccountStatus {
        AccountStatus(status: status, expires: days.map { now.addingTimeInterval($0 * 86400) }, maxConnections: 2, activeConnections: 0)
    }

    @Test func levelsFollowTheEndDate() {
        #expect(st(60).level(now: now) == .fine)
        #expect(st(7).level(now: now) == .soon)
        #expect(st(1).level(now: now) == .soon)
        #expect(st(-2).level(now: now) == .ended)
        #expect(st(nil).level(now: now) == .fine)                 // no end date: nothing to warn about
        #expect(st(60, "Expired").level(now: now) == .ended)      // the panel itself says it is not active
        #expect(st(60, "Disabled").summary(now: now).hasPrefix("Not active"))
    }

    @Test func summariesReadNaturally() {
        #expect(st(54).summary(now: now).hasSuffix("(54 days left)"))
        #expect(st(0).summary(now: now).hasPrefix("Ends today"))
        #expect(st(1).summary(now: now).hasPrefix("Ends tomorrow"))
        #expect(st(-1).summary(now: now).hasPrefix("Ended yesterday"))
        #expect(st(-5).summary(now: now).hasPrefix("Ended 5 days ago"))
        #expect(st(nil).summary(now: now) == "No end date")
    }
}
