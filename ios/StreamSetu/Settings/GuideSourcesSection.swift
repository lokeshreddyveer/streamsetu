import SwiftUI

/// Guide sources for iPhone and iPad: health of each guide, add an address with Test, refresh, and the public channel database switch.
struct GuideSourcesSection: View {
    @Environment(\.container) private var container
    @State private var vm = GuideSourcesViewModel()

    /// `previewModel` fills the page without a library (screenshots).
    init(previewModel: GuideSettingsModel? = nil) { let v = GuideSourcesViewModel(); v.model = previewModel; _vm = State(initialValue: v) }

    var body: some View {
        Section {
            ForEach(vm.model?.rows ?? [], id: \.id) { r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Image(systemName: r.freshness.level == .fresh ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(r.freshness.level == .fresh ? Color.green : Color.orange); Text(r.title); Spacer(); if let h = r.host { Text(h).font(.caption).foregroundStyle(.secondary) }; if r.kind == .userXMLTV { Button(role: .destructive) { vm.remove(r.id, container) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Remove guide").atlas("setting.guide.sources") } }
                    Text(LocalizedStringKey(r.summary)).font(.footnote).foregroundStyle(.secondary)
                    ForEach(r.findings.filter { $0.level != .fresh && $0.text != r.summary }, id: \.key) { f in Text(f.text).font(.caption2).foregroundStyle(.secondary) }
                }
                .atlas("setting.guide.freshness")
            }
            Toggle("Fill missing logos, genres and countries", isOn: Binding(get: { vm.model?.enrichmentEnabled ?? true }, set: { vm.setEnrichment($0, container) })).atlas("setting.guide.publicDatabase")
            TextField("Guide name (optional)", text: $vm.name)
            TextField("https://… XMLTV address", text: $vm.address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            HStack {
                Button("Test") { Task { await vm.test(container) } }.disabled(vm.address.isEmpty || vm.testing).atlas("setting.guide.addXMLTV")
                Button("Add") { Task { await vm.add(container) } }.disabled(vm.address.isEmpty).atlas("setting.guide.addXMLTV")
                Spacer()
                Button("Refresh all guides") { Task { await vm.refresh(container) } }.disabled(vm.refreshing).atlas("control.guide.diagnostics")
            }.buttonStyle(.bordered)
            if let m = vm.message { Text(LocalizedStringKey(m)).font(.footnote).foregroundStyle(.secondary) }
            GuideRemindersList()
        } header: { Text("Guide sources") } footer: { Text("Your playlists' own guides are listed with any guide address you add. Credits: channel data from the public iptv-org database.") }
        .glossRow()
        .task { if vm.model == nil { vm.load(container) } }
    }
}
