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
}
