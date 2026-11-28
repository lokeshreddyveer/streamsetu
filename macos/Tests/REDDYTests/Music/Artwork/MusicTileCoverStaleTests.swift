import Testing
import Foundation
@testable import REDDY

// App-only: the category cover cache keeps an older cover (stale) so a tile can show it while the new one is fetched.
@Suite("Category tile covers: seven days, stale while refreshing")
struct MusicTileCoverStaleTests {
    private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    @Test func freshForSevenDaysThenStaleButStillKnownThenDropped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        var cache = MusicGenreArtworkCache(directory: dir, now: { clock.now })
        cache.set("https://example.org/a.jpg", for: "k")
        #expect(MusicGenreArtworkCache.ttl == 7 * 86_400)
        clock.now = clock.now.addingTimeInterval(6 * 86_400)
        #expect(cache.url(for: "k") != nil)
        clock.now = clock.now.addingTimeInterval(2 * 86_400)
        #expect(cache.url(for: "k") == nil)
        #expect(cache.staleURL(for: "k") == "https://example.org/a.jpg")
        cache.save()
        #expect(MusicGenreArtworkCache(directory: dir, now: { clock.now }).staleURL(for: "k") != nil)
        clock.now = clock.now.addingTimeInterval(7 * 86_400)
        cache.save()
        #expect(MusicGenreArtworkCache(directory: dir, now: { clock.now }).staleURL(for: "k") == nil)
    }

    @Test func sixResolvesRunAtOnce() {
        #expect(MusicTileCoverPolicy.parallel == 6)
    }
}
