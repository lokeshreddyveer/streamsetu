#if os(macOS)
import AppKit
import os

/// Writes a line to the system log whenever one turn of the main run loop takes longer than 250 ms (the interface was frozen for that long): how long, and which
/// window and screen was up. Nothing is sent anywhere; read it with `log show --predicate 'subsystem == "app.streamsetu.mac" AND category == "stall"'`.
@MainActor
enum MainStallLog {
    private static var observer: CFRunLoopObserver?
    private static var turnStart: CFAbsoluteTime = 0
    private static let log = Logger(subsystem: "app.streamsetu.mac", category: "stall")
    static let threshold: CFTimeInterval = 0.25

    static func start() {
        guard observer == nil else { return }
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting]
        let obs = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities.rawValue, true, 0) { _, activity in
            if activity == .afterWaiting { turnStart = CFAbsoluteTimeGetCurrent(); return }
            guard turnStart > 0 else { return }
            let took = CFAbsoluteTimeGetCurrent() - turnStart
            turnStart = 0
            if took >= threshold {
                let title = NSApp.keyWindow?.title ?? "no window"
                log.notice("main thread busy \(Int(took * 1000)) ms; window: \(title, privacy: .public)")
            }
        }
        observer = obs
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
    }
}
#endif
