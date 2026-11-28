import Foundation
#if os(iOS)
import UIKit
#endif

/// The meanings a haptic can have. Screens ask for a meaning, never a raw vibration; on the Mac every call does nothing.
enum MusicHaptic: Sendable, CaseIterable {
    case tick, tap, select, toggleOn, toggleOff, skipNext, skipPrevious, resume, pause, expand, slam

    /// The beats of the pattern as (strength 0...1, delay in milliseconds after the previous beat). The whole pattern stays under 65 ms.
    var beats: [(strength: Double, delayMs: Int)] {
        switch self {
        case .tick: [(0.3, 0)]
        case .tap: [(0.5, 0)]
        case .select: [(0.6, 0)]
        case .toggleOn: [(0.3, 0), (0.8, 30)]
        case .toggleOff: [(0.8, 0), (0.3, 30)]
        case .skipNext: [(0.4, 0), (0.55, 15), (0.8, 15)]
        case .skipPrevious: [(0.8, 0), (0.55, 15), (0.4, 15)]
        case .resume: [(0.3, 0), (0.5, 20), (0.9, 25)]
        case .pause: [(0.9, 0), (0.3, 30)]
        case .expand: [(0.5, 0), (0.7, 25)]
        case .slam: [(1.0, 0), (0.5, 40)]
        }
    }

    var totalMs: Int { beats.reduce(0) { $0 + $1.delayMs } }
}

