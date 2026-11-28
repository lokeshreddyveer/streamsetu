import Foundation
#if os(macOS)
import AppKit
#endif

/// Music's own accessibility choices, kept on this device. Each one is also reachable from the command palette and the Settings page, and each takes effect at once.
enum MusicAccessibilityPrefs {
    static let simplifiedKey = "music.a11y.simplifiedPlayer"
    static let largeKey = "music.a11y.largeControls"
    static let soundKey = "music.a11y.audioFeedback"
    static let hapticKey = "music.a11y.hapticFeedback"
    static let overlayKey = "music.a11y.strongOverlays"
    static let limitOnKey = "music.a11y.volumeLimitOn"
    static let limitKey = "music.a11y.volumeLimit"
    static let noVisualizerKey = "music.visualizer.disabled"

    static func bool(_ key: String, _ d: UserDefaults = .standard) -> Bool { d.bool(forKey: key) }

    static var simplifiedPlayer: Bool { bool(simplifiedKey) }
    /// Large controls: the person's switch, or a listening mode that wants them (Road trip).
    static var largeControls: Bool { bool(largeKey) || MusicListeningModes.profile.largeControls }
    static var visualizersDisabled: Bool { bool(noVisualizerKey) }
    /// Text over pictures gets a stronger dark layer when asked, or when the system asks for more contrast.
    static func strongOverlays(systemIncreasedContrast: Bool) -> Bool { bool(overlayKey) || systemIncreasedContrast }

    /// The loudest the volume slider may go, 0.3...1. 1 when no limit is set.
    static func volumeCeiling(_ d: UserDefaults = .standard) -> Float {
        guard d.bool(forKey: limitOnKey) else { return 1 }
        let v = d.double(forKey: limitKey)
        return Float(min(1, max(0.3, v == 0 ? 0.8 : v)))
    }

    /// The scale of the transport controls.
    static var controlScale: CGFloat { largeControls ? 1.5 : 1 }
}

/// A quiet sound and a tap on the trackpad when a playback action happens, for people who cannot see the control change. Both are off until chosen.
@MainActor
enum MusicActionFeedback {
    enum Kind { case play, pause, next, previous, like }

    static func fire(_ k: Kind) {
        #if os(macOS)
        if MusicAccessibilityPrefs.bool(MusicAccessibilityPrefs.soundKey) {
            let name: String
            switch k { case .play: name = "Pop"; case .pause: name = "Tink"; case .next: name = "Morse"; case .previous: name = "Bottle"; case .like: name = "Glass" }
            if let s = NSSound(named: NSSound.Name(name)) { s.volume = 0.35; s.play() }
        }
        if MusicAccessibilityPrefs.bool(MusicAccessibilityPrefs.hapticKey) {
            NSHapticFeedbackManager.defaultPerformer.perform(k == .like ? .levelChange : .alignment, performanceTime: .now)
        }
        #endif
    }
}
