import Testing
import Foundation
@testable import REDDY

@Suite("Sync") @MainActor struct SyncTests {
    func container() throws -> AppContainer {
        try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-sync-\(UUID().uuidString).sqlite").path,
                         credentials: InMemoryCredentialStore())
    }

    func playlist(_ lines: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("list-\(UUID().uuidString).m3u")
        try ("#EXTM3U\n" + lines).write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    static let sample = """
    #EXTINF:-1 tvg-id="bbc" group-title="News",BBC News
    http://s/live/1.ts
    #EXTINF:-1 group-title="News",CNN
    http://s/live/2.ts
    #EXTINF:-1 group-title="Films",A Movie (2020)
    http://s/movie/u/p/9.mp4
    #EXTINF:-1,======== Bulgaria Channels ========
    http://s/live/3.ts
    """

    @Test func syncsAChannelsAndMoviesFromAFileSource() async throws {
        let c = try container()
        let src = try c.sources.addM3UFile(name: "Local", fileURL: try playlist(Self.sample))
        await c.sync.start(sourceID: src.id)?.value
        let p = await c.sync.progress(for: src.id)
        guard case .completed = p?.state else { Issue.record("not completed: \(String(describing: p?.state))"); return }
        let counts = try c.catalog.counts(sourceID: src.id)
        #expect(counts.channels == 2 && counts.movies == 1, "separator rows are dropped, /movie/ urls become movies")
        #expect(try c.catalog.source(id: src.id)?.syncStatus == "completed")
        #expect(try c.catalog.syncStates(sourceID: src.id).contains { $0.scope == "live" && $0.itemCount == 2 })
        #expect(try c.health.check().healthy)
    }

    @Test func aSecondSyncStartedWhileRunningIsTheSameRun() async throws {
        let c = try container()
        let src = try c.sources.addM3UFile(name: "Local", fileURL: try playlist(Self.sample))
        let a = await c.sync.start(sourceID: src.id)
        let b = await c.sync.start(sourceID: src.id)
        #expect(a != nil && b != nil)
        await a?.value
        #expect(!(await c.sync.isRunning(src.id)))
    }

    @Test func anEmptyPlaylistFailsVisiblyAndKeepsTheExistingCatalog() async throws {
        let c = try container()
        let file = try playlist(Self.sample)
        let src = try c.sources.addM3UFile(name: "Local", fileURL: file)
        await c.sync.start(sourceID: src.id)?.value
        #expect(try c.catalog.counts(sourceID: src.id).channels == 2)
        // the provider now returns nothing
        let stored = StorageService.importedPlaylists.appendingPathComponent(src.baseURL)
        try "#EXTM3U\n".write(to: stored, atomically: true, encoding: .utf8)
        c.sources.invalidateProvider(src.id)
        await c.sync.start(sourceID: src.id)?.value
        guard case .failed(let message) = await c.sync.progress(for: src.id)?.state else { Issue.record("expected a failed state"); return }
        #expect(message.contains("No channels") || message.contains("not look") || message.contains("doesn't look"))
        #expect(try c.catalog.counts(sourceID: src.id).channels == 2, "a bad refresh never replaces a good catalog")
        #expect(try c.catalog.source(id: src.id)?.syncStatus == "failed")
    }

    @Test func aMissingFileIsReportedNotCrashed() async throws {
        let c = try container()
        let src = try c.sources.addM3UFile(name: "Local", fileURL: try playlist(Self.sample))
        try FileManager.default.removeItem(at: StorageService.importedPlaylists.appendingPathComponent(src.baseURL))
        c.sources.invalidateProvider(src.id)
        await c.sync.start(sourceID: src.id)?.value
        guard case .failed = await c.sync.progress(for: src.id)?.state else { Issue.record("expected failure"); return }
    }

    @Test func observersReceiveProgress() async throws {
        final class Box: @unchecked Sendable { var states: [SourceSyncState] = []; let lock = NSLock(); func add(_ s: SourceSyncState) { lock.lock(); states.append(s); lock.unlock() } }
        let c = try container()
        let box = Box()
        _ = await c.sync.addObserver { box.add($0.state) }
        let src = try c.sources.addM3UFile(name: "Local", fileURL: try playlist(Self.sample))
        await c.sync.start(sourceID: src.id)?.value
        let states = box.states
        #expect(states.contains(.connecting) && states.contains(.indexing))
        if case .completed = states.last { } else { Issue.record("last state should be completed: \(String(describing: states.last))") }
    }

    @Test func schedulerPicksOnlyStaleEnabledSources() {
        let now = Date()
        func src(_ name: String, enabled: Bool = true, last: Date?) -> PlaylistSource { PlaylistSource(name: name, type: .m3uRemote, baseURL: "x", enabled: enabled, lastSync: last) }
        let list = [src("fresh", last: now.addingTimeInterval(-3600)), src("stale", last: now.addingTimeInterval(-13 * 3600)), src("never", last: nil), src("off", enabled: false, last: nil)]
        let due = SyncScheduler.dueSources(list, now: now, interval: 12 * 3600).map(\.name)
        #expect(Set(due) == ["stale", "never"])
    }

    @Test func removingASourceDeletesItsFileAndSecrets() throws {
        let c = try container()
        let src = try c.sources.addM3UFile(name: "Local", fileURL: try playlist(Self.sample))
        let file = StorageService.importedPlaylists.appendingPathComponent(src.baseURL)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try c.sources.remove(src.id)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try c.catalog.sources().isEmpty)
    }
}
