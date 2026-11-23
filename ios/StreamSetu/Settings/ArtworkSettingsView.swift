import SwiftUI

/// Fills missing posters and summaries from TMDB on its own; a key of the person's own is optional.
struct ArtworkSettingsView: View {
    @Environment(\.container) private var container
    @State private var model: ArtworkSettingsModel?
    @State private var key = ""

    var body: some View {
        Form {
            if let m = model {
                Section {
                    Toggle("Match artwork in the background", isOn: Binding(get: { m.enabled }, set: { m.setEnabled($0) })).atlas("setting.artworkBackground")
                    Toggle("Use mobile data", isOn: Binding(get: { m.allowCellular }, set: { m.setCellular($0) })).atlas("control.ios.artwork.cellular")
                    HStack { if m.isRunning { ProgressView() }; Text(m.progressLine).font(.callout).foregroundStyle(.secondary).accessibilityLabel(m.progressLine) }
                    Button("Match now") { m.matchNow() }.disabled(!m.canMatch || !m.enabled).atlas("control.ios.artwork.matchNow")
                } footer: { Text(ArtworkSettingsModel.switchNote) }.glossRow()
                Section {
                    Text(m.sourceLine).font(.callout.weight(.semibold))
                    SecureField(m.hasOwnKey ? "Replace key" : "Paste your TMDB API key (optional)", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save Key") { m.save(key); key = "" }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty).atlas("setting.tmdbKey")
                    if m.hasOwnKey { Button("Remove Key", role: .destructive) { m.remove() }.atlas("setting.tmdbKey") }
                    Button("Test Key") { m.test() }.disabled(!m.canMatch || m.testing).atlas("setting.tmdbKey")
                    if let text = m.message { Label(text, systemImage: m.messageFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundStyle(m.messageFailed ? .orange : .green).font(.callout) }
                } header: { Text("API key") } footer: { Text(ArtworkSettingsModel.optionalNote + " " + m.keyHint) }.glossRow()
                Section {
                    Toggle("Use TMDB weekly trending", isOn: Binding(get: { m.trending }, set: { m.setTrending($0) })).atlas("control.ios.artwork.trending")
                } footer: { Text("Ranks Top This Week and Trending in Your Library by this week's trending titles. Only the public list is requested.") }.glossRow()
            }
            HubSourcesSection()
            Section { TMDBAttribution() }.glossRow()
        }
        .navigationTitle("Artwork and Details").atlasScreen("screen.ios.settings.artwork").themed("Artwork and Details")
        .onAppear { if model == nil, let c = container { model = ArtworkSettingsModel(container: c) } else { model?.refresh() } }
        .onDisappear { model?.disappear() }
    }
}
