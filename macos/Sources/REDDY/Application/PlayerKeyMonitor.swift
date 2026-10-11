import AppKit

/// Player keyboard shortcuts. A local key monitor lets plain keys (Space, F, M, arrows) work for playback
/// while never firing when the user is typing in a text field.
@MainActor
final class PlayerKeyMonitor {
    private var monitor: Any?
    var handler: ((NSEvent) -> Bool)?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let handler = self.handler else { return event }
            // typing in a field (field editor is an NSText) always wins
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            // leave Cmd/Ctrl/Option combinations to the menu
            if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return event }
            return MainActor.assumeIsolated { handler(event) } ? nil : event
        }
    }

    func remove() { if let m = monitor { NSEvent.removeMonitor(m); monitor = nil } }
}
