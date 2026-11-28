import SwiftUI

/// Settings for Automix and the equalizer. Automix is off by default and works on songs stored on this device; nothing is downloaded and
/// nothing leaves the device.
struct MusicAutomixSettingsSection: View {
    let hub: MusicHub
    @State private var confirmClear = false
    @State private var showEqualizer = false

    private var player: MusicPlayer { hub.player }
    private var settings: MusicAutomixSettings { hub.library.settings.player.automix }
    private var automix: MusicAutomixController { player.automix }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicTokens.settingsGroupSpacing) {
            automixGroup
            equalizerGroup
        }
        .onAppear { automix.refreshCacheStats() }
        .confirmationDialog("Clear the analysis cache?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { automix.clearCache() }.atlas("control.music.settingsAutomixClear")
        } message: { Text("Songs are analysed again the next time Automix needs them.") }
    }

    private func update(_ change: (inout MusicAutomixSettings) -> Void) {
        var s = settings
        change(&s)
        player.setAutomix(s)
    }

    // MARK: Automix

    private var automixGroup: some View {
        MusicSettingsGroup(title: "Automix", footer: "Works on songs stored on this device: downloads, local files and the audio cache. Analysis stays on this device.") {
            MusicToggleRow(title: "Automix", info: "Blends one song into the next on the beat, and starts plain crossfades at the real end of a song.",
                           isOn: Binding(get: { settings.enabled }, set: { on in update { $0.enabled = on } }))
            if settings.enabled {
                MusicPickerRow(title: "Style", info: settings.style.detail, selection: Binding(get: { settings.style }, set: { v in update { $0.style = v } }),
                               options: MusicAutomixStyle.allCases.map { ($0, $0.title) })
                if settings.style != .fadeOnly {
                    MusicSliderRow(title: "Strength", info: "A higher strength blends for longer and lets the next song's tempo stretch further to match.",
                                   value: Binding(get: { settings.strength }, set: { v in update { $0.strength = v } }), range: 0...1, step: 0.05,
                                   valueText: Localized.string(Self.strengthLabel(settings.strength)))
                }
                MusicValueRow(title: "Status", value: automix.statusText)
            }
            MusicSettingsRow(title: "Analysis cache") {
                HStack(spacing: Spacing.sm) {
                    Text(verbatim: Localized.string("%d songs, %@", automix.cachedSongs, ByteCountFormatter.string(fromByteCount: automix.cacheBytes, countStyle: .file)))
                        .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                    Button("Clear") { confirmClear = true }.musicButton().disabled(automix.cachedSongs == 0)
                        .accessibilityLabel(Text("Clear the analysis cache")).atlas("control.music.settingsAutomixClearTheAnalysisCache")
                }
            }
        }
    }

    static func strengthLabel(_ s: Double) -> String { s < 0.34 ? "Gentle" : (s < 0.67 ? "Balanced" : "Strong") }

    // MARK: Equalizer

    private var equalizerGroup: some View {
        let eq = player.equalizer
        return MusicSettingsGroup(title: "Equalizer", footer: "Seven bands, a bass and treble pad, sixteen presets and stereo widening. Also in the sliders button in the player bar.") {
            MusicSettingsRow(title: "Equalizer") {
                HStack(spacing: Spacing.sm) {
                    Toggle("Equalizer", isOn: Binding(get: { eq.enabled }, set: { on in var s = player.equalizer; s.enabled = on; try? player.setEqualizer(s) })).toggleStyle(.switch).atlas("control.music.settingsAutomixEqualizer")
                    Button("Open") { showEqualizer = true }.musicButton().accessibilityLabel(Text("Open the equalizer"))
                        .popover(isPresented: $showEqualizer, arrowEdge: .bottom) { MusicEqualizerView(hub: hub) }.atlas("control.music.settingsAutomixOpenTheEqualizer")
                }
            }
            if let p = MusicEqualizerPresets.matching(eq.bands), eq.enabled {
                MusicValueRow(title: "Preset", value: p.title)
            }
        }
    }
}
