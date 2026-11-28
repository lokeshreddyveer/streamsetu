import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A popover is a window of its own. When it closes, AppKit gives the keyboard back to the first text field of the main window, which is the app's Search box,
/// so the next key typed (or the focus ring alone) opens the app-wide search. This hands the keyboard back to the page instead: once the popover is gone the main window's
/// first responder is cleared, twice (right away and after the window has become key again), so it never lands in a field the person did not choose.
enum MusicFocusGuard {
    /// Clears keyboard focus on the main window, so the Search box (the first text field) is not given it.
    @MainActor static func releaseToPage() {
        #if os(macOS)
        func clear() {
            guard let w = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain }) else { return }
            w.makeFirstResponder(nil)
        }
        DispatchQueue.main.async { clear() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { clear() }
        #endif
    }
}

private struct MusicFocusGuardModifier: ViewModifier {
    @Binding var isPresented: Bool
    func body(content: Content) -> some View {
        content.onChange(of: isPresented) { was, now in
            if was && !now { MusicDebugLog.log("focus", "popover closed, keyboard handed back to the page"); MusicFocusGuard.releaseToPage() }
        }
    }
}

extension View {
    /// Put on a view that owns a `.popover(isPresented:)`: when the popover closes the keyboard goes back to the page, not to the app's Search box.
    func musicFocusGuard(isPresented: Binding<Bool>) -> some View { modifier(MusicFocusGuardModifier(isPresented: isPresented)) }
}
