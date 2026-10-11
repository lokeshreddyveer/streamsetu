import Testing
import Foundation
@testable import REDDY

/// End-to-end check against a real Xtream provider. Skipped unless REDDY_TEST_SERVER / _USER / _PASS are set:
///   REDDY_TEST_SERVER=http://host:port REDDY_TEST_USER=… REDDY_TEST_PASS=… ./Scripts/run-tests.sh LiveProvider
@Suite("Live provider (opt-in)", .enabled(if: ProcessInfo.processInfo.environment["REDDY_TEST_SERVER"] != nil))
@MainActor struct LiveProviderTests {
    @Test func fullSyncSearchDetailsAndGuide() async throws {
        let env = ProcessInfo.processInfo.environment
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("reddy-live-\(UUID().uuidString).sqlite").path
        let c = try AppContainer(databasePath: path, credentials: InMemoryCredentialStore())
        let t0 = Date()
        func lap(_ s: String) { print(String(format: "  [%5.1fs] %@", Date().timeIntervalSince(t0), s)) }

        let source = try await c.sources.addXtream(name: "Live", server: env["REDDY_TEST_SERVER"]!, username: env["REDDY_TEST_USER"]!, password: env["REDDY_TEST_PASS"]!)
        lap("account verified: live=\(source.capabilities.live) movies=\(source.capabilities.movies) series=\(source.capabilities.series)")
        let task = await c.sync.start(sourceID: source.id, forceGuide: true)
        await task?.value
        let progress = await c.sync.progress(for: source.id)
        lap("sync finished: \(String(describing: progress?.state)) live=\(progress?.liveCount ?? 0) movies=\(progress?.movieCount ?? 0) series=\(progress?.seriesCount ?? 0) guide=\(progress?.guide ?? "-")")
        guard case .completed = progress?.state else { Issue.record("sync did not complete: \(String(describing: progress?.state)) \(progress?.notes ?? [])"); return }

        let counts = try c.catalog.counts(sourceID: source.id)
        #expect(counts.channels > 0)
        if source.capabilities.movies { #expect(counts.movies > 0) }
        if source.capabilities.series { #expect(counts.series > 0) }
        lap("counts \(counts)")

        // search at scale
        let t1 = Date()
        let hits = try await c.search.search("news")
        lap(String(format: "search 'news': %d channels, %d movies, %d series in %.0f ms", hits.channels.count, hits.movies.count, hits.series.count, Date().timeIntervalSince(t1) * 1000))
        #expect(!hits.isEmpty)
        #expect(try c.catalog.channels(ChannelQuery(limit: 50)).count == 50)

        // index health after a big import
        let health = try c.health.check()
        lap("index health: \(health.healthy) docs=\(health.searchDocs)/\(health.catalogItems)")
        #expect(health.healthy)

        // re-sync is idempotent and fast, keeps user data
        let first = try #require(try c.catalog.channels(ChannelQuery(limit: 1)).first)
        _ = try c.favorites.toggle(id: first.id, kind: .channel)
        let t2 = Date()
        await c.sync.start(sourceID: source.id)?.value
        lap(String(format: "second sync in %.1f s", Date().timeIntervalSince(t2)))
        #expect(try c.catalog.channel(id: first.id)?.isFavorite == true)
        #expect(try c.catalog.counts(sourceID: source.id).channels == counts.channels)

        // guide
        let cov = try c.epgRepo.guideCoverage(sourceID: source.id)
        lap("guide: \(cov.channels) channels, \(cov.programs) programs, \(cov.mapped) mapped")
        if cov.programs > 0 {
            let mapped = try c.epgRepo.nowNext(channelIDs: try c.catalog.channels(ChannelQuery(onlyWithGuide: true, limit: 200)).map(\.id), at: Date())
            lap("now/next available for \(mapped.count) of the first 200 guide channels")
            #expect(!mapped.isEmpty)
        }

        // details
        if counts.movies > 0, let m = try c.catalog.movies(VODQuery(limit: 1)).first {
            let d = try await c.details.movie(id: m.id)
            lap("movie detail '\(m.title)': overview \(d.overview == nil ? "none" : "ok"), genre \(d.genre ?? "-")")
        }
        if counts.series > 0, let s = try c.catalog.series(VODQuery(limit: 1)).first {
            let d = try await c.details.series(id: s.id)
            lap("series detail '\(s.title)': \(d.seasons.count) seasons, \(d.episodes.count) episodes")
            #expect(!d.episodes.isEmpty)
        }

        // stream URL at playback time, and the endpoint answers
        let req = try StreamResolver(catalog: c.catalog, sources: c.sources, history: c.historyRepo).resolve(channel: first)
        #expect(req.url.scheme == "http" && req.isLive)
        var r = URLRequest(url: req.url); r.setValue("VLC/3.0.20 LibVLC/3.0.20", forHTTPHeaderField: "User-Agent"); r.timeoutInterval = 20
        let (bytes, resp) = try await URLSession.shared.bytes(for: r)
        var n = 0
        for try await _ in bytes { n += 1; if n >= 188 * 4 { break } }
        lap("stream answered HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0), read \(n) bytes")
        #expect((resp as? HTTPURLResponse)?.statusCode == 200 && n >= 188)

        print("  DB size:", StorageService.shared.formatBytes(Int64((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)))
    }
}
