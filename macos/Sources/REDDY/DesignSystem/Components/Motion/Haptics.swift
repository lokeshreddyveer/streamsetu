import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The one place that makes the phone tap back. On the Mac it does nothing. (Declarative feedback on a view uses `.sensoryFeedback`.)
@MainActor
enum Haptics {
    /// A light tap: a chip, a shuffle, a small toggle.
    static func tap() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
    /// A firmer tap: a gesture that took effect.
    static func firm() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
    /// The action worked.
    static func success() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}
