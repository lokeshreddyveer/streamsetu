import Testing
import Foundation
@testable import REDDY

@Suite("Settings: persistence, validation, migration, effects, maintenance, backup") @MainActor struct SettingsTests {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "reddy-settings-\(UUID().uuidString)")! }
    func container() throws -> AppContainer {
        try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-set-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
    }

    // MARK: persistence & validation

    @Test func everyChangedSettingSurvivesARelaunch() {
        let d = defaults()
        let a = AppSettings(defaults: d)
        a.accent = .blue; a.density = .extraCompact; a.reduceMotion = true; a.sidebarLaunch = .collapsed; a.clickBehavior = .singleClick
        a.defaultLibrarySort = .topRated; a.defaultChannelSort = .alphabetical; a.rememberFolders = false; a.remindersEnabled = false
        a.enginePreference = .mpv; a.hardwareDecoding = .software; a.deinterlace = .on; a.videoQuality = .dataSaver; a.bufferingMode = .large
        a.audioProcessing = .nightMode; a.subtitleSize = 140; a.subtitleBackground = 0.2; a.subtitleColor = .yellow
        a.rememberPosition = false; a.resumeAutomatically = false; a.catalogRefresh = .manual; a.guideRefresh = .every24; a.guideRetentionDays = 3
        let b = AppSettings(defaults: d)
        #expect(b.accent == .blue && b.density == .extraCompact && b.reduceMotion && b.sidebarLaunch == .collapsed && b.clickBehavior == .singleClick)
        #expect(b.defaultLibrarySort == .topRated && b.defaultChannelSort == .alphabetical && !b.rememberFolders && !b.remindersEnabled)
        #expect(b.enginePreference == .mpv && b.hardwareDecoding == .software && b.deinterlace == .on && b.videoQuality == .dataSaver && b.bufferingMode == .large)
        #expect(b.audioProcessing == .nightMode && b.subtitleSize == 140 && b.subtitleBackground == 0.2 && b.subtitleColor == .yellow)
        #expect(!b.rememberPosition && !b.resumeAutomatically && b.catalogRefresh == .manual && b.guideRefresh == .every24 && b.guideRetentionDays == 3)
    }

    @Test func invalidStoredValuesFallBackToSafeDefaults() {
        let d = defaults()
        d.set("Chartreuse", forKey: "settings.accent"); d.set(9000.0, forKey: "settings.subsize"); d.set(-3.0, forKey: "settings.subbg")
        d.set(99, forKey: "settings.guideretention"); d.set(5.0, forKey: "settings.guidehours"); d.set(Double.nan, forKey: "settings.volume")
        let s = AppSettings(defaults: d)
        #expect(s.accent == .coral)
        #expect(s.subtitleSize == 200 && s.subtitleBackground == 0)
        #expect(s.guideRetentionDays == 14 && s.guideHoursVisible == 3)
        #expect(s.volume.isFinite && (0...1).contains(s.volume))
    }

    @Test func versionOneSettingsAreMigratedNotLost() {
        let d = defaults()
        d.set(false, forKey: "settings.hwdec"); d.set(true, forKey: "settings.deinterlace"); d.set("Amber", forKey: "settings.accent")
        let s = AppSettings(defaults: d)
        #expect(s.hardwareDecoding == .software, "the old switch 'off' becomes Software decoding")
        #expect(s.deinterlace == .on)
        #expect(s.accent == .coral, "a removed accent maps to the default")
        #expect(d.integer(forKey: SettingsMigrator.versionKey) == SettingsMigrator.currentVersion)
        let violet = defaults(); violet.set("Violet", forKey: "settings.accent")
        #expect(AppSettings(defaults: violet).accent == .purple)
    }

    @Test func resetsDoExactlyWhatTheyName() {
        let d = defaults(); let s = AppSettings(defaults: d)
        s.accent = .green; s.density = .compact; s.enginePreference = .mpv; s.catalogRefresh = .manual; s.collapseDuplicates = false
        s.resetAppearance()
        #expect(s.accent == .coral && s.density == .comfortable && s.enginePreference == .mpv && s.catalogRefresh == .manual, "appearance reset leaves everything else")
        s.resetPlayback()
        #expect(s.enginePreference == .automatic && s.catalogRefresh == .manual && !s.collapseDuplicates)
        s.resetAll()
        #expect(s.catalogRefresh == .every12 && s.collapseDuplicates)
    }

    // MARK: runtime effects

    @Test func settingsChooseTheRealValuesTheEnginesReceive() {
        #expect(HardwareDecoding.software.mpvValue == "no" && HardwareDecoding.enabled.mpvValue == "videotoolbox-copy" && HardwareDecoding.automatic.mpvValue == "auto-safe")
        #expect(DeinterlaceMode.automatic.isOn(live: true) && !DeinterlaceMode.automatic.isOn(live: false))
        #expect(DeinterlaceMode.on.isOn(live: false) && !DeinterlaceMode.off.isOn(live: true))
        #expect(VideoQualityPreference.dataSaver.peakBitRate < VideoQualityPreference.balanced.peakBitRate && VideoQualityPreference.highest.peakBitRate == 0)
        #expect(VideoQualityPreference.highest.mpvHLSBitrate == "max" && VideoQualityPreference.dataSaver.mpvHLSBitrate == "min")
        var cfg = MPVConfiguration()
        cfg.hardwareDecoding = .software; cfg.deinterlace = true; cfg.hlsBitrate = "min"; cfg.cacheSeconds = BufferingMode.large.mpvCacheSeconds
        let o = Dictionary(cfg.options, uniquingKeysWith: { a, _ in a })
        #expect(o["hwdec"] == "no" && o["deinterlace"] == "yes" && o["hls-bitrate"] == "min" && o["cache-secs"] == "60")
        #expect(BufferingMode.lowLatency.mpvCacheSeconds < BufferingMode.standard.mpvCacheSeconds && BufferingMode.standard.mpvCacheSeconds < BufferingMode.large.mpvCacheSeconds)
    }

    @Test func playbackStartsFromTheSettingsAndRespectsResumeChoices() throws {
        let c = try container()
        c.settings.videoQuality = .dataSaver
        let src = try c.sources.addM3U(name: "Local", url: "http://127.0.0.1:9/l.m3u")
        var m = TestSupport.movie(src, "m", "Film", year: 2020); m.streamRef = "http://127.0.0.1:9/movie/m.mp4"
        try c.indexer.commitMovies(source: src, categories: [], movies: [m])
        let movie = try #require(try c.catalog.movies(VODQuery(sourceID: src.id)).first)
        try c.historyRepo.saveProgress(WatchProgress(itemID: movie.id, kind: .movie, seriesID: nil, positionSeconds: 1200, durationSeconds: 6000, updatedAt: Date(), completed: false))
        c.settings.resumeAutomatically = true
        c.playback.play(movie: movie)
        #expect(c.playback.current?.startPosition == 1200, "resumes where it stopped")
        c.playback.stop()
        c.settings.resumeAutomatically = false
        c.playback.play(movie: movie)
        #expect(c.playback.current?.startPosition == 0, "starts over when automatic resume is off")
        c.playback.play(movie: movie, resume: true)
        #expect(c.playback.current?.startPosition == 1200, "an explicit Resume still resumes")
        c.playback.stop()
    }

    @Test func channelOrderPreferenceChangesTheQuery() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db)
        try c.indexer.commitChannels(source: src, categories: [], channels: [
            TestSupport.channel(src, "1", "Zeta", order: 0), TestSupport.channel(src, "2", "Alpha", order: 1), TestSupport.channel(src, "3", "Mid", order: 2)])
        let provider = try c.catalog.channels(ChannelQuery(sourceID: src.id)).map(\.name)
        let alpha = try c.catalog.channels(ChannelQuery(sourceID: src.id, sortAlphabetically: true)).map(\.name)
        #expect(provider == ["Zeta", "Alpha", "Mid"] && alpha == ["Alpha", "Mid", "Zeta"])
    }

    @Test func densityChangesRealLayoutValues() {
        #expect(LayoutDensity.compact.posterRange.max < LayoutDensity.comfortable.posterRange.max)
        #expect(LayoutDensity.extraCompact.channelRowHeight < LayoutDensity.compact.channelRowHeight)
        let wide = PosterGridLayout.compute(available: 1200, minCard: LayoutDensity.comfortable.posterRange.min, maxCard: LayoutDensity.comfortable.posterRange.max)
        let tight = PosterGridLayout.compute(available: 1200, minCard: LayoutDensity.extraCompact.posterRange.min, maxCard: LayoutDensity.extraCompact.posterRange.max)
        #expect(tight.columns > wide.columns, "denser settings fit more cards in the same width")
    }

    @Test func syncIntervalsReachTheServices() throws {
        let c = try container()
        c.scheduler.setCatalogInterval(nil); #expect(c.scheduler.catalogInterval == nil, "manual: the scheduler does nothing on its own")
        c.scheduler.setCatalogInterval(RefreshInterval.every6.seconds); #expect(c.scheduler.catalogInterval == 6.0 * 3600)
        c.epgSync.configure(refreshInterval: nil, pastRetentionDays: 7)
        #expect(c.epgSync.refreshInterval == nil && c.epgSync.pastHours == 168)
        c.epgSync.configure(refreshInterval: 24 * 3600, pastRetentionDays: 0)
        #expect(c.epgSync.pastHours == 3, "never less than the 3 hours the grid needs")
    }

    // MARK: maintenance

    @Test func optimizeVerifyAndRebuildLeaveTheCatalogIntact() async throws {
        let c = try container()
        let src = try FixtureLibrary.seed(c)
        let before = try c.catalog.counts(sourceID: src.id)
        let opt = try c.maintenance.optimizeDatabase()
        #expect(opt.sizeAfter >= 0 && c.maintenance.lastOptimize != nil)
        let integrity = try c.maintenance.verifyDatabase()
        #expect(integrity.ok && integrity.schemaVersion == DatabaseMigrator.latestVersion && c.maintenance.lastIntegrityCheck != nil)

        let stats0 = try c.maintenance.indexStats()
        #expect(stats0.total == before.channels + before.movies + before.series && stats0.health.healthy)
        final class Phases: @unchecked Sendable { var seen: [IndexRebuildPhase] = []; let l = NSLock(); func add(_ p: IndexRebuildPhase) { l.lock(); seen.append(p); l.unlock() } }
        let phases = Phases()
        try c.maintenance.rebuildSearchIndex { phases.add($0) }
        #expect(phases.seen == [.clearing, .channels, .movies, .series, .fullText, .done], "real phases, in order")
        let stats1 = try c.maintenance.indexStats()
        #expect(stats1.total == stats0.total && stats1.health.healthy, "same documents after the rebuild, and SQLite's integrity check passes: \(stats1.health.integrityMessage)")
        let triggers = try c.db.read { try $0.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND tbl_name='search_docs'") }
        #expect(triggers == 3, "the sync triggers are back, so later catalog updates keep the index current")
        #expect(try c.catalog.counts(sourceID: src.id) == before, "the catalog itself was never touched")
        let hits = try await c.search.search("harvest", filters: SearchFilters(kinds: [.movie], sourceID: src.id), limit: 10)
        #expect(!hits.movies.isEmpty, "search still works after a rebuild")
    }

    @Test func maintenanceWaitsForCatalogWritesInsteadOfOverlappingThem() async throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db)
        let items = (0..<400).map { TestSupport.channel(src, "\($0)", "Channel \($0)", order: $0) }
        let indexer = c.indexer, maintenance = c.maintenance
        async let commit: Void = Task.detached { _ = try indexer.commitChannels(source: src, categories: [], channels: items) }.value
        async let optimize: OptimizeReport = Task.detached { try maintenance.optimizeDatabase() }.value
        try await commit; _ = try await optimize
        #expect(try c.catalog.counts(sourceID: src.id).channels == 400, "the import completed intact")
    }

    @Test func temporaryFilesAreFoundAndClearedButRecentOnesAreSpared() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reddy-tmp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("REDDY-download-old.tmp"), fresh = dir.appendingPathComponent("REDDY-download-new.tmp"), other = dir.appendingPathComponent("someone-elses.tmp")
        for f in [old, fresh, other] { try Data(repeating: 1, count: 1000).write(to: f) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path)
        let service = try container().maintenance
        let r = service.clearTemporaryFiles(in: dir)
        #expect(r.files == 1 && !FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path), "a file that may be an active download is left alone")
        #expect(FileManager.default.fileExists(atPath: other.path), "only REDDY's own files are touched")
    }

    // MARK: backup

    @Test func backupNeverContainsPasswordsAndRestoresAsPlaceholders() throws {
        let c = try container()
        let x = try c.sources.addM3U(name: "Remote", url: "http://user:secret@example.com/list.m3u?token=abc123")
        let key = ReddyBackup.self
        _ = key
        let data = try c.backup.export([.sources, .preferences], settings: c.settings)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("secret") && !text.contains("abc123"), "no password or token in the file")
        #expect(text.contains("Remote"))

        let c2 = try container()
        let plan = try c2.backup.plan(from: data)
        #expect(plan.newSources.count == 1 && plan.duplicateSources.isEmpty)
        let r = try c2.backup.apply(plan, settings: c2.settings)
        #expect(r.sourcesAdded == 1)
        let restored = try #require(try c2.catalog.sources().first)
        #expect(restored.id == x.id && !restored.enabled && restored.credentialRef == nil && !c2.sources.hasCredentials(restored), "same id, switched off, asking for its login")
    }

    @Test func restoreKeepsFavoritesAndCollectionsLinkedAndSkipsDuplicates() throws {
        let c = try container()
        let src = try TestSupport.makeSource(c.db, name: "Mine")
        try c.indexer.commitChannels(source: src, categories: [], channels: [TestSupport.channel(src, "1", "BBC")])
        let ch = try #require(try c.catalog.channels(ChannelQuery()).first)
        try c.favoritesRepo.setFavorite(ch.id, kind: .channel, on: true)
        let col = try c.favoritesRepo.createCollection(name: "News")
        try c.favoritesRepo.add(itemID: ch.id, kind: .channel, toCollection: col.id)
        try c.historyRepo.recordPlay(itemID: ch.id, kind: .channel, title: "BBC")
        let data = try c.backup.export([.sources, .favorites, .collections, .history], settings: c.settings)

        // restoring onto the same data adds nothing twice
        let plan = try c.backup.plan(from: data)
        #expect(plan.duplicateSources.count == 1 && plan.newSources.isEmpty)
        let r = try c.backup.apply(plan, settings: c.settings)
        #expect(r.sourcesAdded == 0 && r.sourcesSkipped == 1)
        #expect(try c.favoritesRepo.favoriteIDs(kind: .channel) == [ch.id])
        #expect(try c.favoritesRepo.collections().filter { $0.name == "News" }.count == 1, "the collection is merged, not duplicated")

        // a different Mac: the playlist comes back with the same id, so the favorite lines up before any sync
        let other = try container()
        _ = try other.backup.apply(try other.backup.plan(from: data), settings: other.settings)
        #expect(try other.favoritesRepo.favoriteIDs(kind: .channel) == [ch.id])
    }

    @Test func remapPointsItemsAtTheExistingPlaylist() {
        let a = UUID().uuidString.lowercased(), b = UUID().uuidString.lowercased()
        #expect(BackupService.remap("\(a)|channel|7", [a: b]) == "\(b)|channel|7")
        #expect(BackupService.remap("\(a)|channel|7", [:]) == "\(a)|channel|7")
    }

    @Test func invalidBackupsAreRejectedWithClearMessages() throws {
        let c = try container()
        #expect(throws: BackupError.self) { _ = try c.backup.plan(from: Data("not json".utf8)) }
        #expect(throws: BackupError.self) { _ = try c.backup.plan(from: Data(#"{"format":"reddy-backup","version":99,"createdAt":"2026-01-01T00:00:00Z","appVersion":"9","includes":[]}"#.utf8)) }
        #expect(throws: BackupError.self) { _ = try c.backup.plan(from: Data(count: BackupService.maxBytes + 1)) }
    }

    @Test func preferencesRestoreOnlyKnownValidValues() {
        let s = AppSettings(defaults: defaults())
        let n = s.apply(snapshot: ["settings.accent": "Blue", "settings.subsize": "9999", "settings.engine": "Nonsense", "settings.audiodev": "evil-device", "other.key": "x"])
        #expect(n == 2 && s.accent == .blue && s.subtitleSize == 200, "valid values applied (clamped); unknown or invalid ones ignored")
        #expect(s.audioOutputUID == "", "machine-specific settings are never restored")
    }

    // MARK: reset & diagnostics

    @Test func removeEverythingNamesAndDeletesExactlyItsList() throws {
        let c = try container()
        let src = try FixtureLibrary.seed(c)
        try FixtureLibrary.seedUserData(c)
        _ = try c.favoritesRepo.createCollection(name: "Keep?")
        let before = c.dataReset.summary()
        #expect(before.playlists == 1 && before.channels > 0 && before.favorites > 0 && before.collections == 1 && before.resumePoints > 0)
        #expect(before.removeAllLines.count == 5 && before.removeAllLines[0].contains("1 playlist"))
        try c.dataReset.removeEverything()
        let after = c.dataReset.summary()
        #expect(after == DataSummary(), "everything in the list is gone")
        #expect(try c.catalog.sources().isEmpty)
        _ = src
    }

    @Test func clearViewingHistoryKeepsFavoritesAndCollections() throws {
        let c = try container()
        try FixtureLibrary.seed(c); try FixtureLibrary.seedUserData(c)
        let favs = c.dataReset.summary().favorites
        try c.dataReset.clearViewingHistory()
        let s = c.dataReset.summary()
        #expect(s.historyEntries == 0 && s.resumePoints == 0 && s.favorites == favs)
    }

    @Test func diagnosticsReportIsComprehensiveAndSanitized() throws {
        let c = try container()
        _ = try c.sources.addM3U(name: "Secret List", url: "http://user:hunter2@iptv.example.com/get.m3u?password=hunter2&token=tok")
        c.diagnostics.record("request to http://user:hunter2@iptv.example.com/live/1.ts?token=tok failed: timeout")
        let report = c.diagnostics.report(playback: "state=idle", engines: ["Apple AVPlayer: available"])
        for needle in ["StreamSetu", "macOS", "PLAYBACK", "DATABASE", "PLAYLISTS", "SYNC DURATIONS", "PLAYBACK OUTCOMES", "RECENT ERRORS", "Schema v"] { #expect(report.contains(needle), "\(needle)") }
        #expect(!report.contains("hunter2") && !report.contains("tok&") && !report.contains("password="), "no credentials or tokens")
        #expect(report.contains("iptv.example.com") == true || report.contains("host"), "playlists appear by host only")
        #expect(report.contains("timeout"), "errors are grouped by category")
    }

    @Test func notificationStatusIsHonestWhenNotRunningAsAnApp() async {
        let s = await NotificationPermission.current()
        #expect(s == .unavailable, "in a test host there is no app bundle, and REDDY says so instead of guessing")
    }
}

@Suite("Playlist manager and settings effects") @MainActor struct PlaylistManagerTests {
    @Test func reportNamesOnlyTheHost() {
        let s = PlaylistSource(name: "Home", type: .xtream, baseURL: "http://provider.example:8080/get.php?username=bob&password=hunter2")
        let text = PlaylistReport.text(source: s, counts: CatalogCounts(channels: 5, movies: 2, series: 1), scopes: [], hasLogin: true)
        #expect(text.contains("provider.example"))
        #expect(!text.contains("hunter2") && !text.contains("bob") && !text.contains("get.php"))
    }

    @Test func tabsOpenTheirFirstItemWhenFoldersAreNotRemembered() {
        let r = AppRouter()
        r.navigate(.movies, .folder("c1"))
        r.navigate(.home); r.navigate(.movies)
        #expect(r.selection == .folder("c1"))
        r.rememberFolders = false
        r.navigate(.home); r.navigate(.movies)
        #expect(r.selection == AppRouter.defaultSelection(for: .movies))
    }

    @Test func refreshPreferencesReachTheScheduler() throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-pm-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        #expect(c.scheduler.catalogInterval == c.settings.catalogRefresh.seconds)
        c.settings.catalogRefresh = .manual
        c.applySettings()
        #expect(c.scheduler.catalogInterval == nil)
        c.settings.catalogRefresh = .every6
        c.applySettings()
        #expect(c.scheduler.catalogInterval == 6.0 * 3600)
    }
}

@Suite("Themes and accents") @MainActor struct ThemeTests {
    @Test func atLeastTwentyThemesEachWithAReadableDistinctPalette() {
        #expect(AppTheme.allCases.count >= 20)
        #expect(Set(AppTheme.allCases.map(\.rawValue)).count == AppTheme.allCases.count)
        #expect(Set(AppTheme.allCases.map { $0.palette.background }).count >= 14, "themes are visibly different, not recolours of one")
        func luminance(_ hex: UInt32) -> Double {
            func c(_ v: UInt32) -> Double { let x = Double(v) / 255; return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            return 0.2126 * c((hex >> 16) & 0xFF) + 0.7152 * c((hex >> 8) & 0xFF) + 0.0722 * c(hex & 0xFF)
        }
        func contrast(_ a: UInt32, _ b: UInt32) -> Double { let (x, y) = (luminance(a), luminance(b)); return (max(x, y) + 0.05) / (min(x, y) + 0.05) }
        for t in AppTheme.allCases {
            let p = t.palette
            #expect(contrast(p.text, p.background) >= 7, "\\(t.rawValue): body text on the page")
            #expect(contrast(p.textSecondary, p.background) >= 4.5, "\\(t.rawValue): secondary text on the page")
            #expect(contrast(p.textSecondary, p.card) >= 3.5, "\\(t.rawValue): secondary text on a card")
            #expect(luminance(p.background) < 0.12, "\\(t.rawValue) is a dark theme")
            #expect(contrast(p.accent, p.background) >= 3, "\\(t.rawValue): the accent is visible on the page")
        }
    }

    @Test func themeAndAccentSurviveARelaunchAndBackup() {
        let d = UserDefaults(suiteName: "theme-\(UUID().uuidString)")!
        let a = AppSettings(defaults: d)
        a.theme = .piano; a.accent = .magenta
        let b = AppSettings(defaults: d)
        #expect(b.theme == .piano && b.accent == .magenta)
        #expect(ThemeStore.current == .piano)
        let snap = a.snapshot()
        let fresh = AppSettings(defaults: UserDefaults(suiteName: "theme-\(UUID().uuidString)")!)
        fresh.apply(snapshot: snap)
        #expect(fresh.theme == .piano && fresh.accent == .magenta)
        d.set("Not A Theme", forKey: "settings.theme")
        #expect(AppSettings(defaults: d).theme == .obsidian, "an unknown stored name falls back to the default")
        ThemeStore.current = .obsidian
    }

    @Test func atLeastTwentyAccents() { #expect(AccentChoice.allCases.count >= 20) }
}
