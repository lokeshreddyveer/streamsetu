import SwiftUI

/// Puts a window's whole content behind App Lock. While the app is locked the content cannot be reached by mouse, keyboard or VoiceOver (it is disabled and hidden from accessibility,
/// not only covered), and the lock screen shows instead. Every window of the app uses this, not only the main one.
struct AppLockGate: ViewModifier {
    let lock: AppLock?
    func body(content: Content) -> some View {
        let locked = lock?.isLocked == true
        content
            .disabled(locked)
            .accessibilityHidden(locked)
            .overlay { if let lock, locked { LockScreen(lock: lock) } }
    }
}

extension View {
    func lockedBehind(_ lock: AppLock?) -> some View { modifier(AppLockGate(lock: lock)) }
}
