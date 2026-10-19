import SwiftUI

/// Movies and episodes saved on this device to watch without a connection.
struct DownloadsView: View {
    @Environment(\.container) private var container
    @State private var confirmRemoveAll = false

    var body: some View {
        List {
            Section { DownloadsList() }.listRowBackground(ColorTokens.surface)
            if let d = container?.downloads {
                Section {
                    Toggle("Only on Wi-Fi", isOn: Binding(get: { d.wifiOnly }, set: { d.wifiOnly = $0 }))
                    if !d.records.isEmpty { Button("Remove All Downloads", role: .destructive) { confirmRemoveAll = true } }
                } footer: {
                    Text("Downloads are kept out of your device backup, pause while something is playing, and carry on from where they stopped.")
                }.listRowBackground(ColorTokens.surface)
            }
        }
        .navigationTitle("Downloads").themed("Downloads")
        .confirmationDialog("Remove every download?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) { container?.downloads.removeAll() }
        } message: { Text("The saved copies are deleted from this device. Your playlists are not changed.") }
    }
}
