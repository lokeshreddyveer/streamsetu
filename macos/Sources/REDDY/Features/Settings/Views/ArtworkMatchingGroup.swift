import SwiftUI

/// Settings → Library: fills missing posters and summaries from TMDB on its own (the person's own key is optional).
struct ArtworkMatchingGroup: View {
    @Environment(\.container) private var container
    @State private var model: ArtworkSettingsModel?
    @State private var key = ""

    var body: some View {
        SettingsGroup(title: "Artwork and details", footer: ArtworkSettingsModel.optionalNote) {
            if let m = model {
                SettingsRow(title: "Match artwork in the background", atlas: "setting.artworkBackground", detail: ArtworkSettingsModel.switchNote) {
                    Toggle("", isOn: Binding(get: { m.enabled }, set: { m.setEnabled($0) })).labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel("Match artwork in the background")
                }
                SettingsRow(title: "Matching progress", atlas: "setting.artworkBackground", detail: m.progressLine) {
                    HStack(spacing: 8) {
                        if m.isRunning { ProgressView().controlSize(.small) }
                        Button("Match now") { m.matchNow() }.disabled(!m.canMatch || !m.enabled).accessibilityLabel("Match artwork now")
                    }
                }
                SettingsRow(title: "Use mobile data or hotspots", atlas: "setting.artworkBackground", detail: "Off: matching waits for Wi-Fi or a cable.") {
                    Toggle("", isOn: Binding(get: { m.allowCellular }, set: { m.setCellular($0) })).labelsHidden().toggleStyle(.switch).accessibilityLabel("Match artwork on mobile data")
                }
                SettingsRow(title: "TMDB key (optional)", atlas: "setting.tmdbKey", detail: m.sourceLine + ". " + m.keyHint) {
                    HStack(spacing: 8) {
                        SecureField(m.hasOwnKey ? "Replace key" : "Paste key", text: $key).textFieldStyle(.roundedBorder).frame(width: 200).onSubmit(save)
                        Button("Save", action: save).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                        if m.hasOwnKey { Button("Remove", role: .destructive) { m.remove() } }
                    }
                }
                SettingsActions { Button("Test Key") { m.test() }.disabled(!m.canMatch || m.testing).atlas("control.settings.testTmdbKey") }
                SettingsRow(title: "Use TMDB weekly trending", atlas: "control.settings.artworkTrending", detail: "Ranks Top This Week and Trending in Your Library by this week's trending titles. Only the public list is requested.") {
                    Toggle("", isOn: Binding(get: { m.trending }, set: { m.setTrending($0) })).labelsHidden().toggleStyle(.switch).accessibilityLabel("Use TMDB weekly trending")
                }
                if let text = m.message { MessageLine(message: .init(text: text, kind: m.messageFailed ? .failure : .info)) }
                else if m.builtInRejected && m.source == .none { MessageLine(message: .init(text: ArtworkSettingsModel.brokenBuiltIn, kind: .info)) }
            }
            TMDBAttribution()
        }
        .onAppear { if model == nil, let c = container { model = ArtworkSettingsModel(container: c) } else { model?.refresh() } }
        .onDisappear { model?.disappear() }
    }

    private func save() { model?.save(key); key = "" }
}
