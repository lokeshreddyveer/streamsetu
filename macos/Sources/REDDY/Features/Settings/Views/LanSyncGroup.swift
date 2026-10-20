import SwiftUI

/// Settings: keep favourites, Watch Later, collections and resume points in step with the person's other devices on the same Wi-Fi.
struct LanSyncGroup: View {
    @Environment(\.container) private var container
    @Environment(AppSettings.self) private var settings
    @State private var adding = false

    var body: some View {
        @Bindable var s = settings
        let lan = container?.lan
        SettingsGroup(title: "Sync on this network", footer: "Devices on the same Wi-Fi share favourites, Watch Later, collections and resume points directly with each other. No account and no server; nothing leaves your network. Pair each device once.") {
            SettingsRow(title: "Sync on this network", detail: "Works between Mac, iPhone, iPad, Android phones and Fire TV.") {
                Toggle("Sync on this network", isOn: $s.lanSync).labelsHidden()
                    .onChange(of: s.lanSync) { _, on in container?.lan.setEnabled(on) }
            }
            if s.lanSync, let lan {
                SettingsValueRow(title: "Status", value: lan.status)
                ForEach(lan.trusted, id: \.id) { p in
                    SettingsValueRow(title: p.name, value: lan.found.contains { $0.id == p.id } ? "On this network" : "Not here now")
                }
                SettingsActions {
                    Button { adding = true } label: { Label("Add a Device…", systemImage: "plus") }
                    Button { Task { await lan.syncNow() } } label: { Label("Sync Now", systemImage: "arrow.triangle.2.circlepath") }
                    if !lan.trusted.isEmpty {
                        Menu("Forget a Device") { ForEach(lan.trusted, id: \.id) { p in Button(p.name, role: .destructive) { lan.forget(p) } } }
                    }
                }
            }
        }
        .sheet(isPresented: $adding) { if let lan { LanPairView(service: lan) } }
    }
}
