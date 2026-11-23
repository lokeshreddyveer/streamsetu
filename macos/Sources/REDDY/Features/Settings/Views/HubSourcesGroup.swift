import SwiftUI

/// Settings → Library → Artwork and details, continued: one card for each extra source (fanart.tv, TheTVDB, TVmaze) with its switch, own key, status and test, and the credits.
struct HubSourcesGroup: View {
    @Environment(\.container) private var container
    @State private var model: HubSettingsModel?
    @State private var keys: [HubSource: String] = [:]
    @State private var pin = ""

    var body: some View {
        SettingsGroup(title: "More sources", footer: HubSettingsModel.keepNote) {
            if let m = model {
                ForEach(HubSettingsModel.cards) { c in
                    SettingsRow(title: c.title, atlas: "control.settings.moreSources", detail: c.help) {
                        Toggle("", isOn: Binding(get: { m.enabled[c.source] ?? false }, set: { m.setEnabled(c.source, $0) })).labelsHidden().toggleStyle(.switch)
                            .accessibilityLabel(c.title)
                    }
                    if let label = c.keyLabel {
                        SettingsRow(title: label, atlas: "control.settings.moreSources", detail: m.hasKey[c.source] == true ? "Your key is saved on this device." : nil) {
                            HStack(spacing: 8) {
                                SecureField(m.hasKey[c.source] == true ? "Replace key" : "Paste key", text: Binding(get: { keys[c.source] ?? "" }, set: { keys[c.source] = $0 }))
                                    .textFieldStyle(.roundedBorder).frame(width: 190)
                                if c.source == .tvdb { SecureField(m.hasPin ? "Replace PIN" : "PIN", text: $pin).textFieldStyle(.roundedBorder).frame(width: 90) }
                                Button("Save") { m.saveKey(c.source, keys[c.source] ?? "", pin: pin); keys[c.source] = ""; pin = "" }
                                    .disabled((keys[c.source] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                                if m.hasKey[c.source] == true { Button("Remove", role: .destructive) { m.removeKey(c.source) } }
                            }
                        }
                    }
                    SettingsActions {
                        Text((m.status[c.source] ?? "").loc).font(.callout).foregroundStyle(.secondary)
                        Button("Test") { m.test(c.source) }.disabled(m.testing.contains(c.source)).atlas("control.settings.moreSources")
                        if let text = m.message[c.source] { MessageLine(message: .init(text: text, kind: m.failed[c.source] == true ? .failure : .info)) }
                    }
                }
            }
            ServiceCreditsView()
        }
        .onAppear { if model == nil, let c = container { let http = c.http; model = HubSettingsModel(store: HubStore(db: c.db), fetch: { try await http.data($0, maxBytes: 2_000_000) }) } else { model?.refresh() } }
    }
}
