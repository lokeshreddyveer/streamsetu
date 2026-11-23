import Foundation
import Network

/// Any network that is online (Low Data Mode is ignored); mobile data and hotspots count unless the person switched "Use mobile data" off. Watches the system's own path updates; does nothing in between.
final class PathMatchNetwork: MatchNetwork, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?
    init() {
        monitor.pathUpdateHandler = { [weak self] p in self?.lock.withLock { self?.path = p } }
        monitor.start(queue: DispatchQueue(label: "app.streamsetu.artworkpath", qos: .utility))
    }
    deinit { monitor.cancel() }
    /// False only when the system says there is no usable path at all.
    var isOnline: Bool { lock.withLock { path }?.status != .unsatisfied }
    func isUsable(allowCellular: Bool) -> Bool {
        guard let p = lock.withLock({ path }) else { return true }          // before the first answer: assume usable
        return Self.decide(satisfied: p.status == .satisfied, metered: p.isExpensive || p.usesInterfaceType(.cellular), allowCellular: allowCellular)
    }

    /// Offline never; mobile data or a hotspot only when the person allows it (it is allowed unless they turn it off).
    static func decide(satisfied: Bool, metered: Bool, allowCellular: Bool) -> Bool {
        satisfied && (allowCellular || !metered)
    }
}
