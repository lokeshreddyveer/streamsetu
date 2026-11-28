import Foundation
import Testing
@testable import REDDY

@Suite struct PerfAndPriorityTests {
    @Test func historyMirrorConvertsOnlyNewRows() {
        var m = MusicHistoryMirror<Int, String>()
        var history = Array((1...1000).reversed())              // newest first
        _ = m.update(history, convert: { "p\($0)" })
        #expect(m.out.count == 1000); #expect(m.rebuilds == 1)
        history.insert(1001, at: 0)
        let o = m.update(history, convert: { "p\($0)" })
        #expect(m.lastConverted == 1); #expect(o.first == "p1001"); #expect(o.count == 1001); #expect(m.rebuilds == 1)
        history.insert(contentsOf: [1003, 1002], at: 0)
        _ = m.update(history, convert: { "p\($0)" })
        #expect(m.lastConverted == 2); #expect(m.out.prefix(3) == ["p1003", "p1002", "p1001"])
        // unchanged: nothing converted
        _ = m.update(history, convert: { "p\($0)" }); #expect(m.lastConverted == 0)
        // full history: a new row at the front, the oldest dropped at the back
        var full = Array((1...50).reversed()); var f = MusicHistoryMirror<Int, Int>()
        _ = f.update(full, convert: { $0 * 2 })
        full.insert(51, at: 0); full.removeLast()
        let r = f.update(full, convert: { $0 * 2 })
        #expect(f.lastConverted == 1); #expect(r == full.map { $0 * 2 }); #expect(f.rebuilds == 1)
        // a different list rebuilds
        _ = f.update([9, 8, 7], convert: { $0 * 2 }); #expect(f.rebuilds == 2); #expect(f.out == [18, 16, 14])
    }

    @Test func mirrorMatchesAFullRebuildAlways() {
        var m = MusicHistoryMirror<Int, Int>()
        var h: [Int] = []
        var next = 0
        for step in 0..<200 {
            let adds = step % 7 == 0 ? 3 : 1
            for _ in 0..<adds { next += 1; h.insert(next, at: 0) }
            if step % 11 == 0, h.count > 20 { h.removeLast(2) }
            if step == 120 { h.remove(at: 5) }           // an edit in the middle: must rebuild, never serve stale
            #expect(m.update(h, convert: { $0 + 1 }) == h.map { $0 + 1 })
        }
    }

    @Test func waitersGoForegroundFirstThenFirstComeFirstServed() {
        let items: [MusicWaiterOrder.Item] = [.init(id: 1, priority: .background), .init(id: 2, priority: .background), .init(id: 3, priority: .foreground),
                                              .init(id: 4, priority: .normal), .init(id: 5, priority: .foreground)]
        #expect(MusicWaiterOrder.sorted(items).map(\.id) == [3, 5, 4, 1, 2])
    }

    @Test func pageEntityGetsForeground() {
        let a = MusicEntityID(kind: .person, token: "AAAAAAAAAAAAA"), b = MusicEntityID(kind: .person, token: "BBBBBBBBBBBBB")
        #expect(MusicRequestPriority.forEntity(a, focus: a, background: true) == .foreground)
        #expect(MusicRequestPriority.forEntity(b, focus: a, background: true) == .background)
        #expect(MusicRequestPriority.forEntity(b, focus: nil) == .normal)
        MusicRequestFocus.shared.entity = a; #expect(MusicRequestFocus.shared.entity == a); MusicRequestFocus.shared.entity = nil
    }

    @Test func memoComputesOncePerKey() {
        let memo = MusicMemo<Int>()
        var runs = 0
        for _ in 0..<5 { _ = memo.value(for: "a") { runs += 1; return 1 } }
        #expect(runs == 1)
        _ = memo.value(for: "b") { runs += 1; return 2 }
        #expect(runs == 2)
    }
}
