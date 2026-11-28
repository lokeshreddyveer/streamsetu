import Foundation
import Testing
@testable import REDDY

@Suite("Explore breadth, first-seen log and film editions") struct ExploreAndFilmBreadthTests {
    @Test func genreTaxonomyHasFamiliesWithStyles() {
        #expect(MusicGenreTaxonomy.families.count >= 15)
        #expect(MusicGenreTaxonomy.families.allSatisfy { !$0.name.isEmpty && !$0.styles.isEmpty })
        #expect(Set(MusicGenreTaxonomy.families.map(\.id)).count == MusicGenreTaxonomy.families.count)
    }

    @MainActor @Test func registryListsCountriesAndIsPureData() {
        let all = MusicExploreRegistry.all(excluding: "")
        #expect(!MusicExploreRegistry.all(excluding: "US").contains { $0.id == "chart-us" })
        #expect(all.count >= MusicExploreRegistry.countryCodes.count)
        #expect(Set(all.map(\.id)).count == all.count)
    }

    @Test func firstSeenKeepsFirstDateAndBucketsHonestly() {
        let t = MusicTrack(id: "1", providerID: "p", title: "A", durationMs: 0, artists: [])
        let item = MusicBrowseItem.track(t)
        var log = MusicFirstSeenLog()
        let day: TimeInterval = 86_400
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        log.record([item], now: now.addingTimeInterval(-3 * day))
        log.record([item], now: now)
        #expect(log.bucket(item, now: now) == .thisWeek)
        #expect(MusicFirstSeenLog().bucket(item, now: now) == nil)
        log.record([item], now: now.addingTimeInterval(40 * day))
        #expect(log.bucket(item, now: now.addingTimeInterval(40 * day)) == nil)
    }

    @Test func firstSeenLogIsBounded() {
        var log = MusicFirstSeenLog()
        let items = (0..<(MusicFirstSeenLog.limit + 50)).map { MusicBrowseItem.track(MusicTrack(id: "\($0)", providerID: "p", title: "t", durationMs: 0, artists: [])) }
        log.record(items, now: Date())
        #expect(log.seen.count <= MusicFirstSeenLog.limit)
    }
}
