import SwiftUI

/// Settings → Artwork and Details: one section for each extra source (fanart.tv, TheTVDB, TVmaze) with its switch, own key, status and test.
struct HubSourcesSection: View {
    @Environment(\.container) private var container
    @State private var model: HubSettingsModel?
    @State private var keys: [HubSource: String] = [:]
    @State private var pin = ""

    var body: some View {
        Group {
            if let m = model {
                ForEach(HubSettingsModel.cards) { c in
                    Section {
                        Toggle(c.title, isOn: Binding(get: { m.enabled[c.source] ?? false }, set: { m.setEnabled(c.source, $0) })).atlas("setting.integrations")
                        Text((m.status[c.source] ?? "").loc).font(.callout.weight(.semibold))
                        if c.keyLabel != nil {
                            SecureField(m.hasKey[c.source] == true ? "Replace key" : "Paste key", text: Binding(get: { keys[c.source] ?? "" }, set: { keys[c.source] = $0 }))
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            if c.source == .tvdb { SecureField(m.hasPin ? "Replace PIN" : "PIN", text: $pin).textInputAutocapitalization(.never).autocorrectionDisabled() }
                            Button("Save Key") { m.saveKey(c.source, keys[c.source] ?? "", pin: pin); keys[c.source] = ""; pin = "" }
                                .disabled((keys[c.source] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                                .atlas("setting.integrations")
                            if m.hasKey[c.source] == true { Button("Remove Key", role: .destructive) { m.removeKey(c.source) }.atlas("setting.integrations") }
                        }
                        Button("Test") { m.test(c.source) }.disabled(m.testing.contains(c.source)).atlas("setting.integrations")
                        if let text = m.message[c.source] { Label(text.loc, systemImage: m.failed[c.source] == true ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundStyle(m.failed[c.source] == true ? .orange : .green).font(.callout) }
                    } header: { Text(c.title) } footer: { Text(c.help.loc) }.glossRow()
                }
            }
        }
        .onAppear { if model == nil, let c = container { let http = c.http; model = HubSettingsModel(store: HubStore(db: c.db), fetch: { try await http.data($0, maxBytes: 2_000_000) }) } else { model?.refresh() } }
    }
}
