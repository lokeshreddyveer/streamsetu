import Foundation
#if os(macOS)
import IOKit.pwr_mgt
#else
import UIKit
#endif

/// When playback should stop the display from sleeping, and when a stream should be reconnected after the Mac wakes.
enum SleepPolicy {
    /// Video that is playing, buffering or reconnecting keeps the screen awake. Paused, stopped or failed video does not.
    static func shouldKeepAwake(state: PlaybackState, hasPlayback: Bool) -> Bool {
        guard hasPlayback else { return false }
        switch state {
        case .playing, .buffering, .recovering, .resolving, .preparing, .seeking: return true
        default: return false
        }
    }

    /// Only a stream that was actually running when the Mac went to sleep is restarted. One that was paused stays paused.
    static func shouldReconnectAfterWake(wasRunningBeforeSleep: Bool, hasPlayback: Bool) -> Bool { wasRunningBeforeSleep && hasPlayback }
}

/// Keeps the screen on while video plays, so the display doesn't dim or sleep under it. Released the moment it is not needed.
@MainActor
final class SleepGuard {
    private(set) var isHolding = false

    #if os(macOS)
    nonisolated(unsafe) private var assertion: IOPMAssertionID = 0

    func update(hold: Bool) {
        if hold, !isHolding {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "StreamSetu is playing video" as CFString, &id)
            if r == kIOReturnSuccess { assertion = id; isHolding = true }
        } else if !hold, isHolding {
            IOPMAssertionRelease(assertion)
            assertion = 0; isHolding = false
        }
    }

    deinit { if assertion != 0 { IOPMAssertionRelease(assertion) } }
    #else
    func update(hold: Bool) {
        guard hold != isHolding else { return }
        UIApplication.shared.isIdleTimerDisabled = hold
        isHolding = hold
    }
    #endif
}
