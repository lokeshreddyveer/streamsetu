import SwiftUI

/// Settings cards for the extras: local music folders and plugin updates. Insert it into the Music settings page.
/// Holds the extras objects so the settings page and the hub share the same ones. `attach(to:)` is called once when the hub attaches.
@MainActor
final class MusicExtras {
    static let shared = MusicExtras()
    let folders = LocalMediaFolders.shared
    private(set) var updates: MusicPluginUpdates?
    private init() {}

    func updates(for hub: MusicHub) -> MusicPluginUpdates {
        if let updates { return updates }
        let u = MusicPluginUpdates(plugins: hub.plugins)
        updates = u
        return u
    }

    /// Only if the person turned the weekly switch on, checks for plugin updates when due.
    func attach(to hub: MusicHub) {
        let u = updates(for: hub)
        Task { await u.checkIfDue() }
    }
}

struct MusicExtrasSettingsSection: View {
    /// Which half of the extras this instance draws: the local folders and library tools (Library & Storage), or the plugin updates (Sources & Plugins).
    enum Part { case library, updates }
    let hub: MusicHub
    let part: Part
    @State private var updates: MusicPluginUpdates
    @State private var folders = LocalMediaFolders.shared
    @State private var tidy: MusicLocalTidySheet.Tab?
    @State private var healthOpen = false
    @State private var toolsOpen = false

    init(hub: MusicHub, part: Part = .library) {
        self.hub = hub
        self.part = part
        _updates = State(initialValue: MusicExtras.shared.updates(for: hub))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicTokens.settingsGroupSpacing) {
            if part == .library { localFolders } else { pluginUpdates }
        }
        .task { await folders.refresh() }
        .sheet(isPresented: $toolsOpen) { MusicConvertSheet(hub: hub) { toolsOpen = false } }
        .sheet(isPresented: $healthOpen) { MusicLibraryHealthSheet(hub: hub) { healthOpen = false } }
        .sheet(item: Binding(get: { tidy.map { TidyTab(tab: $0) } }, set: { if $0 == nil { tidy = nil } })) { t in MusicLocalTidySheet(hub: hub, tab: t.tab, close: { tidy = nil }) }
        .sheet(item: Binding(get: { updates.review }, set: { if $0 == nil { updates.decline() } })) { r in reviewSheet(r) }
    }

    // MARK: local folders

    private var localFolders: some View {
        MusicSettingsGroup(title: "Local folders", count: folders.folders.isEmpty ? nil : Localized.string("%d folders", folders.folders.count),
                           footer: "Only folders you add are read, and nothing is uploaded. Turn on Local files in Music sources to search them.") {
            if folders.folders.isEmpty { MusicNote(text: "No folders added.") }
            ForEach(Array(folders.folders.enumerated()), id: \.element.id) { i, f in
                MusicSourceRow(name: f.name, status: .note(Localized.string("%d tracks", f.trackCount)), first: i == 0) {
                    Text(verbatim: f.path).textSelection(.enabled)
                    HStack(spacing: Spacing.sm) {
                        Button("Rescan") { folders.rescan(folderID: f.id) }.disabled(folders.isScanning).atlas("control.music.settingsExtrasRescan")
                        Button("Remove", role: .destructive) { folders.remove(f.id) }.musicButton(.destructive, size: .compact).atlas("control.music.settingsExtrasRemove")
                    }
                    .musicButton(.secondary, size: .compact)
                }
            }
            MusicSettingsActions {
                #if os(macOS)
                Button("Add folder…") { folders.chooseAndAdd() }.accessibilityLabel(Text("Add a music folder")).atlas("control.music.settingsExtrasAddAMusicFolder")
                #endif
                if folders.isScanning {
                    Button("Stop scan") { folders.cancelScan() }.atlas("control.music.settingsExtrasStopScan")
                } else if !folders.folders.isEmpty {
                    Button("Rescan all") { folders.rescan() }.atlas("control.music.settingsExtrasRescanAll")
                    Button("Thorough rescan") { folders.thoroughRescan() }.disabled(folders.isScanning)
                        .help("Forget which folders were unchanged and list every folder again.")
                        .accessibilityLabel(Text("Thorough rescan of all folders")).atlas("control.music.settingsExtrasThoroughRescanOfAllFolders")
                }
            }
            #if os(macOS)
            MusicToggleRow(title: "Watch folders for changes", atlas: "control.music.settingsWatchFolders",
                           info: "When files in these folders are added, moved or removed, the library updates by itself a few seconds later.",
                           isOn: Binding(get: { folders.watches }, set: { folders.watches = $0 }))
            #endif
            #if os(macOS)
            MusicAcoustIDSettingsRows()
            MusicSonicSettingsRows(hub: hub)
            #endif
            MusicSettingsActions {
                if !folders.folders.isEmpty {
                    Button("Find repeated songs…") { tidy = .duplicates }.atlas("control.music.settingsTidyDuplicates")
                    Button("Check for missing files…") { tidy = .missing }.atlas("control.music.settingsTidyMissing")
                }
                Button("Listening mode…") { MusicChromeState.shared.modesOpen = true }.atlas("control.music.settingsListeningMode")
                Button("Automation…") { MusicChromeState.shared.automationOpen = true }.atlas("control.music.settingsAutomation")
                Button("Audio tools…") { toolsOpen = true }.atlas("control.music.settingsAudioTools")
                Button("Library health…") { healthOpen = true }.atlas("control.music.settingsLibraryHealth")
            }
            if folders.isScanning, let p = folders.progress { MusicNote(text: Localized.string("Reading %d of %d", p.read, p.total)) }
            if let n = folders.note { MusicNote(text: n, tone: .bad) }
        }
    }

    // MARK: updates

    private var pluginUpdates: some View {
        MusicSettingsGroup(title: "Plugin updates", footer: "Updates are never installed on their own. You see what changed and any new permissions, then decide.") {
            MusicToggleRow(title: "Check once a week", info: "Off by default. Contacts the plugin authors' update pages about once a week while Music is open.",
                           isOn: Binding(get: { updates.weeklyCheck }, set: { updates.weeklyCheck = $0 }))
            MusicSettingsRow(title: "Check now", detail: updates.lastCheck.map { Localized.string("Last checked %@", $0.formatted(date: .abbreviated, time: .shortened)) }) {
                Button((updates.isChecking ? "Checking…" : "Check for updates").loc) { Task { await updates.check() } }
                    .musicButton().disabled(updates.isChecking).accessibilityLabel(Text("Check plugins for updates")).atlas("control.music.settingsExtrasCheckPluginsForUpdates")
            }
            ForEach(updates.offers) { o in
                MusicButtonRow(title: o.name, button: "Review update") { Task { await updates.beginUpdate(o) } }
            }
            if let s = updates.status { MusicNote(text: s) }
        }
    }

    private func reviewSheet(_ r: MusicPluginUpdateReview) -> some View {
        let d = r.diff
        return VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Update this plugin?").font(Typography.title)
            Text(verbatim: "\(r.name): \(d.oldVersion) to \(d.newVersion)").font(Typography.bodyMedium)
            if d.widensAccess {
                Label("This version asks for more than the one you have.", systemImage: "exclamationmark.triangle.fill").font(Typography.body).foregroundStyle(ColorTokens.danger)
                ForEach(d.addedHosts, id: \.self) { Label(Localized.string("New network address: %@", $0), systemImage: "plus.circle.fill").font(Typography.body).foregroundStyle(ColorTokens.danger) }
                ForEach(d.addedPermissions, id: \.self) { Label(Localized.string("New permission: %@", $0), systemImage: "plus.circle.fill").font(Typography.body).foregroundStyle(ColorTokens.danger) }
                ForEach(d.addedCapabilities, id: \.self) { Label(Localized.string("New ability: %@", $0), systemImage: "plus.circle.fill").font(Typography.body).foregroundStyle(ColorTokens.danger) }
            } else {
                Text("No new permissions.").font(Typography.body).foregroundStyle(ColorTokens.textSecondary)
            }
            ForEach(d.removedHosts + d.removedPermissions + d.removedCapabilities, id: \.self) {
                Label(Localized.string("No longer asks for: %@", $0), systemImage: "minus.circle").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { updates.decline() }.musicButton().keyboardShortcut(.cancelAction).atlas("control.music.settingsExtrasCancel")
                Button("Update") { updates.confirm() }.musicButton(.primary).keyboardShortcut(.defaultAction).atlas("control.music.settingsExtrasUpdate")
            }
        }
        .padding(Spacing.xl).frame(minWidth: MusicTokens.sheetWidth)
    }
}

/// Lets a sheet be shown for one of the two tidy tabs.
private struct TidyTab: Identifiable { let tab: MusicLocalTidySheet.Tab; var id: Int { tab == .duplicates ? 0 : 1 } }
