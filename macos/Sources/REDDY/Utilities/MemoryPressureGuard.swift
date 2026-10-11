import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Frees what can be rebuilt (pictures held in memory) when the system says it is short of memory, so the app is not the one that
/// gets stopped. It never touches playback: a playing stream keeps its own buffers and keeps playing.
final class MemoryPressureGuard: @unchecked Sendable {
    private var source: DispatchSourceMemoryPressure?
    private var observer: NSObjectProtocol?
    private let relieve: @Sendable () async -> Void

    init(relieve: @escaping @Sendable () async -> Void) {
        self.relieve = relieve
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        s.setEventHandler { [relieve] in Task(priority: .utility) { await relieve() } }
        s.resume()
        source = s
        #if canImport(UIKit)
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [relieve] _ in
            Task(priority: .utility) { await relieve() }
        }
        #endif
    }

    deinit { source?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
}
