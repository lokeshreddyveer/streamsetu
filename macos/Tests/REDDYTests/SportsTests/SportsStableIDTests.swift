import Testing
import Foundation
@testable import REDDY

/// An event keeps its id when its feeds change. Phase 2 (focus, scroll position, reminders) relies on this.
@Suite("Sports event ids") struct SportsStableIDTests {
    let a = UUID(), b = UUID()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)       // 2027-01-15 08:00 UTC, far from a day boundary
    let ctx = SportsContext(profileID: "main", restricting: false, lockedCategoryIDs: [], hiddenChannelIDs: [])
    var window: DateInterval { DateInterval(start: t0.addingTimeInterval(-6 * 3600), end: t0.addingTimeInterval(20 * 3600)) }

    private func events(_ g: FakeGuide, tolerance: TimeInterval = 45 * 60) async throws -> [SportsEvent] {
        try await SportsEventService(inputs: g.inputs(), startTolerance: tolerance).events(in: window, context: ctx)
    }
    private func base() -> FakeGuide {
        let g = FakeGuide(); g.revisions = [a: "r1"]
        g.add(g.channel("c1", source: a, name: "Sports 1"), "Premier League: Arsenal v Chelsea", at: t0)
        g.add(g.channel("c2", source: a, name: "Sports 2"), "Premier League: Arsenal v Chelsea", at: t0.addingTimeInterval(5 * 60))
        return g
    }

    @Test func anEarlierFeedAppearingDoesNotChangeTheId() async throws {
        let before = try #require(try await events(base()).first)
        let g = base(); g.add(g.channel("c3", source: a, name: "Sports 3"), "Premier League: Arsenal v Chelsea", at: t0.addingTimeInterval(-30 * 60))
        let after = try #require(try await events(g).first)
        #expect(after.start < before.start && after.feeds.count == 3, "the event now starts earlier")
        #expect(after.id == before.id, "but it is the same event")
    }

    @Test func aLaterFeedAppearingDoesNotChangeTheId() async throws {
        let before = try #require(try await events(base()).first)
        let g = base(); g.add(g.channel("c3", source: a, name: "Sports 3"), "Premier League: Arsenal v Chelsea", at: t0.addingTimeInterval(40 * 60))
        let after = try #require(try await events(g).first)
        #expect(after.feeds.count == 3 && after.id == before.id)
    }

    @Test func removingAFeedEvenTheEarliestDoesNotChangeTheId() async throws {
        let g = base(); g.add(g.channel("c3", source: a, name: "Sports 3"), "Premier League: Arsenal v Chelsea", at: t0.addingTimeInterval(20 * 60))
        let full = try #require(try await events(g).first)
        for gone in ["c1", "c2", "c3"] {
            let g2 = FakeGuide(); g2.revisions = [a: "r1"]
            for c in g.channels where c.id != gone { g2.add(c, "Premier League: Arsenal v Chelsea", at: g.programmes[c.id]![0].start) }
            let after = try #require(try await events(g2).first)
            #expect(after.feeds.count == 2 && after.id == full.id, "without \(gone)")
        }
    }

    @Test func aSmallEPGTimeCorrectionDoesNotChangeTheId() async throws {
        let before = try #require(try await events(base()).first)
        for shift in [-20.0, -5.0, 10.0, 25.0] {
            let g = FakeGuide(); g.revisions = [a: "r1"]
            for c in base().channels { g.add(c, "Premier League: Arsenal v Chelsea", at: base().programmes[c.id]![0].start.addingTimeInterval(shift * 60)) }
            let after = try #require(try await events(g).first)
            #expect(after.id == before.id && after.start != before.start, "shifted by \(shift) minutes")
        }
        // only one of the feeds corrected
        let g = FakeGuide(); g.revisions = [a: "r1"]
        g.add(g.channel("c1", source: a, name: "Sports 1"), "Premier League: Arsenal v Chelsea", at: t0.addingTimeInterval(12 * 60))
        g.add(g.channel("c2", source: a, name: "Sports 2"), "Premier League: Arsenal v Chelsea", at: t0.addingTimeInterval(5 * 60))
        #expect(try #require(try await events(g).first).id == before.id)
    }

    @Test func aSourceRefreshKeepsTheIdWhileTheRevisionChanges() async throws {
        let g = base()
        let before = try #require(try await events(g).first)
        g.revisions[a] = "r2"                                                        // the guide was imported again, the listings are the same
        let after = try #require(try await events(g).first)
        #expect(after.id == before.id && after.guideRevision != before.guideRevision)
        // a refresh that corrects the times and adds the same match from another playlist
        g.revisions = [a: "r3", b: "x1"]
        g.add(g.channel("b1", source: b, name: "B Sports"), "Premier League: Arsenal vs Chelsea", at: t0.addingTimeInterval(8 * 60))
        let both = try #require(try await events(g).first)
        #expect(both.id == before.id && both.sourceIDs == [a, b])
    }

    @Test func theSameSidesPlayingTwiceOnTheSameDateAreTwoStableEvents() async throws {
        let g = base()
        g.add(g.channel("c3", source: a, name: "Sports 3"), "Premier League: Arsenal v Chelsea", at: t0.addingTimeInterval(8 * 3600))      // a second match the same day
        let two = try await events(g)
        #expect(two.count == 2 && Set(two.map(\.id)).count == 2)
        let first = two[0], second = two[1]
        // a feed appears for each; neither id changes
        g.add(g.channel("c4", source: a, name: "Sports 4"), "Premier League: Arsenal v Chelsea", at: t0.addingTimeInterval(8 * 3600 + 900))
        g.add(g.channel("c5", source: a, name: "Sports 5"), "Premier League: Arsenal v Chelsea", at: t0.addingTimeInterval(-600))
        let more = try await events(g)
        #expect(more.count == 2 && more[0].id == first.id && more[1].id == second.id && more[0].feeds.count == 3 && more[1].feeds.count == 2)
        // and the ids are the same on every rebuild
        for _ in 0..<5 { #expect(try await events(g).map(\.id) == more.map(\.id)) }
    }

    @Test func differentEventsGetDifferentIdsAndTheToleranceDoesNotEnterTheId() async throws {
        let g = base()
        g.add(g.channel("n1", source: a, name: "NBA 1"), "NBA: Lakers vs Celtics", at: t0)
        let evs = try await events(g)
        #expect(evs.count == 2 && evs[0].id != evs[1].id)
        let tight = try await events(g, tolerance: 20 * 60), loose = try await events(g, tolerance: 3 * 3600)
        #expect(tight.map(\.id) == evs.map(\.id) && loose.map(\.id) == evs.map(\.id), "the tolerance only decides which feeds group together; it is not part of the identity")
    }

    @Test func reversedSidesAndOtherTitleFormsKeepTheSameId() async throws {
        let g = base()
        let before = try #require(try await events(g).first)
        g.add(g.channel("c3", source: a, name: "Sports 3"), "Premier League | Chelsea @ Arsenal HD", at: t0.addingTimeInterval(2 * 60))
        #expect(try #require(try await events(g).first).id == before.id)
    }
}
