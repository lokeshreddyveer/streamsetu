import Testing
import Foundation
@testable import REDDY

@Suite("Scroll performance helpers") struct ScrollPerformanceTests {
    // MARK: publish gate (event coalescer, injected clock)

    @Test func gateIgnoresBatchesThatTouchNothingOnScreen() {
        var g = LandedPublishGate(minInterval: 30)
        let r1 = g.offer(now: 100, changedVisible: false, busy: false)
        #expect(!r1)
        #expect(!g.pending)
    }

    @Test func gatePublishesOnceThenWaitsTheInterval() {
        var g = LandedPublishGate(minInterval: 30)
        let r2 = g.offer(now: 100, changedVisible: true, busy: false)
        #expect(r2)
        let r3 = g.offer(now: 110, changedVisible: true, busy: false)
        #expect(!r3)      // held
        #expect(g.pending)
        let q101 = g.retry(now: 120, busy: false)
        #expect(!q101)
        let q102 = g.retry(now: 130, busy: false)
        #expect(q102)                             // one publish for the held change
        let q103 = g.retry(now: 200, busy: false)
        #expect(!q103)                            // nothing left to publish
    }

    @Test func gateHoldsWhileScrollingAndReleasesAfter() {
        var g = LandedPublishGate(minInterval: 2)
        let r4 = g.offer(now: 10, changedVisible: true, busy: true)
        #expect(!r4)
        #expect(g.pending)
        let q104 = g.retry(now: 11, busy: true)
        #expect(!q104)
        let q105 = g.retry(now: 12, busy: false)
        #expect(q105)
    }

    // MARK: hub

    @MainActor @Test func hubDeliversOnlyToTilesShowingTheId() {
        let hub = MetadataLandedHub()
        var a = 0, b = 0
        let ta = UUID(), tb = UUID()
        hub.register(id: "a", token: ta) { a += 1 }
        hub.register(id: "b", token: tb) { b += 1 }
        hub.deliver(["a", "zzz"])
        #expect(a == 1 && b == 0)
        #expect(hub.hasVisible(anyOf: ["x", "b"]) && !hub.hasVisible(anyOf: ["x"]))
        hub.unregister(id: "a", token: ta)
        hub.deliver(["a"])
        #expect(a == 1 && hub.visibleCount == 1)
    }

    @MainActor @Test func hubScrollSignalUsesTheClock() {
        let hub = MetadataLandedHub()
        var t: TimeInterval = 100
        hub.clock = { t }
        #expect(!hub.isScrolling)
        hub.noteActivity()
        #expect(hub.isScrolling)
        t = 101
        #expect(!hub.isScrolling)
    }

    // MARK: saved-cast facts cache

    @Test func castIndexIsLeastRecentlyUsedAndForgets() {
        let c = SavedCastIndex(capacity: 4)
        for i in 0..<4 { c.set("t\(i)", i % 2 == 0) }
        _ = c.value("t0")
        c.set("t4", true)                                  // over capacity: the older half goes, recent ones stay
        #expect(c.value("t4") == true)
        #expect(c.value("t0") == true)
        #expect(c.count <= 4)
        c.forget(["t4"])
        #expect(c.value("t4") == nil)
    }

    @Test func castIndexLooksUpOnceOffTheCaller() async {
        let c = SavedCastIndex(capacity: 16)
        c.warm("x") { _ in true }
        c.warm("x") { _ in false }                         // already in flight: ignored
        for _ in 0..<200 where c.value("x") == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(c.value("x") == true)
    }

    // MARK: memoised card model equals the old computation

    @Test func memoisedQualityEqualsTheOldComputation() {
        let titles = ["Nocturne 4K", "Der Tunnel (Café) FHD", "Plain Title", "Night Shift 1080p", "Old Film SD", "Éclair HD", "A+ 2160p", ""]
        for t in titles {
            let old = MetadataNormalizer.qualityLabel(MetadataNormalizer.normalize(t))
            #expect(PosterQualityMemo.label(for: t) == old)
            #expect(PosterQualityMemo.label(for: t) == old)          // second call comes from the cache
        }
    }

    @Test func cachedDisplayLabelsEqualTheComputedOnes() {
        let items: [(id: String, title: String, year: Int?)] = [("1", "Arcane 2021", 2021), ("2", "Dune (English)", nil), ("3", "Dune (French)", nil)]
        #expect(DisplayTitle.labelsCached(items) == DisplayTitle.labels(items))
        #expect(DisplayTitle.labelsCached(items) == DisplayTitle.labels(items))
    }

    @Test func imageKeyIsStableAndHex() {
        let u = URL(string: "https://example.test/p.jpg")!
        let k = ImageCache.key(u, .poster)
        #expect(k.count == 64 && k.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(ImageCache.key(u, .poster) == k)
    }

    // MARK: now/next store

    @MainActor @Test func nowNextPublishWritesOnlyChangedBoxes() {
        let s = NowNextStore()
        #expect(!s.isKnown("c1"))
        #expect(s.publish(["c1", "c2"], [:]).sorted() == ["c1", "c2"])        // [] remembered: no guide data
        #expect(s.isKnown("c1"))
        #expect(s.publish(["c1", "c2"], [:]).isEmpty)                         // nothing changed, nothing written
    }

    // MARK: atlas markers

    @MainActor @Test func atlasMarkersAreOffUntilShowMeOrTests() {
        #expect(AtlasMarkerGate.forceEnabled == false)
        if !ShowMeController.shared.isActive { #expect(AtlasMarkerGate.enabled == false) }
        AtlasMarkerGate.forceEnabled = true
        #expect(AtlasMarkerGate.enabled)
        AtlasMarkerGate.forceEnabled = false
    }
}

/// A synthetic measurement (no device, no UI): 30,000 channel-style titles through the per-redraw work a tile used to repeat. It records time
/// numbers for the old path (recompute every pass) and the new one (remembered); it does not claim anything about real-device smoothness.
@Suite("Scroll work measurement") struct ScrollWorkMeasurementTests {
    private static func titles(_ n: Int) -> [(id: String, title: String, year: Int?)] {
        let q = ["4K", "FHD", "HD", "SD", "1080p", ""]
        return (0..<n).map { (id: "c\($0)", title: "Channel \($0 % 5000) Café Nocturne \(q[$0 % q.count])", year: $0 % 7 == 0 ? 2000 + $0 % 25 : nil) }
    }

    @Test func rememberedWorkIsFasterThanRecomputingAndGivesTheSameAnswers() {
        let all = Self.titles(30_000)
        let rows = Array(stride(from: 0, to: all.count, by: 50).map { Array(all[$0..<min($0 + 50, all.count)]) }.prefix(40))          // the screenful being scrolled: 40 rows of 50 tiles out of 600
        let clock = ContinuousClock()
        // the visible window is redrawn many times while scrolling (a shelf's body re-runs on each)
        var plain: [String: String] = [:], cached: [String: String] = [:]
        let tPlain = clock.measure { for _ in 0..<25 { for r in rows { plain = DisplayTitle.labels(r) } } }
        let tCached = clock.measure { for _ in 0..<25 { for r in rows { cached = DisplayTitle.labelsCached(r) } } }
        #expect(plain == cached)
        var q1 = 0, q2 = 0
        let tQ = clock.measure { for _ in 0..<5 { for t in all { if MetadataNormalizer.qualityLabel(MetadataNormalizer.normalize(t.title)) != nil { q1 += 1 } } } }
        let tQM = clock.measure { for _ in 0..<5 { for t in all { if PosterQualityMemo.label(for: t.title) != nil { q2 += 1 } } } }
        #expect(q1 == q2)
        func ms(_ d: Duration) -> String { String(format: "%.0f ms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15) }
        print("MEASURE visible window 2,000 of 30,000 titles x25 redraws (labels); all 30,000 x5 (quality): labels recomputed \(ms(tPlain)) vs remembered \(ms(tCached)); quality recomputed \(ms(tQ)) vs remembered \(ms(tQM))")
        #expect(tCached < tPlain && tQM < tQ, "remembering must beat recomputing on repeated passes")
    }
}
