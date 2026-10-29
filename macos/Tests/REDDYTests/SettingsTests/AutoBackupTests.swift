import Testing
import Foundation
@testable import REDDY

@Suite("Backups: organisation and automatic") @MainActor struct AutoBackupTests {
    func container() throws -> AppContainer {
        try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-ab-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
    }

    @Test func organisationWorkIsBackedUpAndRestored() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db, type: .xtream)
        let cats = (0..<3).map { CatalogCategory(id: CatalogCategory.makeID(source: src.id, kind: .channel, provider: "\($0)"), sourceID: src.id, kind: .channel, providerID: "\($0)", name: "F\($0)", sortOrder: $0) }
        let chans = (0..<3).map { i -> Channel in var ch = TestSupport.channel(src, "\(i)", "Chan \(i)", cat: nil); ch.categoryID = cats[i].id; ch.categoryName = cats[i].name; return ch }
        try c.indexer.commitChannels(source: src, categories: cats, channels: chans)
        try c.catalog.setFolderOrder([cats[2].id, cats[0].id])
        try c.favoritesRepo.hide(chans[1].id, kind: "channel")
        try c.favoritesRepo.setOverride(itemID: chans[0].id, displayName: "My Name", categoryName: "Mine", epgID: nil)
        try c.catalog.setCategoryLocked(cats[1].id, true)
        c.playback.channelPrefs.update(chans[2].id) { $0.volumeTrim = -0.2 }

        let data = try c.backup.export(.standard, settings: c.settings, channelPrefs: c.playback.channelPrefs)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("folderOrder") && !text.contains("\"password\""))

        // a fresh library with the same playlist: restoring brings the work back
        let d = try container()
        try d.catalog.save(source: src)
        try d.indexer.commitChannels(source: src, categories: cats, channels: chans)
        let plan = try d.backup.plan(from: data)
        #expect(plan.organisationCount >= 3)
        let r = try d.backup.apply(plan, settings: d.settings, channelPrefs: d.playback.channelPrefs)
        #expect(r.organised >= 3)
        #expect(try d.catalog.categories(sourceID: src.id, kind: .channel, includeHidden: false).map(\.name).prefix(2) == ["F2", "F0"])
        #expect(try d.favoritesRepo.hiddenIDs(kind: "channel").contains(chans[1].id))
        #expect(try d.favoritesRepo.override(for: chans[0].id)?.displayName == "My Name")
        #expect(try d.catalog.lockedCategoryIDs() == [cats[1].id])
        #expect(d.playback.channelPrefs.pref(for: chans[2].id).volumeTrim == -0.2)
    }

    @Test func aWeeklyBackupIsWrittenAndOnlyTheNewestFiveKept() throws {
        let c = try container()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reddy-autobk-\(UUID().uuidString)", isDirectory: true)
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let svc = AutoBackupService(backup: c.backup, settings: c.settings, channelPrefs: c.playback.channelPrefs, directory: dir, now: { clock })
        c.settings.autoBackup = true; c.settings.lastAutoBackup = nil
        #expect(svc.isDue)
        let first = try #require(svc.runIfDue())
        #expect(FileManager.default.fileExists(atPath: first.path) && !svc.isDue)
        clock = clock.addingTimeInterval(3 * 86400); #expect(svc.runIfDue() == nil, "not due after three days")
        for week in 1...7 { clock = clock.addingTimeInterval(7 * 86400 + Double(week)); #expect(svc.runIfDue() != nil) }
        #expect(svc.existing().count == AutoBackupService.keep, "older ones are removed")
        c.settings.autoBackup = false
        clock = clock.addingTimeInterval(30 * 86400); #expect(svc.runIfDue() == nil, "switched off means none")
    }

    /// A source library with playlists, favourites, history and hidden items, exported, for restoring into an empty one.
    private func backupData() throws -> (Data, PlaylistSource) {
        let a = try container()
        let src = try TestSupport.makeSource(a.db, name: "Restored List")
        try a.db.write { c in
            try c.execute("INSERT INTO favorites(item_id,kind,created_at) VALUES('\(src.id.uuidString.lowercased())|c1','channel',1)")
            try c.execute("INSERT INTO watch_history(item_id,kind,title,played_at) VALUES('\(src.id.uuidString.lowercased())|m1','movie','Heat',1000)")
            try c.execute("INSERT INTO hidden_items(item_id,kind,hidden_at) VALUES('\(src.id.uuidString.lowercased())|c2','channel',1)")
        }
        return (try a.backup.export([.sources, .favorites, .collections, .history, .organisation], settings: a.settings, channelPrefs: a.playback.channelPrefs), src)
    }

    @Test func aRestoreThatFailsHalfwayChangesNothing() throws {
        let (data, _) = try backupData()
        let b = try container()
        // A failure in the last step (organisation) must undo the playlists, favourites and history written before it.
        try b.db.write { try $0.exec("CREATE TRIGGER fail_hidden BEFORE INSERT ON hidden_items BEGIN SELECT RAISE(ABORT, 'disk full'); END") }
        let plan = try b.backup.plan(from: data)
        #expect(throws: (any Error).self) { _ = try b.backup.apply(plan, settings: b.settings, channelPrefs: b.playback.channelPrefs) }
        let counts = try b.db.read { c in (try c.scalarInt("SELECT COUNT(*) FROM sources"), try c.scalarInt("SELECT COUNT(*) FROM favorites"), try c.scalarInt("SELECT COUNT(*) FROM watch_history")) }
        #expect(counts.0 == 0 && counts.1 == 0 && counts.2 == 0, "nothing from the failed restore is left behind")
    }

    @Test func preferencesAreOnlyAppliedAfterTheDatabaseSucceeds() throws {
        let a = try container()
        a.settings.guideHoursVisible = 7
        let data = try a.backup.export([.sources, .preferences, .organisation], settings: a.settings, channelPrefs: a.playback.channelPrefs)
        let b = try container()
        let before = b.settings.guideHoursVisible
        _ = try b.backup.plan(from: data)
        try b.db.write { try $0.exec("CREATE TRIGGER fail_src BEFORE INSERT ON sources BEGIN SELECT RAISE(ABORT, 'no'); END") }
        let other = try backupData().0
        let plan = try b.backup.plan(from: other)
        #expect(throws: (any Error).self) { _ = try b.backup.apply(plan, settings: b.settings) }
        #expect(b.settings.guideHoursVisible == before, "a failed restore leaves the settings alone")
    }

    @Test func restoringTheSameBackupTwiceAddsNothingTheSecondTime() throws {
        let (data, _) = try backupData()
        let b = try container()
        _ = try b.backup.apply(try b.backup.plan(from: data), settings: b.settings, channelPrefs: b.playback.channelPrefs)
        func counts() throws -> [Int] { try b.db.read { c in try ["sources", "favorites", "watch_history", "hidden_items"].map { try c.scalarInt("SELECT COUNT(*) FROM \($0)") } } }
        let once = try counts()
        #expect(once == [1, 1, 1, 1])
        let again = try b.backup.apply(try b.backup.plan(from: data), settings: b.settings, channelPrefs: b.playback.channelPrefs)
        #expect(try counts() == once, "no duplicates")
        #expect(again.history == 0 && again.sourcesAdded == 0)
    }
}
