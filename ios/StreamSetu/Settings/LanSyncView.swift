import SwiftUI

/// Sync with the person's other devices on the same Wi-Fi.
struct LanSyncView: View {
    @Environment(\.container) private var container
    @Environment(AppSettings.self) private var settings
    @State private var adding = false

    var body: some View {
        @Bindable var s = settings
        let lan = container?.lan
        Form {
            Section {
                Toggle("Sync on this network", isOn: $s.lanSync).onChange(of: s.lanSync) { _, on in container?.lan.setEnabled(on) }
            } footer: {
                Text("Devices on the same Wi-Fi share favourites, Watch Later, collections and resume points directly with each other. No account and no server; nothing leaves your network. Pair each device once.")
            }.listRowBackground(ColorTokens.surface)
            if s.lanSync, let lan {
                Section("Devices") {
                    LabeledContent("Status", value: lan.status)
                    ForEach(lan.trusted, id: \.id) { p in
                        LabeledContent(p.name, value: lan.found.contains { $0.id == p.id } ? "On this network" : "Not here now")
                            .swipeActions { Button("Forget", role: .destructive) { lan.forget(p) } }
                    }
                    Button("Add a Device…") { adding = true }
                    Button("Sync Now") { Task { await lan.syncNow() } }
                }.listRowBackground(ColorTokens.surface)
            }
        }
        .navigationTitle("Sync on this network").themed("Sync on this network")
        .sheet(isPresented: $adding) { if let lan { NavigationStack { LanPairView(service: lan) } } }
    }
}
