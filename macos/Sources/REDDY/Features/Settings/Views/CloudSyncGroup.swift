import SwiftUI

/// Settings: iCloud sync between this Mac and the person's iPhone and iPad.
struct CloudSyncGroup: View {
    @Environment(\.container) private var container
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        let status = container?.cloud.status
        SettingsGroup(title: "iCloud", footer: "Playlists, favourites, collections, watch history and resume positions, folder organisation and settings follow you to your other devices through your own private iCloud. The channels, movies and series themselves are downloaded separately on each device. Nothing is sent to anyone else.") {
            SettingsRow(title: "Sync with iCloud", detail: "Needs the same Apple ID on every device.") {
                Toggle("Sync with iCloud", isOn: $s.iCloudSync).labelsHidden().toggleStyle(.switch)
                    .onChange(of: s.iCloudSync) { _, _ in Task { await container?.updateCloudSync() } }
            }
            SettingsRow(title: "Sync logins", detail: "Playlist logins and your TMDB key travel in iCloud Keychain, end-to-end encrypted by Apple. Turn this off to enter logins on each device.") {
                Toggle("Sync logins", isOn: $s.syncLogins).labelsHidden().toggleStyle(.switch).disabled(!s.iCloudSync)
                    .onChange(of: s.syncLogins) { _, _ in Task { await container?.updateCloudSync() } }
            }
            if s.iCloudSync, let status {
                SettingsValueRow(title: "Status", value: status.text, tone: { if case .failed = status.state { return .warning }; if case .unavailable = status.state { return .warning }; return .normal }())
                if status.pending > 0 { SettingsValueRow(title: "Waiting to send", value: "\(status.pending)") }
                SettingsActions {
                    Button { Task { await container?.cloud.syncNow() } } label: { Label("Sync Now", systemImage: "arrow.triangle.2.circlepath") }
                    Button(role: .destructive) { Task { s.iCloudSync = false; await container?.cloud.eraseCloudData() } } label: { Text("Erase iCloud Data…") }
                }
            }
        }
    }
}
