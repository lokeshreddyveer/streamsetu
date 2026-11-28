import Foundation
import Network
import Observation

// Finding the person's other devices with Bonjour. Browsing starts only when the person asks to look, and stops when they leave.
// Advertising is done by the host listener itself (MusicRemoteHost) and exists only while "Allow other devices to control this one" is on.

struct MusicPeer: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var endpoint: NWEndpoint
}

@MainActor @Observable
final class MusicDeviceDiscovery {
    private(set) var peers: [MusicPeer] = []
    private(set) var isBrowsing = false
    private(set) var note: String?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private let ownDeviceID: @MainActor () -> String

    init(ownDeviceID: @escaping @MainActor () -> String) { self.ownDeviceID = ownDeviceID }

    func start() {
        guard browser == nil else { return }
        note = nil
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: MusicRemoteLimits.serviceType, domain: nil), using: MusicRemoteNetwork.tcpParameters())
        b.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .failed, .waiting:
                    self.note = "Could not look for devices. Check that Local Network access is allowed for this app in System Settings."
                case .ready: self.note = nil
                default: break
                }
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let mapped = results.compactMap { Self.peer(from: $0) }
            MainActor.assumeIsolated { self?.apply(mapped) }
        }
        browser = b
        isBrowsing = true
        b.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        peers = []
    }

    private nonisolated static func peer(from r: NWBrowser.Result) -> MusicPeer? {
        guard case .service(let name, _, _, _) = r.endpoint else { return nil }
        // A Listen Together room shares the service type; it is shown on its own page, not as a device.
        if case .bonjour(let flags) = r.metadata, flags["room"] == "1" { return nil }
        var id = name
        if case .bonjour(let txt) = r.metadata, let v = txt["id"], !v.isEmpty, v.count <= MusicRemoteLimits.maxName { id = v }
        return MusicPeer(id: id, name: String(MusicRemoteSanitizer.text(name).prefix(MusicRemoteLimits.maxName)), endpoint: r.endpoint)
    }

    private func apply(_ found: [MusicPeer]) {
        let me = ownDeviceID()
        peers = found.filter { $0.id != me }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
