import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The tactile half of a click. On a Force Touch trackpad a press gives one light, short tap (the system's own "alignment" haptic, the one drag guides use); on a mouse
/// or an older trackpad it does nothing. It is limited to one tap per 70 ms so a fast sweep over a row of buttons never buzzes, and it is silent under Reduce Motion.
@MainActor
enum PremiumFeedback {
    private static var last = Date.distantPast

    static func tick() {
        #if os(macOS)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, !UserDefaults.standard.bool(forKey: DefaultsKey.reduceMotion) else { return }
        let now = Date()
        guard now.timeIntervalSince(last) > 0.07 else { return }
        last = now
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #endif
    }
}
