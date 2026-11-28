import SwiftUI

/// Settings, Accessibility: choices that make the player easier to see, hear and operate. Each takes effect at once.
struct MusicAccessibilitySettingsGroup: View {
    @AppStorage(MusicAccessibilityPrefs.simplifiedKey) private var simplified = false
    @AppStorage(MusicAccessibilityPrefs.largeKey) private var large = false
    @AppStorage(MusicAccessibilityPrefs.soundKey) private var sound = false
    @AppStorage(MusicAccessibilityPrefs.hapticKey) private var haptic = false
    @AppStorage(MusicAccessibilityPrefs.overlayKey) private var overlays = false
    @AppStorage(MusicAccessibilityPrefs.limitOnKey) private var limitOn = false
    @AppStorage(MusicAccessibilityPrefs.limitKey) private var limit = 0.8
    @AppStorage(MusicAccessibilityPrefs.noVisualizerKey) private var noVisualizer = false

    var body: some View {
        MusicSettingsGroup(title: "Accessibility", footer: "These apply to Music only. VoiceOver, Switch Control and Full Keyboard Access work with every control; the system's Reduce Motion and Increase Contrast settings are followed as well.") {
            MusicToggleRow(title: "Simplified player", atlas: "control.music.settingsA11ySimple", info: "The player bar keeps only the song, previous, play or pause, next and the heart.", isOn: $simplified)
            MusicToggleRow(title: "Large controls", atlas: "control.music.settingsA11yLarge", info: "Bigger playback buttons and a taller player bar. Road trip mode turns this on while it is active.", isOn: $large)
            MusicToggleRow(title: "Sound for playback actions", atlas: "control.music.settingsA11ySound", info: "A quiet sound when you play, pause, skip or like.", isOn: $sound)
            #if os(macOS)
            MusicToggleRow(title: "Trackpad tap for playback actions", atlas: "control.music.settingsA11yHaptic", info: "A light tap on a Force Touch trackpad when you play, pause, skip or like.", isOn: $haptic)
            #endif
            MusicToggleRow(title: "Stronger text over pictures", atlas: "control.music.settingsA11yOverlay", info: "A darker layer behind text that sits on cover art. It is also used when the system's Increase Contrast is on.", isOn: $overlays)
            MusicToggleRow(title: "Never show visualizers", atlas: "control.music.settingsA11yNoVisualizer", info: "Removes the visualizer from menus and keeps it from ever drawing.", isOn: $noVisualizer)
            MusicToggleRow(title: "Limit the volume", atlas: "control.music.settingsA11yLimitOn", info: "The volume slider cannot go above the limit you choose, so a stray key or slider drag stays comfortable.", isOn: $limitOn)
            if limitOn {
                MusicSettingsRow(title: "Loudest allowed", atlas: "control.music.settingsA11yLimit", detail: "\(Int(limit * 100))%", info: nil) {
                    Slider(value: $limit, in: 0.3...1, step: 0.05).frame(width: 160).accessibilityLabel(Localized.string("Loudest allowed volume")).atlas("control.music.settingsA11yLimit")
                }
            }
        }
    }
}

/// A darker layer behind text that sits on a picture, stronger when asked (or when the system asks for more contrast).
struct MusicReadableOverlay: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let strong = MusicAccessibilityPrefs.strongOverlays(systemIncreasedContrast: contrast == .increased)
        content.background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(strong ? 0.85 : 0.45)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
        }
    }
}

extension View {
    /// Keeps text over artwork readable: a gradient behind it that is darker for people who need more contrast.
    func musicReadableOverlay() -> some View { modifier(MusicReadableOverlay()) }
}
