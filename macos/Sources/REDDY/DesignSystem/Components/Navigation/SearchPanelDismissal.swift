import SwiftUI
import AppKit

/// Where a click lands relative to the search field and its ideas panel (window coordinates).
enum SearchPanelDismissal {
    /// A click closes the panel unless it is inside the field or the panel itself.
    static func shouldDismiss(click: CGPoint, field: CGRect?, panel: CGRect?) -> Bool {
        if let field, field.contains(click) { return false }
        if let panel, panel.contains(click) { return false }
        return true
    }
}

/// The two views whose frames count as "inside".
final class SearchDismissRegion {
    weak var field: NSView?
    weak var panel: NSView?
    func rect(_ v: NSView?) -> CGRect? { v.map { $0.convert($0.bounds, to: nil) } }
}

/// Records its own view as the field or the panel region.
struct SearchRegionAnchor: NSViewRepresentable {
    let region: SearchDismissRegion
    let isPanel: Bool
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        if isPanel { region.panel = v } else { region.field = v }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        if isPanel { region.panel = v } else { region.field = v }
    }
}

/// While active, a local mouse monitor reports clicks outside the field and panel. The click is passed on untouched, so it
/// still acts on what was clicked. The monitor is removed when inactive or when the view goes away.
struct SearchOutsideClickMonitor: NSViewRepresentable {
    let region: SearchDismissRegion
    let isActive: Bool
    let onOutsideClick: () -> Void

    final class Coordinator { var monitor: Any? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        if let m = context.coordinator.monitor { NSEvent.removeMonitor(m); context.coordinator.monitor = nil }
        guard isActive else { return }
        let region = region, action = onOutsideClick
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak v] event in
            guard let w = v?.window, event.window === w else { return event }
            if SearchPanelDismissal.shouldDismiss(click: event.locationInWindow, field: region.rect(region.field), panel: region.rect(region.panel)) {
                DispatchQueue.main.async { action() }
            }
            return event
        }
    }
    static func dismantleNSView(_ v: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m); coordinator.monitor = nil }
    }
}
