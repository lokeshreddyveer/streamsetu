import SwiftUI

// Settings for lyrics: where they come from (order and switches, what each is sent in its details), the lyrics display options, the translation
// language and the global timing offset.

enum MusicLyricsSettingsLogic {
    /// Moves one entry; the result lists every id once.
    static func moved(_ ids: [String], from: Int, toOffset: Int) -> [String] {
        guard ids.indices.contains(from) else { return ids }
        var out = ids
        let item = out.remove(at: from)
        let dest = toOffset > from ? toOffset - 1 : toOffset
        out.insert(item, at: min(max(0, dest), out.count))
        return out
    }

    static func switched(_ enabled: [String: Bool], id: String, on: Bool) -> [String: Bool] {
        var e = enabled; e[id] = on; return e
    }

    /// What the person sees under a source: its own privacy note, else what the source is.
    static func note(for id: String, info: MusicProviderInfo?) -> String {
        if let n = info?.privacyNote, !n.isEmpty { return n }
        return Localized.string("Sends the title and artist of the song being played to %@.", MusicLyricsSources.name(id))
    }

    /// Shown under every source that reads a third party's web client without a published agreement; App Review is told the same in the notes.
    static let unofficialNote = "Unofficial: this reads a third party's service that has no published agreement for apps, so it can stop working without notice."

    static let languages: [(code: String, name: String)] = {
        let codes = ["", "en", "es", "fr", "de", "it", "pt", "nl", "sv", "da", "no", "fi", "pl", "cs", "ro", "hu", "el", "tr", "ru", "uk", "ar", "he", "fa", "hi", "bn", "ta", "te", "mr", "gu", "kn", "ml", "pa", "ur", "th", "vi", "id", "ms", "tl", "ja", "ko", "zh-Hans", "zh-Hant"]
        return codes.map { c in
            c.isEmpty ? (c, "Same as the system") : (c, Locale.current.localizedString(forIdentifier: c) ?? c)
        }
    }()
}

struct MusicLyricsSettingsSection: View {
    let hub: MusicHub
    @AppStorage(MusicLyricsPrefs.blurKey) private var blur = true
    private var globalOffset: Binding<Int> {
        Binding(get: { Int(hub.library.settings.lyricsOffsetMs) },
                set: { hub.library.settings.lyricsOffsetMs = MusicLyricsLookup.clampGlobalOffset(Int64($0)) })
    }
    @AppStorage(MusicLyricsPrefs.translationLanguageKey) private var language = ""
    @State private var paxKey = ""
    @State private var paxSaved = false
    private var settings: MusicSettings { hub.library.settings }
    private var entries: [MusicLyricsSources.Entry] { hub.lyrics.sourceEntries }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicTokens.settingsGroupSpacing) {
            sourcesGroup
            displayGroup
        }
        .onAppear { paxKey = MusicLyricsKeychain.read(MusicLyricsKeychain.paxSenixKey) ?? "" }
    }

    private func isOn(_ e: MusicLyricsSources.Entry) -> Bool { e.enabled && hub.registry.isEnabled(e.id) }

    private var sourcesGroup: some View {
        let ids = entries.map(\.id)
        let on = entries.filter(isOn).count
        return MusicSettingsGroup(title: "Lyrics sources", count: MusicSettingsCount.text(on, of: entries.count),
                                  footer: "Looked up in this order. Each source that is on is told the title and artist of what you play. Drag to reorder.") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                    MusicSourceRow(name: MusicLyricsSources.name(e.id), status: isOn(e) ? .on : .off,
                                   isOn: Binding(get: { isOn(e) }, set: { setEnabled(e.id, $0) }),
                                   reorder: MusicReorder(id: e.id, drop: { save(order: MusicOrderLogic.dropped(ids, dragged: $0, onto: e.id)) }, step: { move(e.id, by: $0) }),
                                   first: i == 0) {
                        if let about = MusicLyricsSources.about[e.id], let head = about.first { Text(verbatim: String(head).uppercased() + String(about.dropFirst()) + ".") }
                        Text(verbatim: Localized.string(MusicLyricsSettingsLogic.note(for: e.id, info: hub.registry.provider(id: e.id)?.info)))
                        if MusicLyricsSources.unofficial.contains(e.id) { Text(verbatim: Localized.string(MusicLyricsSettingsLogic.unofficialNote)) }
                    }
                }
            }
            MusicSettingsRow(title: "PaxSenix key", info: "Optional. Some PaxSenix lyrics need a key from its owner. It is kept in the Keychain on this Mac and sent only to PaxSenix.") {
                HStack(spacing: Spacing.sm) {
                    SecureField("Key", text: $paxKey).textFieldStyle(.roundedBorder).frame(width: MusicTokens.settingsControlWidth - MusicTokens.settingsValueWidth - Spacing.sm)
                        .accessibilityLabel(Text("PaxSenix key")).onChange(of: paxKey) { _, _ in paxSaved = false }
                    Button((paxSaved ? "Saved" : "Save").loc) {
                        MusicLyricsKeychain.write(MusicLyricsKeychain.paxSenixKey, paxKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        paxSaved = true
                    }
                    .buttonStyle(.bordered).frame(width: MusicTokens.settingsValueWidth).accessibilityLabel(Text("Save the PaxSenix key")).atlas("control.music.musicSaveThePaxsenixKey")
                }
            }
        }
    }

    private var displayGroup: some View {
        MusicSettingsGroup(title: "Lyrics display") {
            MusicToggleRow(title: "Prefer word-by-word lyrics", info: "Waits a little longer for a lower source that has word timing instead of settling for line timing.",
                           isOn: Binding(get: { settings.preferWordByWord }, set: { v in hub.library.settings.preferWordByWord = v; hub.lyrics.apply(settings: hub.library.settings) }))
            MusicToggleRow(title: "Soft blur and glow on lyrics", isOn: $blur)
            MusicPickerRow(title: "Translate lyrics into", selection: $language, options: MusicLyricsSettingsLogic.languages.map { ($0.code, $0.name) })
            MusicSettingsRow(title: "Lyrics timing", info: "Positive values show lyrics later. A song's own nudge is added to this.") {
                HStack(spacing: Spacing.sm) {
                    Text(verbatim: MusicLyricsMotion.offsetLabel(Int64(globalOffset.wrappedValue))).font(Typography.caption).monospacedDigit().foregroundStyle(ColorTokens.textSecondary)
                    Stepper("Lyrics timing", value: globalOffset, in: -Int(MusicLyricsMotion.offsetRangeMs)...Int(MusicLyricsMotion.offsetRangeMs), step: Int(MusicLyricsMotion.offsetStepMs))
                        .labelsHidden().accessibilityLabel(Text("Global lyrics offset"))
                }
            }
        }
    }

    private func setEnabled(_ id: String, _ on: Bool) {
        hub.registry.setEnabled(on, id: id)
        var s = hub.library.settings
        s.lyricsSourceOrder = entries.map(\.id)
        s.lyricsSourceEnabled = MusicLyricsSettingsLogic.switched(Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.enabled) }), id: id, on: on)
        hub.library.settings = s
        hub.lyrics.apply(settings: s)
    }

    private func move(_ id: String, by d: Int) {
        let ids = entries.map(\.id)
        guard let i = ids.firstIndex(of: id), ids.indices.contains(i + d) else { return }
        save(order: MusicLyricsSettingsLogic.moved(ids, from: i, toOffset: d > 0 ? i + 2 : i - 1))
    }

    private func save(order: [String]) {
        var s = hub.library.settings
        let on = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.enabled) })
        s.lyricsSourceOrder = order
        s.lyricsSourceEnabled = on
        hub.library.settings = s
        hub.lyrics.apply(settings: s)
    }
}
