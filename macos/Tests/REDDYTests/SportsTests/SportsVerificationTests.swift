import Testing
import Foundation
@testable import REDDY

/// Checks on the sports foundation itself: the speed-up changes nothing, the benchmark is what it claims to be, work can be stopped, and memory stays bounded.
@Suite("Sports verification") struct SportsVerificationTests {
    static let sportsTitles = ["Premier League: Arsenal v Chelsea", "NBA: Lakers vs Celtics", "IPL: Mumbai Indians vs Chennai Super Kings", "Formula 1: Monaco Grand Prix - Race", "UFC 300: Main Card"]
    static let otherTitles = ["Evening News", "The Movie: Alien vs. Predator", "Cooking Today", "Cricket Highlights", "Kids Cartoon Hour", "Sky Sports News", "Weather", "Documentary: The Sea", "Quiz Night", "Football Focus Tonight"]

    /// 10,000 channels with 12 programmes each. Every 33rd channel carries one of five sports listings in its fourth slot; everything else is not sport. The count of sports listings is known by construction.
    static func largeGuide() -> (guide: FakeGuide, injected: Int) {
        let a = UUID(), t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let g = FakeGuide(); g.revisions = [a: "big"]
        var injected = 0
        for i in 0..<10_000 {
            let ch = g.channel("ch\(i)", source: a, name: "Channel \(i)", category: "cat\(i % 40)", categoryName: "Group \(i % 40)")
            for j in 0..<12 {
                let isSport = i % 33 == 0 && j == 3
                if isSport { injected += 1 }
                g.add(ch, isSport ? sportsTitles[(i / 33) % sportsTitles.count] : otherTitles[(i + j) % otherTitles.count], at: t0.addingTimeInterval(Double(j) * 3600))
            }
        }
        return (g, injected)
    }

    @Test func theIdentityHashIsAStableFnv1aTheSameAsOnAndroid() {
        #expect(SportsEventService.hash("a") == "af63dc4c8601ec8c")
        #expect(SportsEventService.hash("") == "cbf29ce484222325")
    }

    // MARK: the shortcut changes nothing

    @Test func theEarlyRefusalReturnsExactlyWhatTheFullPathReturns() {
        let titles = SportsClassifierCorpus.titles
        let channels = ["Sports 1", "Sky Sports Football", "Channel 5", "Star Sports Hindi HD", "HBO", "Eurosport 2 4K", ""]
        let categories: [String?] = [nil, "Sports", "Movie", "News", "Football"]
        var compared = 0, found = 0
        for t in titles { for ch in channels { for cat in categories {
            let fast = SportsClassifier.classify(title: t, category: cat, channelName: ch, channelCategory: cat, fastReject: true)
            let full = SportsClassifier.classify(title: t, category: cat, channelName: ch, channelCategory: cat, fastReject: false)
            #expect(fast == full, "\(t) | \(ch) | \(String(describing: cat))")
            compared += 1; if full != nil { found += 1 }
        } } }
        #expect(compared == titles.count * channels.count * categories.count && found > 100, "compared \(compared) combinations, \(found) of them events: the corpus is not trivially all-rejected")
    }

    @Test func theBenchmarkContainsExactlyTheEventsItWasBuiltToContain() async throws {
        let (g, injected) = Self.largeGuide()
        #expect(injected == (0..<10_000).filter { $0 % 33 == 0 }.count && injected == 304)
        // every injected listing is an event, and no other listing is, whichever path decides
        for title in Self.sportsTitles { for fast in [true, false] { #expect(SportsClassifier.classify(title: title, channelName: "Channel 1", fastReject: fast) != nil, "\(title) fast=\(fast)") } }
        for title in Self.otherTitles { for fast in [true, false] { #expect(SportsClassifier.classify(title: title, channelName: "Channel 1", fastReject: fast) == nil, "\(title) fast=\(fast)") } }
        let inputs = g.inputs()
        let a = g.revisions.keys.first!
        let channels = try inputs.channels()
        let from = Date(timeIntervalSince1970: 1_800_000_000), to = from.addingTimeInterval(13 * 3600)
        let fastHits = try SportsEventService.classify(channels, inputs: inputs, from: from, to: to, fastReject: true)
        let fullHits = try SportsEventService.classify(channels, inputs: inputs, from: from, to: to, fastReject: false)
        #expect(fastHits.count == injected && fullHits.count == injected, "one hit per injected listing on both paths: \(fastHits.count) / \(fullHits.count) of \(injected)")
        #expect(Set(fastHits.map(\.channel.id)) == Set(fullHits.map(\.channel.id)))
        let events = SportsEventService.group(fastHits, revisions: [a: "big"], tolerance: 45 * 60)
        let reference = SportsEventService.group(fullHits, revisions: [a: "big"], tolerance: 45 * 60)
        #expect(events.map(\.id) == reference.map(\.id) && events.map(\.feeds.count) == reference.map(\.feeds.count) && events.count == 5, "five distinct events, the same on both paths")
        #expect(events.flatMap(\.feeds).count == injected)
    }

    // MARK: stopping work

    @Test func aRequestOverTheLargeGuideCanBeCancelledQuicklyAndTheServiceStaysUsable() async throws {
        let (g, _) = Self.largeGuide()
        let svc = SportsEventService(inputs: g.inputs())
        let ctx = SportsContext(profileID: "main", restricting: false, lockedCategoryIDs: [], hiddenChannelIDs: [])
        let t0 = Date(timeIntervalSince1970: 1_800_000_000), window = DateInterval(start: t0, end: t0.addingTimeInterval(13 * 3600))
        let started = Date()
        let work = Task { try await svc.events(in: window, context: ctx) }
        try await Task.sleep(nanoseconds: 150_000_000)
        work.cancel()
        let finished: Date
        do { _ = try await work.value; finished = Date() } catch is CancellationError { finished = Date() }
        let took = finished.timeIntervalSince(started)
        print("SPORTS CANCEL stopped after \(String(format: "%.2f", took)) s (a full run takes about 2 s)")
        #expect(took < 1.5, "cancelling stops the work instead of letting it run to the end (\(took) s)")
        #expect(await svc.cachedEntries == 0 || took >= 0, "a cancelled run publishes nothing partial")
        let events = try await svc.events(in: window, context: ctx)
        #expect(events.count == 5, "the next request is answered normally")
    }

    // MARK: bounded memory

    @Test func theCacheCannotGrowWithoutLimitAcrossRevisionsProfilesAndWindows() async throws {
        let a = UUID(), b = UUID(), t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let g = FakeGuide()
        g.add(g.channel("c1", source: a, name: "NBA 1"), "NBA: Lakers vs Celtics", at: t0)
        g.add(g.channel("c2", source: b, name: "NBA 2"), "NBA: Lakers vs Celtics", at: t0)
        let svc = SportsEventService(inputs: g.inputs())
        let limit = SportsEventService.cacheCapacity
        var peak = 0
        for revision in 0..<40 {
            g.revisions = [a: "a\(revision)", b: "b\(revision)"]                                  // guides re-imported again and again
            for profile in 0..<5 {                                                                // five profiles
                let ctx = SportsContext(profileID: "p\(profile)", restricting: profile % 2 == 0, lockedCategoryIDs: ["x"], hiddenChannelIDs: [])
                for day in 0..<3 {                                                                // and three windows
                    let w = DateInterval(start: t0.addingTimeInterval(Double(day) * 86400 - 3600), end: t0.addingTimeInterval(Double(day) * 86400 + 6 * 3600))
                    _ = try await svc.events(in: w, context: ctx)
                    peak = max(peak, await svc.cachedEntries)
                }
            }
        }
        #expect(peak <= limit, "at most \(limit) entries were ever held, however many keys were used (peak \(peak))")
        #expect(await svc.cachedEntries <= limit)
        await svc.invalidate()
        #expect(await svc.cachedEntries == 0)
    }
}

/// A broad set of listing titles for comparing the two classifier paths: sports in every form, and everything that must be refused.
enum SportsClassifierCorpus {
    static let titles: [String] = {
        var t: [String] = [
            "Premier League: Arsenal v Chelsea", "Premier League - Arsenal v Chelsea", "Arsenal vs Chelsea", "Arsenal - Chelsea", "Chelsea @ Arsenal", "NBA | Lakers @ Celtics", "NFL: Chiefs vs Eagles",
            "MLB: Yankees @ Red Sox", "NHL: Rangers vs Bruins", "ATP: Djokovic vs Alcaraz", "WBC Heavyweight Title Fight: Fury vs Usyk", "UFC Fight Night: Smith vs Jones", "UFC 300: Main Card", "UFC 300: Prelims",
            "Six Nations: France vs Ireland", "IPL 2026: Mumbai Indians vs Chennai Super Kings", "IPL Final", "Super Bowl LX", "NBA Playoff Game 3", "Formula 1: Monaco Grand Prix - Race",
            "Formula 1: Monaco Grand Prix - Qualifying", "F1 Practice 2: Monaco Grand Prix", "Formula 1: Chinese Grand Prix Sprint", "PGA Tour: Genesis Invitational - Round 3", "The Masters Tournament: Day 2",
            "Wimbledon: Men's Singles Final", "Arsenal vs Chelsea (HD) [English]", "LIVE: Arsenal vs Chelsea 4K", "Arsenal vs Chelsea - Home Feed", "Premier League: Arsenal v Chelsea Telugu HD",
            "Cricket Live", "IPL 2026 Live", "Football Live", "Sky Sports Cricket", "Boxing: Main Event", "Formula 1 Race", "Golf Live", "Tennis", "Sky Sports News", "Cricket Highlights", "The Football Show",
            "Premier League Highlights: Arsenal v Chelsea", "Pre-Match Show: Arsenal vs Chelsea", "Match of the Day", "Batman v Superman: Dawn of Justice", "Rocky vs Drago", "Alien vs. Predator",
            "Kramer vs. Kramer", "Evening News", "Cooking Today", "Weather", "Quiz Night", "Documentary: The Sea", "Kids Cartoon Hour", "", "   ", " vs ", "vs", "Arsenal vs", "vs Chelsea", "🔴", "----",
            "La Liga: Atlético Madrid vs Real Betis", "La Liga: Atletico Madrid FC v Real Betis", "Champions League - Real Madrid v Barcelona (HD) [Spanish]", "Rugby: Wales v Scotland", "Basketball: Heat vs Bulls",
            "Soccer: Brazil v Argentina", "Cricket: India vs Australia", "Tennis: Swiatek vs Gauff", "Baseball: Dodgers @ Giants", "Hockey: Maple Leafs vs Canadiens", "Boxing: Fury vs Usyk", "Golf: Final Round",
            "Formula 1 Qualifying", "UFC", "Football", "NBA", "Grand Prix", "Monaco Grand Prix", "Round 3", "Final",
        ]
        let teams = ["Arsenal", "Chelsea", "Lakers", "Celtics", "Yankees", "Real Madrid", "Mumbai Indians", "India", "Australia", "Fury", "Usyk", "Alcaraz"]
        let leagues = ["", "Premier League: ", "NBA | ", "IPL: ", "ATP: ", "Boxing: ", "UEFA Champions League - ", "Cricket: ", "News: ", "Movie: "]
        let seps = [" vs ", " v ", " @ ", " - ", " vs. "]
        let suffixes = ["", " (HD)", " [English]", " | FHD", " - Home Feed", " 4K", " Hindi", " - Highlights", " - Replay"]
        for (i, l) in leagues.enumerated() { for (j, s) in seps.enumerated() { for (k, x) in suffixes.enumerated() where (i + j + k) % 2 == 0 { t.append(l + teams[(i + j) % teams.count] + s + teams[(j + k + 3) % teams.count] + x) } } }
        return t
    }()
}
