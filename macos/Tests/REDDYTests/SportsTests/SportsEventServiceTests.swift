import Testing
import Foundation
@testable import REDDY

/// A scripted guide: channels, their programmes, and each playlist's revision, with no database.
final class FakeGuide: @unchecked Sendable {
    private let lock = NSLock()
    var channels: [Channel] = []
    var programmes: [String: [EPGProgram]] = [:]          // by channel id
    var revisions: [UUID: String] = [:]
    private(set) var programmeCalls = 0
    private(set) var asked: [(from: Date, to: Date)] = []
    var onProgrammes: (() -> Void)?

    func inputs() -> SportsEventService.Inputs {
        SportsEventService.Inputs(
            channels: { [self] in lock.lock(); defer { lock.unlock() }; return channels },
            programmes: { [self] ids, from, to in
                lock.lock(); programmeCalls += 1; asked.append((from, to)); let hook = onProgrammes; lock.unlock()
                hook?()
                lock.lock(); defer { lock.unlock() }
                return Dictionary(uniqueKeysWithValues: ids.compactMap { id in programmes[id].map { (id, $0) } })
            },
            revisions: { [self] in lock.lock(); defer { lock.unlock() }; return revisions })
    }

    private var nextID: Int64 = 1
    private var known = Set<String>()
    func channel(_ id: String, source: UUID, name: String, category: String? = "Sports", categoryName: String? = "Sports", language: String? = nil, resolution: String? = nil, archive: Int = 0) -> Channel {
        Channel(id: id, sourceID: source, providerID: id, name: name, normalizedName: name.lowercased(), categoryID: category, categoryName: categoryName, logoURL: nil, epgID: id, language: language, country: nil,
                resolutionHint: resolution, sortOrder: 0, streamRef: "x", groupKey: nil, isFavorite: false, archiveDays: archive)
    }
    func add(_ channel: Channel, _ title: String, at start: Date, minutes: Double = 120, subtitle: String? = nil, category: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if known.insert(channel.id).inserted { channels.append(channel) }
        nextID += 1
        programmes[channel.id, default: []].append(EPGProgram(id: nextID, sourceID: channel.sourceID, xmltvChannelID: channel.id, start: start, end: start.addingTimeInterval(minutes * 60), title: title, subtitle: subtitle, description: nil, category: category, imageURL: nil))
    }
}

@Suite("Sports events") struct SportsEventServiceTests {
    let a = UUID(), b = UUID()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)       // 2027-01-15 08:00 UTC
    var window: DateInterval { DateInterval(start: t0.addingTimeInterval(-3600), end: t0.addingTimeInterval(12 * 3600)) }
    let ctx = SportsContext(profileID: "main", restricting: false, lockedCategoryIDs: [], hiddenChannelIDs: [])

    private func service(_ g: FakeGuide, tolerance: TimeInterval = 45 * 60) -> SportsEventService { SportsEventService(inputs: g.inputs(), startTolerance: tolerance) }

    // MARK: feeds and duplicates

    @Test func duplicateFeedsOfOneEventBecomeOneEventSortedByQuality() async throws {
        let g = FakeGuide(); g.revisions = [a: "r1"]
        g.add(g.channel("c1", source: a, name: "Sports 1 SD"), "Premier League: Arsenal v Chelsea (SD)", at: t0)
        g.add(g.channel("c2", source: a, name: "Sports 1 4K"), "Premier League: Arsenal vs Chelsea 4K", at: t0.addingTimeInterval(5 * 60))
        g.add(g.channel("c3", source: a, name: "Sports 2 Hindi", language: "hi", resolution: "FHD", archive: 3), "Premier League: Arsenal v Chelsea - Hindi", at: t0)
        let events = try await service(g).events(in: window, context: ctx)
        #expect(events.count == 1)
        let e = try #require(events.first)
        #expect(e.sport == .football && e.kind == .headToHead && e.participants == ["Arsenal", "Chelsea"] && e.feeds.count == 3)
        #expect(e.feeds.map(\.channelID) == ["c2", "c3", "c1"], "4K, then FHD, then SD")
        let hindi = try #require(e.feeds.first { $0.channelID == "c3" })
        #expect(hindi.language == "hi" && hindi.languageSource == .provider && hindi.quality == "FHD" && hindi.qualitySource == .provider && hindi.catchUp)
        #expect(e.state(at: t0 + 600) == .live && e.state(at: t0 - 600) == .upcoming && e.state(at: t0 + 3 * 3600) == .finished)
    }

    @Test func unknownLanguageAndQualityStayUnknown() async throws {
        let g = FakeGuide(); g.revisions = [a: "r1"]
        g.add(g.channel("c1", source: a, name: "Sky Sports Football"), "Premier League: Arsenal v Chelsea", at: t0)         // an Android-style channel: no language, no quality
        let feed = try #require(try await service(g).events(in: window, context: ctx).first?.feeds.first)
        #expect(feed.language == nil && feed.quality == nil && feed.languageSource == .unknown && feed.qualitySource == .unknown && feed.variant == nil, "nothing is invented")
        g.add(g.channel("c2", source: a, name: "Sky Sports Football HD Hindi"), "Premier League: Arsenal v Chelsea", at: t0)
        let hinted = try #require(try await service(g).events(in: window, context: ctx).first?.feeds.first { $0.channelID == "c2" })
        #expect(hinted.quality == "HD" && hinted.qualitySource == .parsedFromName && hinted.language == "hi" && hinted.languageSource == .parsedFromName, "a hint read out of a name is marked as one")
    }

    @Test func reversedSidesOnDifferentChannelsAreOneEvent() async throws {
        let g = FakeGuide(); g.revisions = [a: "r1"]
        g.add(g.channel("c1", source: a, name: "NBA 1"), "NBA: Lakers vs Celtics", at: t0)
        g.add(g.channel("c2", source: a, name: "NBA 2"), "NBA | Celtics @ Lakers", at: t0)
        let events = try await service(g).events(in: window, context: ctx)
        #expect(events.count == 1 && events[0].feeds.count == 2 && events[0].participants == ["Lakers", "Celtics"], "the first feed's order is kept for display")
    }

    @Test func twoSourcesCarryingTheSameEventAreOneEventWithACompositeRevision() async throws {
        let g = FakeGuide(); g.revisions = [a: "rA", b: "rB"]
        g.add(g.channel("a1", source: a, name: "A Sports"), "Premier League: Arsenal v Chelsea", at: t0)
        g.add(g.channel("b1", source: b, name: "B Sports"), "Premier League: Arsenal vs Chelsea", at: t0.addingTimeInterval(600))
        g.add(g.channel("a2", source: a, name: "A Cricket"), "IPL: Mumbai Indians vs Chennai Super Kings", at: t0)
        let events = try await service(g).events(in: window, context: ctx)
        let football = try #require(events.first { $0.sport == .football }), cricket = try #require(events.first { $0.sport == .cricket })
        #expect(football.sourceIDs == [a, b] && football.guideRevision.contains("rA") && football.guideRevision.contains("rB"))
        #expect(cricket.sourceIDs == [a] && cricket.guideRevision.contains("rA") && !cricket.guideRevision.contains("rB"), "only the playlists that carry an event are in its revision")
    }

    // MARK: grouping rules

    @Test func theSameSidesOnDifferentDatesAreDifferentEvents() async throws {
        let g = FakeGuide(); g.revisions = [a: "r1"]
        g.add(g.channel("c1", source: a, name: "Sports 1"), "Premier League: Arsenal v Chelsea", at: t0)
        g.add(g.channel("c1", source: a, name: "Sports 1"), "Premier League: Arsenal v Chelsea", at: t0.addingTimeInterval(7 * 86400))
        let w = DateInterval(start: t0.addingTimeInterval(-3600), end: t0.addingTimeInterval(8 * 86400))
        #expect(try await service(g).events(in: DateInterval(start: w.start, end: w.start.addingTimeInterval(72 * 3600)), context: ctx).count == 1)
        g.revisions[a] = "r2"
        let both = try await service(g).events(in: DateInterval(start: w.start, end: w.start.addingTimeInterval(72 * 3600)), context: ctx)
        #expect(both.count == 1, "the window is limited to 72 hours, so the second date is not even read")
    }

    @Test func sameSidesAtDifferentTimesStaySeparateEvenInsideOneWindow() async throws {
        let g = FakeGuide(); g.revisions = [a: "r1"]
        g.add(g.channel("c1", source: a, name: "Sports 1"), "Premier League: Arsenal v Chelsea", at: t0)
        g.add(g.channel("c2", source: a, name: "Sports 2"), "Premier League: Arsenal v Chelsea", at: t0.addingTimeInterval(8 * 3600))      // a second showing/leg eight hours later
        #expect(try await service(g).events(in: window, context: ctx).count == 2)
    }

    @Test func sameSidesAndTimeInDifferentCompetitionsAreNotMerged() async throws {
        let g = FakeGuide(); g.revisions = [a: "r1"]
        g.add(g.channel("c1", source: a, name: "Sports 1"), "Premier League: Arsenal v Chelsea", at: t0)
        g.add(g.channel("c2", source: a, name: "Sports 2"), "FA Cup: Arsenal v Chelsea", at: t0)
        g.add(g.channel("c3", source: a, name: "Sports 3"), "Arsenal v Chelsea", at: t0, category: "Football")             // no competition named: compatible with either, joins the first
        let events = try await service(g).events(in: window, context: ctx)
        #expect(events.count == 2 && events.map(\.feeds.count).sorted() == [1, 2])
    }

    @Test func eventsNearAFifteenMinuteBoundaryAreNotSplitOrMerged() async throws {
        let boundary = Date(timeIntervalSince1970: (1_800_000_000 / 900 + 1) * 900)           // exactly on a 15-minute line
        let g = FakeGuide(); g.revisions = [a: "r1"]
        // one match whose feeds start a minute either side of the line: one event
        g.add(g.channel("c1", source: a, name: "S1"), "Premier League: Arsenal v Chelsea", at: boundary.addingTimeInterval(-60))
        g.add(g.channel("c2", source: a, name: "S2"), "Premier League: Arsenal v Chelsea", at: boundary.addingTimeInterval(60))
        // two different matches either side of the line: two events
        g.add(g.channel("c3", source: a, name: "S3"), "NBA: Lakers vs Celtics", at: boundary.addingTimeInterval(-60))
        g.add(g.channel("c4", source: a, name: "S4"), "NBA: Heat vs Bulls", at: boundary.addingTimeInterval(60))
        let w = DateInterval(start: boundary.addingTimeInterval(-3600), end: boundary.addingTimeInterval(6 * 3600))
        let events = try await service(g).events(in: w, context: ctx)
        #expect(events.count == 3)
        #expect(events.first { $0.title.contains("Arsenal") }?.feeds.count == 2)
    }

    @Test func feedsWhoseProgrammesOverlapAreOneEventEvenIfTheyStartFarApart() async throws {
        let g = FakeGuide(); g.revisions = [a: "r1"]
        g.add(g.channel("c1", source: a, name: "S1"), "Premier League: Arsenal v Chelsea", at: t0, minutes: 240)                       // starts with a long pre-show
        g.add(g.channel("c2", source: a, name: "S2"), "Premier League: Arsenal v Chelsea", at: t0.addingTimeInterval(110 * 60), minutes: 110)
        #expect(try await service(g, tolerance: 20 * 60).events(in: window, context: ctx).count == 1, "overlapping programmes")
        let g2 = FakeGuide(); g2.revisions = [a: "r1"]
        g2.add(g2.channel("c1", source: a, name: "S1"), "Premier League: Arsenal v Chelsea", at: t0, minutes: 90)
        g2.add(g2.channel("c2", source: a, name: "S2"), "Premier League: Arsenal v Chelsea", at: t0.addingTimeInterval(110 * 60), minutes: 90)
        #expect(try await service(g2, tolerance: 20 * 60).events(in: window, context: ctx).count == 2, "no overlap and beyond the tolerance")
        #expect(try await service(g2, tolerance: 2 * 3600).events(in: window, context: ctx).count == 1, "the tolerance can be set")
    }

    @Test func daylightSavingAndTimeZonesAreHandledInAbsoluteTime() async throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/New_York")!
        let spring = cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 50))!       // 01:50 EST, ten minutes before the clocks jump
        let later = cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 3, minute: 10))!        // 03:10 EDT: twenty real minutes after the first
        #expect(later.timeIntervalSince(spring) == 20 * 60)
        let g = FakeGuide(); g.revisions = [a: "r1"]
        g.add(g.channel("c1", source: a, name: "S1"), "NBA: Lakers vs Celtics", at: spring, minutes: 150)
        g.add(g.channel("c2", source: a, name: "S2"), "NBA: Lakers vs Celtics", at: later, minutes: 150)
        let w = DateInterval(start: spring.addingTimeInterval(-3600), end: spring.addingTimeInterval(6 * 3600))
        let e = try #require(try await service(g).events(in: w, context: ctx).first)
        #expect(e.feeds.count == 2, "twenty real minutes apart, though the wall clocks differ by an hour and twenty")
        #expect(e.end.timeIntervalSince(e.start) == 170 * 60 && e.state(at: later) == .live && e.state(at: spring.addingTimeInterval(4 * 3600)) == .finished)
        // autumn: the 01:30 hour happens twice; two real instants an hour apart are one wall-clock time
        let fall1 = Date(timeIntervalSince1970: cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 30))!.timeIntervalSince1970 + 3600)
        let g2 = FakeGuide(); g2.revisions = [a: "r1"]
        g2.add(g2.channel("c1", source: a, name: "S1"), "NBA: Lakers vs Celtics", at: fall1, minutes: 100)
        g2.add(g2.channel("c2", source: a, name: "S2"), "NBA: Lakers vs Celtics", at: fall1.addingTimeInterval(3600), minutes: 100)
        #expect(try await service(g2, tolerance: 20 * 60).events(in: DateInterval(start: fall1.addingTimeInterval(-3600), end: fall1.addingTimeInterval(7200 * 2)), context: ctx).count == 1, "the second start is within the first's programme")
    }

    // MARK: restrictions

    @Test func lockedAndHiddenChannelsNeverLeakThroughAnEvent() async throws {
        let g = FakeGuide(); g.revisions = [a: "r1"]
        g.add(g.channel("open", source: a, name: "Open 1", category: "cat-open"), "Premier League: Arsenal v Chelsea", at: t0)
        g.add(g.channel("locked", source: a, name: "Locked 1", category: "cat-adult"), "Premier League: Arsenal v Chelsea", at: t0)
        g.add(g.channel("hidden", source: a, name: "Hidden 1", category: "cat-open"), "Premier League: Arsenal v Chelsea", at: t0)
        g.add(g.channel("onlyLocked", source: a, name: "Locked 2", category: "cat-adult"), "NBA: Lakers vs Celtics", at: t0)
        let svc = service(g)
        let free = try await svc.events(in: window, context: ctx)
        #expect(free.flatMap(\.feeds).count == 4, "nothing is restricted yet")
        let limited = SportsContext(profileID: "main", restricting: true, lockedCategoryIDs: ["cat-adult"], hiddenChannelIDs: ["hidden"])
        let events = try await svc.events(in: window, context: limited)
        #expect(events.count == 1 && events[0].feeds.map(\.channelID) == ["open"], "a hidden or locked channel is gone, and an event only they carried disappears")
        #expect(!events.flatMap(\.feeds).contains { $0.channelID == "locked" || $0.channelID == "hidden" || $0.channelID == "onlyLocked" })
        #expect(limited.restriction(for: g.channel("x", source: a, name: "x", category: "cat-adult")) == .lockedFolder && limited.restriction(for: g.channel("hidden", source: a, name: "h")) == .hiddenChannel)
        let notRestricting = SportsContext(profileID: "main", restricting: false, lockedCategoryIDs: ["cat-adult"], hiddenChannelIDs: [])
        #expect(try await svc.events(in: window, context: notRestricting).flatMap(\.feeds).count == 4, "a locked folder is only in force while the lock is")
    }

    @Test func switchingProfileNeverServesTheOtherProfilesResults() async throws {
        let g = FakeGuide(); g.revisions = [a: "r1"]
        g.add(g.channel("shared", source: a, name: "Shared", category: "ok"), "NBA: Lakers vs Celtics", at: t0)
        g.add(g.channel("adultOnly", source: a, name: "Adult", category: "adult"), "NFL: Chiefs vs Eagles", at: t0)
        let svc = service(g)
        let parent = SportsContext(profileID: "parent", restricting: false, lockedCategoryIDs: ["adult"], hiddenChannelIDs: [])
        let kid = SportsContext(profileID: "kid", restricting: true, lockedCategoryIDs: ["adult"], hiddenChannelIDs: [])
        #expect(try await svc.events(in: window, context: parent).count == 2)
        #expect(try await svc.events(in: window, context: kid).count == 1, "the kid profile does not get the parent's cached events")
        #expect(try await svc.events(in: window, context: parent).count == 2)
    }

    @Test func aProfileSwitchWhileClassifyingCancelsTheOldWorkAndPublishesNothingFromIt() async throws {
        let g = FakeGuide(); g.revisions = [a: "r1"]
        g.add(g.channel("shared", source: a, name: "Shared", category: "ok"), "NBA: Lakers vs Celtics", at: t0)
        g.add(g.channel("adultOnly", source: a, name: "Adult", category: "adult"), "NFL: Chiefs vs Eagles", at: t0)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let first = ManagedFlag()
        g.onProgrammes = { if first.takeFirst() { entered.signal(); release.wait() } }              // the first read (the parent's) is held up
        let svc = service(g)
        let parent = SportsContext(profileID: "parent", restricting: false, lockedCategoryIDs: ["adult"], hiddenChannelIDs: [])
        let kid = SportsContext(profileID: "kid", restricting: true, lockedCategoryIDs: ["adult"], hiddenChannelIDs: [])
        let oldWork = Task { try await svc.events(in: window, context: parent) }
        await waitFor(entered)                                                  // the parent's classification is running
        async let kidResult = svc.events(in: window, context: kid)                                    // the profile switches meanwhile
        try await Task.sleep(nanoseconds: 100_000_000)
        release.signal()
        let kidEvents = try await kidResult
        #expect(kidEvents.count == 1 && !kidEvents.flatMap(\.feeds).contains { $0.channelID == "adultOnly" })
        await #expect(throws: CancellationError.self) { _ = try await oldWork.value }                // the parent's work is cancelled and never published
        #expect(try await svc.events(in: window, context: kid).flatMap(\.feeds).allSatisfy { $0.channelID != "adultOnly" }, "and nothing of it reached the cache")
    }

    @Test func aLockChangeCancelsWorkInFlight() async throws {
        let g = FakeGuide(); g.revisions = [a: "r1"]
        g.add(g.channel("c1", source: a, name: "Sports 1"), "NBA: Lakers vs Celtics", at: t0)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let first = ManagedFlag()
        g.onProgrammes = { if first.takeFirst() { entered.signal(); release.wait() } }
        let svc = service(g)
        let work = Task { try await svc.events(in: window, context: ctx) }
        await waitFor(entered)
        await svc.contextDidChange()
        release.signal()
        await #expect(throws: CancellationError.self) { _ = try await work.value }
        #expect(try await svc.events(in: window, context: ctx).count == 1, "asking again works")
    }

    // MARK: cache

    @Test func theCacheIsKeyedByEachPlaylistsOwnRevisionSoOneUpdateDoesNotRedoTheOther() async throws {
        let g = FakeGuide(); g.revisions = [a: "a1", b: "b1"]
        g.add(g.channel("a1", source: a, name: "A Sports"), "Premier League: Arsenal v Chelsea", at: t0)
        g.add(g.channel("b1", source: b, name: "B Sports"), "NBA: Lakers vs Celtics", at: t0)
        let svc = service(g)
        _ = try await svc.events(in: window, context: ctx)
        #expect(await svc.classifiedSources == 2)
        _ = try await svc.events(in: window, context: ctx)
        #expect(await svc.classifiedSources == 2, "answered from the cache")
        g.revisions[b] = "b2"                                                                           // only playlist B's guide was re-imported
        _ = try await svc.events(in: window, context: ctx)
        #expect(await svc.classifiedSources == 3, "only B was classified again; A was reused")
        g.add(g.channel("a9", source: a, name: "A Sports 2"), "NBA: Heat vs Bulls", at: t0)           // a new channel in A without a new guide revision
        let events = try await svc.events(in: window, context: ctx)
        #expect(await svc.classifiedSources == 4 && events.count == 3, "a changed channel list is a change too")
        await svc.invalidate()
        _ = try await svc.events(in: window, context: ctx)
        #expect(await svc.classifiedSources == 6, "invalidate() drops everything")
    }

    @Test func aDifferentWindowIsAnotherEntryAndTheWindowIsBounded() async throws {
        let g = FakeGuide(); g.revisions = [a: "r1"]
        g.add(g.channel("c1", source: a, name: "Sports 1"), "NBA: Lakers vs Celtics", at: t0)
        let svc = service(g)
        let huge = DateInterval(start: t0, end: t0.addingTimeInterval(30 * 86400))
        _ = try await svc.events(in: huge, context: ctx)
        let asked = try #require(g.asked.last)
        #expect(asked.to.timeIntervalSince(asked.from) <= SportsEventService.maxWindow + 900, "no more than 72 hours of guide is ever read")
    }

    // MARK: large guide

    @Test func aLargeSyntheticGuideIsReadInBatchesAndClassifiedQuickly() async throws {
        let g = FakeGuide(); g.revisions = [a: "big"]
        let channelCount = 10_000, perChannel = 12
        let sportsTitles = ["Premier League: Arsenal v Chelsea", "NBA: Lakers vs Celtics", "IPL: Mumbai Indians vs Chennai Super Kings", "Formula 1: Monaco Grand Prix - Race", "UFC 300: Main Card"]
        let otherTitles = ["Evening News", "The Movie: Alien vs. Predator", "Cooking Today", "Cricket Highlights", "Kids Cartoon Hour", "Sky Sports News", "Weather", "Documentary: The Sea", "Quiz Night", "Football Focus Tonight"]
        for i in 0..<channelCount {
            let ch = g.channel("ch\(i)", source: a, name: "Channel \(i)", category: "cat\(i % 40)", categoryName: "Group \(i % 40)")
            for j in 0..<perChannel {
                let title = (i % 33 == 0 && j == 3) ? sportsTitles[(i / 33) % sportsTitles.count] : otherTitles[(i + j) % otherTitles.count]
                g.add(ch, title, at: t0.addingTimeInterval(Double(j) * 3600))
            }
        }
        let svc = service(g)
        let t = Date()
        let events = try await svc.events(in: DateInterval(start: t0, end: t0.addingTimeInterval(13 * 3600)), context: ctx)
        let seconds = Date().timeIntervalSince(t)
        print("SPORTS PERF \(channelCount) channels x \(perChannel) programmes (\(channelCount * perChannel) total): \(events.count) events in \(String(format: "%.2f", seconds)) s; guide read in \(g.programmeCalls) batches")
        #expect(g.programmeCalls == (channelCount + SportsEventService.batch - 1) / SportsEventService.batch, "batched, never a query per channel")
        #expect(events.count == 5 && events.flatMap(\.feeds).count == (0..<channelCount).filter { $0 % 33 == 0 }.count)
        #expect(seconds < 20, "classified in \(seconds) s")
        let again = Date()
        _ = try await svc.events(in: DateInterval(start: t0, end: t0.addingTimeInterval(13 * 3600)), context: ctx)
        #expect(Date().timeIntervalSince(again) < 1.5, "the second request comes from the cache")
    }
}

/// Waits for a semaphore without blocking a Swift concurrency thread.
func waitFor(_ s: DispatchSemaphore) async { await withCheckedContinuation { c in DispatchQueue.global().async { s.wait(); c.resume() } } }

/// True once, for the first caller (used to hold up only the first read of the guide).
final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock(); private var used = false
    func takeFirst() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}
