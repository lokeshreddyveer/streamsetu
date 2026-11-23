import Testing
import Foundation
@testable import REDDY

@Suite("Locked state") struct LockedTests {
    @Test func concurrentIncrementsAreNotLost() async {
        let n = LockedBox(0)
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<64 { g.addTask { for _ in 0..<500 { n.withLock { $0 += 1 } } } }
        }
        #expect(n.value == 32_000)
    }

    @Test func onlyOneCallerTakesTheFlag() async {
        let flag = OnceFlag()
        let winners = LockedBox(0)
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<100 { g.addTask { if flag.take() { winners.withLock { $0 += 1 } } } }
        }
        #expect(winners.value == 1)
        #expect(flag.value)
        flag.end()
        #expect(flag.begin())
        #expect(!flag.begin())
    }

    @Test func swapReturnsTheOldValue() {
        let box = LockedBox("a")
        #expect(box.swap("b") == "a")
        #expect(box.value == "b")
    }

    @Test func matchProfileDefaultsToMain() {
        let p = MatchProfileBox()
        #expect(p.id == "main")
        p.id = "kids"
        #expect(p.id == "kids")
    }
}
