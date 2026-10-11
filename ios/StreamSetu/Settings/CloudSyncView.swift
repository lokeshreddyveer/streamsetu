import SwiftUI

/// iCloud sync between this device and the person's other iPhones, iPads and Macs.
struct CloudSyncView: View {
    @Environment(\.container) private var container
    @Environment(AppSettings.self) private var settings
    @State private var confirmErase = false

    var body: some View {
        @Bindable var s = settings
        let status = container?.cloud.status
        Form {
            Section {
                Toggle("Sync with iCloud", isOn: $s.iCloudSync).onChange(of: s.iCloudSync) { _, _ in Task { await container?.updateCloudSync() } }
                Toggle("Sync logins", isOn: $s.syncLogins).disabled(!s.iCloudSync).onChange(of: s.syncLogins) { _, _ in Task { await container?.updateCloudSync() } }
            } footer: {
                Text("Playlists, favourites, collections, watch history and resume positions, folder organisation and settings follow you to your other devices through your own private iCloud. Logins travel in iCloud Keychain, end-to-end encrypted by Apple; turn that off to enter them on each device. The channels, movies and series are downloaded separately on each device. Nothing is sent to anyone else.")
            }.listRowBackground(ColorTokens.surface)
            if s.iCloudSync, let status {
                Section("Status") {
                    LabeledContent("iCloud", value: status.text)
                    if status.pending > 0 { LabeledContent("Waiting to send", value: "\(status.pending)") }
                    Button("Sync Now") { Task { await container?.cloud.syncNow() } }
                }.listRowBackground(ColorTokens.surface)
                Section { Button("Erase iCloud Data…", role: .destructive) { confirmErase = true } } footer: { Text("Removes what StreamSetu stored in your iCloud and turns sync off. Everything on this device stays.") }.listRowBackground(ColorTokens.surface)
            }
        }
        .navigationTitle("iCloud Sync").themed("iCloud Sync")
        .confirmationDialog("Erase StreamSetu data from iCloud?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase and Turn Off", role: .destructive) { Task { s.iCloudSync = false; await container?.cloud.eraseCloudData() } }
        } message: { Text("Other devices keep their own copies. Turning sync on again uploads this device's data afresh.") }
    }
}
