import SwiftUI
import AppKit

/// Makes the main window's chrome deterministic. The app draws its own top bar, so the window's title bar must be
/// transparent and must not push content down; the window's own three buttons are hidden and `TrafficLights` draws them in the bar instead, so their
/// size, spacing and position are ours and they line up with the wordmark in every window state. They appear when the pointer is in the top-left corner.
///
/// Without this the bar sits inside the title bar's safe area, whose inset differs between a normal window, a maximised
/// one and fullscreen, so the bar's position depended on the window state. The root shell also ignores the top safe area
/// (see `MainShell`), so nothing is positioned by an offset.
struct WindowChrome: NSViewRepresentable {
    let barHeight: CGFloat

    func makeNSView(context: Context) -> ChromeView { ChromeView(barHeight: barHeight) }
    func updateNSView(_ view: ChromeView, context: Context) { view.barHeight = barHeight; view.apply() }

    @MainActor
    final class ChromeView: NSView {
        var barHeight: CGFloat
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
        nonisolated(unsafe) private var mouseMonitor: Any?
        private var buttonsShown = false

        init(barHeight: CGFloat) { self.barHeight = barHeight; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            guard let w = window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didExitFullScreenNotification, NSWindow.didEnterFullScreenNotification] {
                observers.append(center.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.apply() } })
            }
            w.acceptsMouseMovedEvents = true
            if let m = mouseMonitor { NSEvent.removeMonitor(m) }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseExited]) { [weak self] event in
                MainActor.assumeIsolated { self?.showButtonsIfPointerIsInCorner() }
                return event
            }
            apply()
            DispatchQueue.main.async { [weak self] in self?.apply() }     // AppKit lays the title bar out after the window appears
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
            if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        }

        /// The corner that brings the window buttons back: the width of the three buttons and the height of the bar.
        private func showButtonsIfPointerIsInCorner(animated: Bool = true) {
            guard let w = window else { return }
            let p = w.mouseLocationOutsideOfEventStream
            let top = w.frame.height      // the window's own top edge: the content runs under the title bar, so its layout rect would sit lower
            let inCorner = p.x >= 0 && p.x < 90 && p.y > top - barHeight && p.y <= top
            guard inCorner != buttonsShown else { return }
            buttonsShown = inCorner
            NotificationCenter.default.post(name: .trafficLightsCorner, object: w, userInfo: ["hot": inCorner])
        }

        func apply() {
            guard let w = window else { return }
            // Only write what differs: this runs on resize and focus notifications, and a write that changes nothing must not
            // cause another layout pass.
            if w.titleVisibility != .hidden { w.titleVisibility = .hidden }
            if !w.titlebarAppearsTransparent { w.titlebarAppearsTransparent = true }
            if !w.styleMask.contains(.fullSizeContentView) { w.styleMask.insert(.fullSizeContentView) }
            if w.titlebarSeparatorStyle != .none { w.titlebarSeparatorStyle = .none }
            if w.isMovableByWindowBackground { w.isMovableByWindowBackground = false }     // the bar itself is the drag area (see WindowDragArea)
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                if let b = w.standardWindowButton(type), !b.isHidden { b.isHidden = true }
            }
        }
    }
}

extension Notification.Name { static let trafficLightsCorner = Notification.Name("trafficLightsCorner") }
