import Foundation
import Testing
@testable import REDDY

private actor Counter {
    var n = 0, running = 0, peak = 0
    func hit() { n += 1 }
    func enter() { running += 1; peak = max(peak, running) }
    func leave() { running -= 1 }
}

private func governor(_ clock: VirtualClock, lane: MusicRequestGovernor.Lane? = nil, global: Int = 6) -> MusicRequestGovernor {
    var lanes = MusicRequestGovernor.defaultLanes
    if let lane { lanes["h"] = lane }
    return MusicRequestGovernor(clock: clock, lanes: lanes, globalLimit: global, jitter: { 0 })
}

@Suite("Request governor") struct MetadataGovernorTests {
    @Test func musicBrainzNeverStartsTwoRequestsWithinAboutOneSecond() async throws {
        let clock = VirtualClock(); let g = governor(clock)
        let starts = StartLog()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<6 {
                group.addTask { _ = try await g.perform(host: "musicbrainz.org", key: "k\(i)") { await starts.add(clock.now()); return Data() } }
            }
            try await group.waitForAll()
        }
        let t = await starts.times.sorted()
        #expect(t.count == 6)
        for (a, b) in zip(t, t.dropFirst()) { #expect(b - a >= 1.0, "gap \(b - a)") }
        let st = await g.stats(host: "musicbrainz.org")
        #expect(st.started == 6)
    }

    @Test func fiftyConcurrentIdenticalRequestsMakeOneNetworkCall() async throws {
        let clock = VirtualClock(); let g = governor(clock); let c = Counter()
        let results = try await withThrowingTaskGroup(of: Int.self) { group -> [Int] in
            for _ in 0..<50 {
                group.addTask {
                    let r = try await g.perform(host: "h", key: "same") { await c.hit(); try await Task.sleep(nanoseconds: 30_000_000); return Data([7]) }
                    return Int(r.data[0])
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 50 && Set(results) == [7])
        let calls = await c.n, flights = await g.activeFlights
        #expect(calls == 1 && flights == 0)
    }

    @Test func a503BacksOffExponentiallyThenSucceeds() async throws {
        let clock = VirtualClock(); let g = governor(clock); let c = Counter()
        let t0 = clock.now()
        let r = try await g.perform(host: "musicbrainz.org", key: "x") {
            await c.hit()
            if await c.n < 3 { throw MusicError.network("HTTP 503") }
            return Data([1])
        }
        let n = await c.n, st = await g.stats(host: "musicbrainz.org")
        #expect(!r.stale && r.data == Data([1]) && n == 3)
        #expect(st.retries == 2)
        // Waits of 1 s then 2 s (jitter fixed at zero); the 1.1 s pacing overlaps the first.
        #expect(abs((clock.now() - t0) - 3.1) < 0.01, "elapsed \(clock.now() - t0)")
    }

    @Test func retryAfterIsHonoured() async throws {
        let clock = VirtualClock(); let g = governor(clock); let c = Counter()
        let before = clock.now()
        _ = try await g.perform(host: "wikidata.org", key: "ra") {
            await c.hit(); if await c.n == 1 { throw MusicError.rateLimited(retryAfter: 7) }; return Data()
        }
        #expect(clock.now() - before >= 7)
    }

    @Test func fiveFailuresOpenTheBreakerAndAProbeClosesIt() async throws {
        let clock = VirtualClock()
        var lane = MusicRequestGovernor.Lane(minInterval: 0, maxConcurrent: 1); lane.maxRetries = 0
        let g = governor(clock, lane: lane); let c = Counter()
        for i in 0..<5 { _ = try? await g.perform(host: "h", key: "f\(i)") { await c.hit(); throw MusicError.network("HTTP 503") } }
        let open1 = await g.isOpen(host: "h"), opens = await g.stats(host: "h").breakerOpens
        #expect(open1 && opens == 1)
        do { _ = try await g.perform(host: "h", key: "after") { await c.hit(); return Data() }; Issue.record("an open breaker must refuse") }
        catch let e as MusicGovernorError { if case .circuitOpen = e {} else { Issue.record("wrong error") } }
        let n5 = await c.n
        #expect(n5 == 5, "no network call while open")
        clock.advance(61)
        let ok = try await g.perform(host: "h", key: "probe") { await c.hit(); return Data([9]) }
        let stillOpen = await g.isOpen(host: "h"), n6 = await c.n
        #expect(ok.data == Data([9]) && !stillOpen && n6 == 6)
    }

    @Test func aFailedProbeReopensForLonger() async throws {
        let clock = VirtualClock()
        var lane = MusicRequestGovernor.Lane(minInterval: 0, maxConcurrent: 1); lane.maxRetries = 0; lane.failuresToOpen = 2
        let g = governor(clock, lane: lane)
        for i in 0..<2 { _ = try? await g.perform(host: "h", key: "f\(i)") { throw MusicError.network("HTTP 503") } }
        clock.advance(61)
        _ = try? await g.perform(host: "h", key: "probe") { throw MusicError.network("HTTP 503") }
        clock.advance(61)
        let open2 = await g.isOpen(host: "h"), opens2 = await g.stats(host: "h").breakerOpens
        #expect(open2, "the second opening lasts twice as long")
        #expect(opens2 == 2)
    }

    @Test func staleWhileErrorServesTheLastAnswerWhenTheNetworkFailsOrTheBreakerIsOpen() async throws {
        let clock = VirtualClock()
        var lane = MusicRequestGovernor.Lane(minInterval: 0, maxConcurrent: 1); lane.maxRetries = 0; lane.failuresToOpen = 1
        let g = governor(clock, lane: lane)
        let r = try await g.perform(host: "h", key: "a", stale: { Data([4]) }) { throw MusicError.network("HTTP 503") }
        #expect(r.stale && r.data == Data([4]))
        let opened = await g.isOpen(host: "h")
        #expect(opened)
        let r2 = try await g.perform(host: "h", key: "b", stale: { Data([5]) }) { Data([0]) }
        #expect(r2.stale && r2.data == Data([5]), "an open breaker answers from the cache without an error")
        do { _ = try await g.perform(host: "h", key: "c") { Data() }; Issue.record("no stale data means the error") } catch {}
    }

    @Test func notFoundDoesNotCountAgainstTheHost() async throws {
        let clock = VirtualClock()
        var lane = MusicRequestGovernor.Lane(minInterval: 0, maxConcurrent: 1); lane.failuresToOpen = 2
        let g = governor(clock, lane: lane)
        for i in 0..<5 { _ = try? await g.perform(host: "h", key: "n\(i)") { throw MusicError.notFound } }
        let o = await g.isOpen(host: "h")
        #expect(!o)
    }

    @Test func globalConcurrencyIsBoundedAtSix() async throws {
        let clock = VirtualClock()
        var lane = MusicRequestGovernor.Lane(minInterval: 0, maxConcurrent: 20); lane.maxRetries = 0
        let g = governor(clock, lane: lane); let c = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<24 { group.addTask { _ = try await g.perform(host: "h", key: "g\(i)") { await c.enter(); try await Task.sleep(nanoseconds: 15_000_000); await c.leave(); return Data() } } }
            try await group.waitForAll()
        }
        let peak = await c.peak
        #expect(peak <= 6 && peak >= 2)
    }

    @Test func perHostConcurrencyIsOneForMusicBrainz() async throws {
        let clock = VirtualClock(); let g = governor(clock); let c = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<4 { group.addTask { _ = try await g.perform(host: "musicbrainz.org", key: "m\(i)") { await c.enter(); try await Task.sleep(nanoseconds: 10_000_000); await c.leave(); return Data() } } }
            try await group.waitForAll()
        }
        let peak = await c.peak
        #expect(peak == 1)
    }

    @Test func cancellingEveryWaiterCancelsTheCall() async throws {
        let clock = VirtualClock(); let g = governor(clock); let flag = Flag()
        let t = Task { try await g.perform(host: "h", key: "slow") { do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { await flag.set(); throw error }; return Data() } }
        try await Task.sleep(nanoseconds: 50_000_000)
        t.cancel()
        _ = try? await t.value
        try await Task.sleep(nanoseconds: 100_000_000)
        let saw = await flag.value, flights = await g.activeFlights
        #expect(saw, "the network task saw the cancellation")
        #expect(flights == 0)
    }

    @Test func laneKeysFoldWikipediaAndWikidataHosts() {
        #expect(MusicRequestGovernor.laneKey(for: "www.wikidata.org") == "wikidata.org")
        #expect(MusicRequestGovernor.laneKey(for: "te.wikipedia.org") == "en.wikipedia.org")
        #expect(MusicRequestGovernor.laneKey(for: "query.wikidata.org") == "query.wikidata.org")
    }

    @Test func governedTransportServesTheLastReplyWhenTheNetworkFails() async throws {
        let clock = VirtualClock()
        let g = MusicRequestGovernor(clock: clock, jitter: { 0 })
        let mem = MusicResponseMemory()
        let flaky = FlakyTransport()
        let http = MusicHTTP(transport: flaky)
        let t = MusicGovernedTransport(governor: g, http: http, memory: mem)
        let url = URL(string: "https://musicbrainz.org/ws/2/recording/x")!
        let first = try await t.get(url, query: ["fmt": "json"], headers: [:])
        #expect(String(decoding: first, as: UTF8.self) == "ok")
        flaky.fail = true
        let second = try await t.get(url, query: ["fmt": "json"], headers: [:])
        #expect(String(decoding: second, as: UTF8.self) == "ok", "stale-while-error")
        #expect(flaky.lastUserAgent?.hasPrefix("StreamSetu") == true && flaky.lastUserAgent?.contains("@") == false)
    }
}

private actor StartLog { var times: [TimeInterval] = []; func add(_ t: TimeInterval) { times.append(t) } }
private actor Flag { var value = false; func set() { value = true } }

private final class FlakyTransport: MusicHTTPTransport, @unchecked Sendable {
    var fail = false
    private(set) var lastUserAgent: String?
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastUserAgent = request.value(forHTTPHeaderField: "User-Agent")
        if fail { throw MusicError.network("HTTP 503") }
        return (Data("ok".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
