import SwiftUI

struct LibrarySettingsPage: View {
    @Bindable var vm: LibrarySettingsViewModel
    @Environment(\.container) private var container
    @Environment(AppSettings.self) private var settings
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @State private var showMaintenance = false

    private func n(_ v: Int) -> String { v.formatted() }
    private func bytes(_ v: Int64) -> String { ByteCountFormatter.string(fromByteCount: v, countStyle: .file) }
    private func date(_ d: Date?) -> String { d.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never" }

    var body: some View {
        @Bindable var s = settings
        SettingsPage {
            SettingsGroup(title: "Manage", footer: "Add, edit or refresh playlists, and organise channels and folders. These open in the main window.") {
                SettingsActions {
                    Button { showManager(.playlists) } label: { Label("Playlists…", systemImage: "list.bullet.rectangle") }
                    Button { showManager(.channelManager) } label: { Label("Channel manager…", systemImage: "slider.horizontal.3") }
                }
            }

            // MARK: catalog
            SettingsGroup(title: "Catalog", footer: "StreamSetu keeps your library on this Mac and opens it instantly. Refreshes run in the background, only while the app is open, and never interrupt what is playing.") {
                SettingsValueRow(title: "Playlists", value: n(vm.overview.playlists))
                SettingsValueRow(title: "Live channels", value: n(vm.overview.channels))
                SettingsValueRow(title: "Movies", value: n(vm.overview.movies))
                SettingsValueRow(title: "Series", value: n(vm.overview.series))
                SettingsValueRow(title: "Folders", value: n(vm.overview.categories))
                SettingsValueRow(title: "Last successful refresh", value: date(vm.overview.lastSync))
                SettingsValueRow(title: "Next scheduled refresh", value: nextRefresh)
                SettingsRow(title: "Refresh automatically", detail: "How often playlists are refreshed. Fresh enough catalogs are skipped.") {
                    Picker("Refresh automatically", selection: $s.catalogRefresh) { ForEach(RefreshInterval.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).fixedSize()
                }
                SettingsRow(title: "Refresh when the app opens", detail: "Playlists more than an hour old are refreshed as the app opens, even when the schedule above is Manual.") {
                    Toggle("", isOn: $s.refreshOnOpen).labelsHidden()
                }
                SettingsValueRow(title: "Current state", value: syncState, tone: state.isSyncing ? .warning : .normal, divider: !state.sources.isEmpty)
                syncList
                SettingsActions {
                    Button { state.syncAll() } label: { HStack(spacing: 6) { if state.isSyncing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }; Text(state.isSyncing ? "Refreshing…" : "Refresh All Playlists") } }
                        .disabled(state.isSyncing || state.sources.isEmpty)
                    if state.isSyncing { Button("Cancel") { for s in state.sources { state.cancelSync(s.id) } } }
                }
                MessageLine(message: vm.syncMessage)
            }

            ArtworkMatchingGroup()

            CloudSyncGroup()

            // MARK: guide
            SettingsGroup(title: "Programme guide", footer: "The guide is downloaded from each playlist's XMLTV address. Programmes up to seven days ahead are kept.") {
                SettingsValueRow(title: "Last successful update", value: date(vm.overview.guideUpdated))
                SettingsValueRow(title: "Programmes stored", value: n(vm.overview.guidePrograms))
                SettingsValueRow(title: "Channels matched to the guide", value: n(vm.overview.guideMatched))
                SettingsValueRow(title: "Channels without guide data", value: n(vm.overview.guideUnmatched), tone: vm.overview.guideUnmatched > 0 && vm.overview.guideMatched == 0 ? .warning : .normal)
                SettingsRow(title: "Refresh guide", detail: "Fresh guides are skipped, so a short interval doesn't download more often than needed.") {
                    Picker("Refresh guide", selection: $s.guideRefresh) { ForEach(RefreshInterval.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).fixedSize()
                }
                SettingsRow(title: "Keep past programmes", detail: "How far back the grid can scroll. Applies from the next guide download.") {
                    Picker("Keep past programmes", selection: $s.guideRetentionDays) {
                        Text("3 hours").tag(0); Text("1 day").tag(1); Text("3 days").tag(3); Text("7 days").tag(7)
                    }.pickerStyle(.menu).fixedSize()
                }
                SettingsActions {
                    Button { for src in state.sources where src.enabled { state.sync(src.id, forceGuide: true) }; vm.guideMessage = .init(text: "Guide refresh started.", kind: .info) } label: { Label("Refresh Guide", systemImage: "calendar") }
                        .disabled(state.isSyncing || state.sources.isEmpty)
                    Button { showChannelManager() } label: { Label("Review EPG Mappings…", systemImage: "link") }
                }
                MessageLine(message: vm.guideMessage)
            }

            // MARK: backup
            SettingsGroup(title: "Backup", footer: "Passwords and full playlist addresses are never exported. A restored playlist comes back switched off and asks for its login.") {
                backupToggle("Playlists (names, types and addresses)", .sources)
                backupToggle("Collections", .collections)
                backupToggle("Favorites", .favorites)
                backupToggle("Preferences", .preferences)
                backupToggle("Viewing history and resume points", .history, divider: false)
                SettingsRow(title: "Back up automatically", detail: "Once a week, StreamSetu saves a backup here and keeps the newest five. It never contains passwords.") {
                    Toggle("Back up automatically", isOn: $s.autoBackup)
                }
                SettingsActions {
                    Button { NSWorkspace.shared.open(StorageService.backups) } label: { Label("Show Backups in Finder", systemImage: "folder") }
                }
                SettingsActions {
                    Button { if let c = container { vm.export(c) } } label: { Label("Export Backup…", systemImage: "square.and.arrow.up") }.disabled(vm.backupOptions.isEmpty)
                    Button { if let c = container { vm.chooseRestore(c) } } label: { Label("Restore Backup…", systemImage: "square.and.arrow.down") }
                }
                MessageLine(message: vm.backupMessage)
            }

            // MARK: maintenance (technical, collapsed until asked for)
            SettingsGroup(title: "Maintenance", footer: "Storage use, database checks and the search index. You rarely need these; they are here for when something looks wrong.") {
                SettingsRow(title: "Show maintenance tools", detail: "Cache sizes, database verification and search index rebuild.", divider: false) {
                    Toggle("Show maintenance tools", isOn: $showMaintenance.animation(AnimationTokens.standard))
                }
            }
            if showMaintenance {
            // MARK: storage
            SettingsGroup(title: "Storage") {
                SettingsValueRow(title: "Library database", value: bytes(vm.storage.database))
                SettingsValueRow(title: "Artwork cache", value: bytes(vm.storage.artworkCache))
                SettingsValueRow(title: "Temporary files", value: bytes(vm.storage.temporary))
                SettingsValueRow(title: "Imported playlist files", value: bytes(vm.storage.playlistFiles))
                SettingsValueRow(title: "Total used by StreamSetu", value: bytes(vm.storage.total), divider: false)
                SettingsActions {
                    AsyncActionButton(title: "Clear Artwork Cache", symbol: "photo", busyTitle: "Clearing…") { if let c = container { await vm.clearArtwork(c) } }
                    AsyncActionButton(title: "Clear Temporary Files", symbol: "trash", busyTitle: "Clearing…") { if let c = container { await vm.clearTemporary(c) } }
                }
                MessageLine(message: vm.storageMessage)
            }

            // MARK: database
            SettingsGroup(title: "Database", footer: "Maintenance waits for any catalog update in progress and never deletes the database file.") {
                SettingsValueRow(title: "Status", value: databaseStatus, tone: vm.integrity.map { $0.ok ? .good : .bad } ?? .normal)
                SettingsValueRow(title: "Schema version", value: vm.index.map { "v\($0.health.schemaVersion)" } ?? "—")
                SettingsValueRow(title: "Last verified", value: date(container?.maintenance.lastIntegrityCheck))
                SettingsValueRow(title: "Last optimized", value: date(container?.maintenance.lastOptimize), divider: false)
                SettingsActions {
                    AsyncActionButton(title: "Verify Database", symbol: "checkmark.shield", busyTitle: "Verifying…") { if let c = container { await vm.verifyDatabase(c) } }
                    AsyncActionButton(title: "Optimize Database", symbol: "wand.and.stars", busyTitle: "Optimizing…") { if let c = container { await vm.optimize(c) } }
                }
                MessageLine(message: vm.databaseMessage)
            }

            // MARK: search index
            SettingsGroup(title: "Search index", footer: "Rebuilding regenerates the index from your catalog. Your channels, movies, series, favorites and history are not touched.") {
                SettingsValueRow(title: "Indexed channels", value: n(vm.index?.channels ?? 0))
                SettingsValueRow(title: "Indexed movies", value: n(vm.index?.movies ?? 0))
                SettingsValueRow(title: "Indexed series", value: n(vm.index?.series ?? 0))
                SettingsValueRow(title: "Total indexed records", value: n(vm.index?.total ?? 0))
                SettingsValueRow(title: "Index health", value: indexHealth, tone: vm.index.map { $0.health.healthy ? .good : .warning } ?? .normal)
                SettingsValueRow(title: "Last verified", value: date(container?.maintenance.lastIndexVerification), divider: vm.rebuildPhase != nil)
                if let p = vm.rebuildPhase {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text(p.label + "…").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary); Spacer() }
                        .padding(.horizontal, 14).padding(.vertical, 8).accessibilityElement(children: .combine)
                }
                SettingsActions {
                    AsyncActionButton(title: "Verify Index", symbol: "checkmark.circle", busyTitle: "Verifying…") { if let c = container { await vm.verifyIndex(c) } }
                    AsyncActionButton(title: "Rebuild Search Index", symbol: "arrow.triangle.2.circlepath", busyTitle: "Rebuilding…") { if let c = container { await vm.rebuildIndex(c) } }
                    Button { if let c = container { vm.clearSearchHistory(c) } } label: { Label("Clear Search History", systemImage: "clock.arrow.circlepath") }
                }
                MessageLine(message: vm.indexMessage)
            }

            }
        }
        .task { if let c = container { await vm.refresh(c) } }
        .task(id: state.catalogVersion) { if let c = container { await vm.refresh(c) } }
        .confirmationDialog("Restore this backup?", isPresented: $vm.confirmRestore, titleVisibility: .visible) {
            Button("Restore") { if let c = container { vm.applyRestore(c, state: state) } }
            Button("Cancel", role: .cancel) { vm.pendingRestore = nil }
        } message: { Text((vm.pendingRestore?.summary ?? []).joined(separator: "\n") + "\n\nNothing is deleted. Items that already exist are left as they are.") }
    }

    // MARK: derived text

    private var nextRefresh: String {
        guard let interval = settings.catalogRefresh.seconds else { return "Manual only" }
        let due = state.sources.filter(\.enabled).map { ($0.lastSync ?? .distantPast).addingTimeInterval(interval) }.min()
        guard let due else { return "—" }
        return due <= Date() ? "Due now (checked every 15 minutes)" : due.formatted(date: .abbreviated, time: .shortened)
    }

    private var syncState: String {
        if state.isSyncing {
            let busy = state.sources.filter { state.syncProgress[$0.id]?.state.isBusy == true }
            return busy.count == 1 ? "Refreshing “\(busy[0].name)”" : "Refreshing \(busy.count) playlists"
        }
        let failed = state.sources.filter { if case .failed = state.syncProgress[$0.id]?.state { true } else { false } }
        return failed.isEmpty ? "Idle" : "\(failed.count) failed in the last refresh"
    }

    @ViewBuilder private var syncList: some View {
        ForEach(state.sources) { src in
            if let p = state.syncProgress[src.id], p.state != .idle {
                HStack(spacing: 8) {
                    StatusDot(color: color(p.state))
                    Text(src.name).font(Typography.caption).lineLimit(1)
                    Spacer()
                    Text(p.state.label).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.vertical, 6).accessibilityElement(children: .combine)
            }
        }
    }

    private func color(_ s: SourceSyncState) -> Color {
        switch s { case .failed: ColorTokens.danger; case .completed: ColorTokens.success; case .idle: ColorTokens.textTertiary; default: ColorTokens.warning }
    }

    private var databaseStatus: String {
        guard let r = vm.integrity else { return vm.index?.health.integrityOK == false ? "Needs attention" : "Not verified this session" }
        return r.ok ? "Verified, no problems" : "Problems found (\(r.problems.count + r.foreignKeyViolations))"
    }

    private var indexHealth: String {
        guard let h = vm.index?.health else { return "—" }
        return h.healthy ? "Healthy" : "Out of step (\(h.searchDocs.formatted()) of \(h.catalogItems.formatted()) records)"
    }

    private func backupToggle(_ title: String, _ option: BackupOptions, divider: Bool = true) -> some View {
        SettingsRow(title: title, divider: divider) {
            Toggle(title, isOn: Binding(get: { vm.backupOptions.contains(option) }, set: { on in if on { vm.backupOptions.insert(option) } else { vm.backupOptions.remove(option) } }))
        }
    }

    private func showChannelManager() { showManager(.channelManager) }

    private func showManager(_ d: Destination) {
        NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true }?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        router.go(d)
    }
}
