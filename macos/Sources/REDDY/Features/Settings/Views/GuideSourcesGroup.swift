import SwiftUI

/// Settings > Library > Guide sources: every guide the app reads, with its health, an address field with Test, refresh now, and the public channel database.
struct GuideSourcesGroup: View {
    @Environment(\.container) private var container
    @State private var vm = GuideSourcesViewModel()

    /// `previewModel` fills the page without a library (snapshots and previews).
    init(previewModel: GuideSettingsModel? = nil) { let v = GuideSourcesViewModel(); v.model = previewModel; _vm = State(initialValue: v) }

    var body: some View {
        SettingsGroup(title: "Guide sources", footer: "Your playlists' own guides are listed with any guide address you add. A channel without a guide of its own can use an added one. Credits: channel data from the public iptv-org database.") {
            if let rows = vm.model?.rows {
                ForEach(rows, id: \.id) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: r.freshness.level == .fresh ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(r.freshness.level == .fresh ? ColorTokens.success : ColorTokens.warning)
                            Text(r.title).font(.headline); if let h = r.host { Text(h).foregroundStyle(.secondary) }
                            Spacer()
                            if r.kind == .userXMLTV { Button(role: .destructive) { vm.remove(r.id, container) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Remove guide").atlas("setting.guide.sources") }
                            if r.kind != .provider { Toggle("", isOn: Binding(get: { r.enabled }, set: { vm.setEnabled(r.id, $0, container) })).labelsHidden().atlas("setting.guide.sources") }
                        }
                        Text(LocalizedStringKey(r.summary)).font(.callout).foregroundStyle(.secondary)
                        ForEach(r.findings.filter { $0.level != .fresh && $0.text != r.summary }, id: \.key) { f in Text(f.text).font(.caption).foregroundStyle(f.level == .error ? ColorTokens.warning : Color.secondary) }
                    }.padding(.vertical, 4).atlas("setting.guide.freshness")
                }
            }
            SettingsRow(title: "Fill missing logos, genres and countries", atlas: "setting.guide.publicDatabase", detail: "Uses the public iptv-org channel list, downloaded once a day. Nothing from your library is sent. Locked, hidden, adult and kids channels are never touched.") {
                Toggle("", isOn: Binding(get: { vm.model?.enrichmentEnabled ?? true }, set: { vm.setEnrichment($0, container) })).labelsHidden()
            }
            HStack {
                TextField("Guide name (optional)", text: $vm.name).frame(maxWidth: 180)
                TextField("https://… XMLTV address", text: $vm.address).textContentType(.URL)
                Button("Test") { Task { await vm.test(container) } }.disabled(vm.address.isEmpty || vm.testing).atlas("setting.guide.addXMLTV")
                Button("Add") { Task { await vm.add(container) } }.disabled(vm.address.isEmpty).atlas("setting.guide.addXMLTV")
            }
            SettingsActions {
                Button { Task { await vm.refresh(container) } } label: { Label("Refresh all guides", systemImage: "arrow.clockwise") }.disabled(vm.refreshing).atlas("control.guide.diagnostics")
            }
            if let m = vm.message { Text(LocalizedStringKey(m)).font(.callout).foregroundStyle(.secondary) }
            GuideRemindersList()
        }
        .task { if vm.model == nil { vm.load(container) } }
    }
}
