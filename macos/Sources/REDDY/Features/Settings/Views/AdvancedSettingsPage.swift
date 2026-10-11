import SwiftUI

struct AdvancedSettingsPage: View {
    @Bindable var vm: AdvancedSettingsViewModel
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var confirm: Confirmation?
    @State private var legal: LegalPage?
    @State private var confirmRemoveAll = false

    private enum Confirmation: Identifiable {
        case history, allPreferences
        var id: Self { self }
    }

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Diagnostics", footer: "The report names playlists by host only. Passwords, tokens and stream addresses are removed before it is shown.") {
                SettingsActions {
                    AsyncActionButton(title: "Generate Report", symbol: "doc.text.magnifyingglass", busyTitle: "Generating…") { if let c = container { await vm.generate(c) } }
                    Button { vm.copy() } label: { Label("Copy", systemImage: "doc.on.doc") }.disabled(vm.report.isEmpty)
                    Button { vm.save() } label: { Label("Save…", systemImage: "square.and.arrow.down") }.disabled(vm.report.isEmpty)
                    Button { vm.revealLogs() } label: { Label("Reveal Logs", systemImage: "list.bullet.rectangle") }
                }
                if vm.report.isEmpty {
                    Text("Copy and Save become available after you generate a report.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).padding(.horizontal, 14).padding(.bottom, 10)
                } else {
                    ScrollView { Text(vm.report).font(Typography.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                        .frame(height: 220).background(ColorTokens.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 14).padding(.bottom, 10)
                }
                MessageLine(message: vm.reportMessage)
            }

            SettingsGroup(title: "Reset", footer: "Each button does exactly one thing. None of them removes your playlists.") {
                resetRow("Reset appearance", "Accent, density, animation and sidebar.", "Reset") { if let c = container { vm.resetAppearance(c) } }
                resetRow("Reset playback preferences", "Engine, decoding, quality, buffering, audio and subtitles.", "Reset") { if let c = container { vm.resetPlayback(c) } }
                resetRow("Clear viewing history", "Watch history, Recently Watched and resume points. Favorites stay.", "Clear…") { confirm = .history }
                resetRow("Clear search history", "The list of recent searches.", "Clear") { if let c = container { vm.clearSearchHistory(c) } }
                resetRow("Clear artwork cache", "Downloaded posters and logos. They are fetched again when needed.", "Clear") { if let c = container { Task { await vm.clearArtwork(c) } } }
                resetRow("Reset all preferences", "Every setting returns to its default. Library data is not touched.", "Reset…", divider: false) { confirm = .allPreferences }
                MessageLine(message: vm.resetMessage)
            }

            SettingsGroup(title: "Remove everything", footer: "This cannot be undone. Export a backup first if you may want your favorites and collections again. Your provider accounts are not affected, and nothing belonging to other apps is touched.") {
                SettingsRow(title: "Remove all playlists and data", detail: "Deletes everything listed in the confirmation, from this Mac only.", divider: false) {
                    Button("Remove All Sources and Data…", role: .destructive) { confirmRemoveAll = true }
                        .disabled(container?.parental.isRestricting == true)
                }
                if container?.parental.isRestricting == true {
                    Text("Locked by your PIN. Unlock restricted content first (account menu or Settings → General).").font(.callout).foregroundStyle(.secondary)
                }
            }

            aboutGroup
        }
        .task { if let c = container { await vm.loadAbout(c) } }
        .confirmationDialog(confirm == .history ? "Clear viewing history?" : "Reset all preferences?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            if confirm == .history { Button("Clear History and Resume Points", role: .destructive) { if let c = container { vm.clearHistory(c, state: state) } } }
            else { Button("Reset All Preferences", role: .destructive) { if let c = container { vm.resetAllPreferences(c) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirm == .history ? "Removes \(vm.summary.historyEntries) history entries and \(vm.summary.resumePoints) resume points. Favorites and collections stay." : "Every setting returns to its default. Playlists, favorites and history stay.")
        }
        .confirmationDialog("Remove all playlists and data?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove Everything", role: .destructive) { if let c = container { Task { await vm.removeEverything(c, state: state) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This will delete:\n" + vm.summary.removeAllLines.map { "• " + $0 }.joined(separator: "\n")) }
        .sheet(item: $legal) { page in
            VStack(spacing: 0) {
                HStack { Text(page.title).font(Typography.title); Spacer(); Button("Done") { legal = nil }.keyboardShortcut(.cancelAction) }.padding(16)
                LegalView(page: page)
            }.frame(width: 680, height: 560).background(ColorTokens.background)
        }
        .sheet(isPresented: $vm.showLicenses) { LicensesSheet(libraries: vm.about.bundledLibraries) }
    }

    private func resetRow(_ title: String, _ detail: String, _ button: String, divider: Bool = true, action: @escaping () -> Void) -> some View {
        SettingsRow(title: title, detail: detail, divider: divider) { Button(button, action: action) }
    }

    private var aboutGroup: some View {
        SettingsGroup(title: "About") {
            SettingsValueRow(title: "Version", value: "\(vm.about.version) (build \(vm.about.build))")
            SettingsValueRow(title: "Requires", value: vm.about.minimumMacOS)
            SettingsValueRow(title: "This Mac", value: "macOS \(vm.about.macOS) · \(vm.about.architecture)")
            SettingsValueRow(title: "Playback engines", value: installedEngines)
            SettingsValueRow(title: "MPV version", value: vm.about.mpvVersion ?? "Not installed")
            SettingsValueRow(title: "FFmpeg version", value: vm.about.ffmpegVersion ?? "Not installed")
            SettingsValueRow(title: "Database schema", value: "v\(vm.about.schemaVersion)")
            SettingsRow(title: "Updates", detail: "StreamSetu has no built-in updater. Install a new version from a new download.") { EmptyView() }
            SettingsActions {
                Button { WindowManager.revealInFinder(StorageService.applicationSupport) } label: { Label("Show Data Folder", systemImage: "folder") }
                Button { NSWorkspace.shared.open(CrashReports.folder) } label: { Label("Crash Reports (\(CrashReports.list().count))", systemImage: "ladybug") }
                Button { legal = .privacy } label: { Label("Privacy Policy", systemImage: "hand.raised") }
                Button { legal = .terms } label: { Label("Terms of Use", systemImage: "doc.text") }
                Button { vm.showLicenses = true } label: { Label("View Licenses", systemImage: "doc.plaintext") }
            }
        }
    }

    private var installedEngines: String {
        guard let c = container else { return "—" }
        return c.playback.availableEngines.contains(.mpv) ? "AVPlayer, MPV" : "AVPlayer"
    }
}

struct LicensesSheet: View {
    let libraries: [String]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Licenses and notices").font(Typography.title); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(AboutInfo.notices).font(Typography.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if !libraries.isEmpty {
                        Text("Libraries bundled with this build").font(Typography.heading)
                        Text(libraries.joined(separator: "\n")).font(Typography.mono).foregroundStyle(ColorTokens.textSecondary).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20).frame(width: 560, height: 480).background(ColorTokens.background)
    }
}
