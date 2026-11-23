import Testing
import Foundation
@testable import REDDY

@Suite("Recovery policy") struct RecoveryPolicyTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    @Test func reloadsTwiceThenAsksThePerson() {
        let p = RecoveryPolicy.standard
        #expect(p.action(terminations: [at(0)], now: at(0)) == .reload)
        #expect(p.action(terminations: [at(0), at(10)], now: at(10)) == .reload)
        #expect(p.action(terminations: [at(0), at(10), at(20)], now: at(20)) == .showRetryCard)
        #expect(p.action(terminations: [at(0), at(10), at(20), at(30)], now: at(30)) == .showRetryCard, "never a loop")
    }

    @Test func oldStopsLeaveTheWindow() {
        let p = RecoveryPolicy.standard
        #expect(p.action(terminations: [at(0), at(10), at(100)], now: at(100)) == .reload)
        #expect(p.recent([at(0), at(50), at(100)], now: at(100)) == [at(50), at(100)])
    }

    @Test func theLimitsAreConfiguration() {
        let strict = RecoveryPolicy(maxAutoReloads: 0, window: 5)
        #expect(strict.action(terminations: [at(0)], now: at(0)) == .showRetryCard)
        #expect(RecoveryPolicy.standard.maxAutoReloads == 2 && RecoveryPolicy.standard.window == 60)
    }
}
