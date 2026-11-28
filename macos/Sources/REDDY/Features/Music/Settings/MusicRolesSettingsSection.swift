import SwiftUI

/// The four roles a source can play, one compact row each: who answers search and browse, who finds the audio, where lyrics come from and
/// where plays are sent. The audio order is a table under the rows; the lyrics and scrobbling details live in their own places.
struct MusicRolesSettingsSection: View {
    let hub: MusicHub
    /// Jumps to a block on another tab (or this one).
    var open: (MusicSettingsTab, String) -> Void = { _, _ in }

    private var registry: MusicRegistry { hub.registry }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicTokens.settingsGroupSpacing) {
            rolesGroup
            audioOrderGroup
        }
    }

    private var audioIDs: [String] { registry.audioOrder.filter { registry.provider(id: $0) != nil } }

    private func name(_ id: String) -> String { registry.provider(id: id).map { $0.info.name } ?? id }

    private var rolesGroup: some View {
        let metadata = registry.metadata
        let firstAudio = audioIDs.first { registry.isEnabled($0) }
        let lyrics = hub.lyrics.sourceEntries
        let lyricsOn = lyrics.filter { $0.enabled && registry.isEnabled($0.id) }
        let scrobbling = hub.scrobbler.serviceStates().filter(\.enabled)
        return MusicSettingsGroup(title: "Roles", footer: "Each role is answered by one source, or by an ordered list where the first that resolves wins.") {
            MusicSettingsRow(title: "Metadata", detail: "Answers search and browse") {
                if metadata.isEmpty {
                    roleValue("None on", .warning)
                } else {
                    Picker("Metadata", selection: Binding(get: { registry.activeMetadataID ?? metadata[0].id }, set: { registry.setActiveMetadata($0) })) {
                        ForEach(metadata, id: \.id) { Text(verbatim: $0.info.name).tag($0.id) }
                    }
                    .pickerStyle(.menu).labelsHidden().frame(width: MusicSettingsLayout.controlWidth, alignment: .trailing).atlas("control.music.settingsRolesMetadata")
                }
            }
            MusicSettingsRow(title: "Audio", detail: "Ordered list, first that resolves wins") {
                if let firstAudio { roleValue(name(firstAudio), .normal) } else { roleValue("None on", .warning) }
            }
            MusicSettingsRow(title: "Lyrics", detail: "Ordered list, first with lyrics wins") {
                HStack(spacing: Spacing.sm) {
                    if let first = lyricsOn.first { roleValue(MusicLyricsSources.name(first.id), .normal) } else { roleValue("None on", .warning) }
                    Button("Order") { open(.lyrics, "lyrics.options") }.musicButton().accessibilityLabel(Text("Open the lyrics sources")).atlas("control.music.settingsRolesOpenTheLyricsSources")
                }
            }
            MusicSettingsRow(title: "Scrobbling", detail: "Services plays are sent to") {
                HStack(spacing: Spacing.sm) {
                    if scrobbling.isEmpty { roleValue("None on", .normal) } else { roleValue(scrobbling.map(\.name).joined(separator: ", "), .normal) }
                    Button("Manage") { open(.plugins, "plugins.scrobbling") }.musicButton().accessibilityLabel(Text("Open scrobbling")).atlas("control.music.settingsRolesOpenScrobbling")
                }
            }
        }
    }

    private func roleValue(_ text: String, _ tone: SettingsValueRow.Tone) -> some View {
        Text(verbatim: Localized.string(text)).musicScaledText(.caption).lineLimit(2).truncationMode(.middle).multilineTextAlignment(.trailing)
            .frame(maxWidth: MusicSettingsLayout.controlWidth, alignment: .trailing).help(Text(verbatim: Localized.string(text)))
            .foregroundStyle(tone == .warning ? ColorTokens.warning : ColorTokens.textSecondary)
    }

    private var audioOrderGroup: some View {
        let shown = audioIDs
        return MusicSettingsGroup(title: "Audio order", count: MusicSettingsCount.text(shown.filter { registry.isEnabled($0) }.count, of: shown.count),
                                  footer: "The player tries these from the top until one has the song. Drag to reorder.") {
            if shown.isEmpty { MusicNote(text: "No source offers this.") }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element) { i, id in
                    MusicSourceRow(name: name(id), status: registry.isEnabled(id) ? .on : .off,
                                   reorder: MusicReorder(id: id,
                                                         drop: { registry.setAudioOrder(MusicOrderLogic.dropped(shown, dragged: $0, onto: id)) },
                                                         step: { registry.setAudioOrder(MusicOrderLogic.moved(shown, id: id, by: $0)) }),
                                   first: i == 0, hasDetail: false) { EmptyView() }
                }
            }
        }
    }
}
