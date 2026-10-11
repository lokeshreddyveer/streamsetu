import SwiftUI
import Observation
import AppKit
import UniformTypeIdentifiers

@MainActor @Observable
final class LibrarySettingsViewModel {
    var overview = CatalogOverview()
    var storage = StorageBreakdown()
    var integrity: IntegrityReport?
    var index: IndexStats?
    var rebuildPhase: IndexRebuildPhase?

    var syncMessage: SettingsMessage?
    var guideMessage: SettingsMessage?
    var storageMessage: SettingsMessage?
    var databaseMessage: SettingsMessage?
    var indexMessage: SettingsMessage?
    var backupMessage: SettingsMessage?

    var backupOptions: BackupOptions = .standard
    var pendingRestore: RestorePlan?
    var confirmRestore = false

    /// Refreshes every number on the page off the main thread.
    func refresh(_ c: AppContainer) async {
        let catalog = c.catalog, epg = c.epgRepo, maintenance = c.maintenance
        let artwork = StorageService.shared.cacheSize()
        let r = await Task.detached { () -> (CatalogOverview, StorageBreakdown, IndexStats?) in
            (CatalogOverviewService.load(catalog: catalog, epg: epg, sourceID: nil), maintenance.storage(artworkCacheBytes: artwork), try? maintenance.indexStats())
        }.value
        overview = r.0; storage = r.1; index = r.2
        integrity = integrity ?? nil
    }

    // MARK: storage

    func clearArtwork(_ c: AppContainer) async {
        await c.artwork.clear()
        storageMessage = .init(text: "Artwork cache cleared.")
        await refresh(c)
    }

    func clearTemporary(_ c: AppContainer) async {
        let m = c.maintenance
        let r = await Task.detached { m.clearTemporaryFiles() }.value
        storageMessage = .init(text: r.files == 0 ? "No temporary files to clear." : "Cleared \(r.files) temporary file\(r.files == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file))).")
        await refresh(c)
    }

    func optimize(_ c: AppContainer) async {
        let m = c.maintenance
        do {
            let r = try await Task.detached { try m.optimizeDatabase() }.value
            databaseMessage = .init(text: r.summary)
        } catch { databaseMessage = .init(text: "Couldn't optimize the database: \(error.localizedDescription)", kind: .failure) }
        await refresh(c)
    }

    func verifyDatabase(_ c: AppContainer) async {
        let m = c.maintenance
        do {
            let r = try await Task.detached { try m.verifyDatabase() }.value
            integrity = r
            databaseMessage = r.ok ? .init(text: "Database verified: no problems found.")
                : .init(text: "Database problems found: " + (r.problems.first ?? "\(r.foreignKeyViolations) broken references") + ". Export a backup, then remove and re-add the affected playlist.", kind: .failure)
        } catch { databaseMessage = .init(text: "Couldn't verify the database: \(error.localizedDescription)", kind: .failure) }
    }

    // MARK: index

    func verifyIndex(_ c: AppContainer) async {
        let m = c.maintenance
        do {
            let h = try await Task.detached { try m.verifyIndex() }.value
            indexMessage = h.healthy ? .init(text: "Search index verified.") : .init(text: "The search index is out of step with the catalog. Rebuild it (your library is not affected).", kind: .failure)
        } catch { indexMessage = .init(text: "Couldn't verify the index: \(error.localizedDescription)", kind: .failure) }
        await refresh(c)
    }

    func rebuildIndex(_ c: AppContainer) async {
        let m = c.maintenance
        rebuildPhase = .clearing
        do {
            let box = PhaseBox()
            let task = Task { @MainActor in
                while !Task.isCancelled { if let p = box.value { self.rebuildPhase = p }; try? await Task.sleep(nanoseconds: 80_000_000) }
            }
            try await Task.detached { try m.rebuildSearchIndex { box.value = $0 } }.value
            task.cancel()
            indexMessage = .init(text: "Search index rebuilt. The catalog was not changed.")
        } catch { indexMessage = .init(text: "Couldn't rebuild the index: \(error.localizedDescription)", kind: .failure) }
        rebuildPhase = nil
        await refresh(c)
    }

    func clearSearchHistory(_ c: AppContainer) {
        c.search.clearHistory()
        indexMessage = .init(text: "Search history cleared.")
    }

    // MARK: backup

    func export(_ c: AppContainer) {
        do {
            let data = try c.backup.export(backupOptions, settings: c.settings, channelPrefs: c.playback.channelPrefs)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            if WindowManager.saveFile(name: "StreamSetu-backup-\(f.string(from: Date())).json", data: data) {
                backupMessage = .init(text: "Backup saved. It contains no passwords.")
            }
        } catch { backupMessage = .init(text: "Couldn't create the backup: \(error.localizedDescription)", kind: .failure) }
    }

    func chooseRestore(_ c: AppContainer) {
        guard let url = WindowManager.chooseFile(types: ["json"], prompt: "Choose Backup") else { return }
        do {
            let data = try Data(contentsOf: url)
            pendingRestore = try c.backup.plan(from: data)
            confirmRestore = true
        } catch { backupMessage = .init(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, kind: .failure) }
    }

    func applyRestore(_ c: AppContainer, state: AppState) {
        guard let plan = pendingRestore else { return }
        do {
            let r = try c.backup.apply(plan, settings: c.settings, channelPrefs: c.playback.channelPrefs)
            c.parental.reloadLocks()
            backupMessage = .init(text: r.summary + (r.sourcesAdded > 0 ? " Add each restored playlist's login in Playlists to start syncing." : ""))
            state.reload(); state.reloadFavorites(); state.catalogVersion += 1
        } catch { backupMessage = .init(text: "Couldn't restore: \(error.localizedDescription)", kind: .failure) }
        pendingRestore = nil
    }
}

/// Carries the latest rebuild phase from the background thread to the UI.
final class PhaseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var phase: IndexRebuildPhase?
    var value: IndexRebuildPhase? { get { lock.withLock { phase } } set { lock.withLock { phase = newValue } } }
}
