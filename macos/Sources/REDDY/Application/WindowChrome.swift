import SwiftUI
import AppKit

/// Makes the main window's chrome deterministic. The app draws its own top bar, so the window's title bar must be
/// transparent and must not push content down; the three window buttons stay native but are centred inside the bar.
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
            apply()
            DispatchQueue.main.async { [weak self] in self?.apply() }     // AppKit lays the title bar out after the window appears
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        func apply() {
            guard let w = window else { return }
            // Only write what differs: this runs on resize and focus notifications, and a write that changes nothing must not
            // cause another layout pass.
            if w.titleVisibility != .hidden { w.titleVisibility = .hidden }
            if !w.titlebarAppearsTransparent { w.titlebarAppearsTransparent = true }
            if !w.styleMask.contains(.fullSizeContentView) { w.styleMask.insert(.fullSizeContentView) }
            if w.titlebarSeparatorStyle != .none { w.titlebarSeparatorStyle = .none }
            if w.isMovableByWindowBackground { w.isMovableByWindowBackground = false }     // the bar itself is the drag area (see WindowDragArea)
            guard !w.styleMask.contains(.fullScreen) else { return }
            centerTrafficLights(in: w)
        }

        /// Native close / minimise / zoom buttons, vertically centred in the bar rather than hugging the top edge.
        private func centerTrafficLights(in w: NSWindow) {
            guard let close = w.standardWindowButton(.closeButton), let container = close.superview?.superview, let content = w.contentView else { return }
            let height = barHeight
            let target = NSRect(x: container.frame.origin.x, y: content.frame.height - height, width: container.frame.width, height: height)
            if container.frame != target { container.frame = target }
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let b = w.standardWindowButton(type) else { continue }
                let y = ((height - b.frame.height) / 2).rounded()
                if b.frame.origin.y != y { b.setFrameOrigin(NSPoint(x: b.frame.origin.x, y: y)) }
            }
        }
    }
}
