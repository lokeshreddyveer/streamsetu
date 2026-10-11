import Foundation
import Network
import Observation

/// Finds HDHomeRun tuners on the local network through Bonjour (`_hdhomerun._tcp`). Nothing leaves the network; no outside service is asked.
/// The system asks for Local Network permission the first time.
@MainActor @Observable
final class HDHomeRunDiscovery {
    struct Tuner: Identifiable, Hashable, Sendable { let id: String; let name: String; let host: String }

    private(set) var tuners: [Tuner] = []
    private(set) var searching = false
    private var browser: NWBrowser?
    private var connections: [String: NWConnection] = [:]
    private var stopTask: Task<Void, Never>?

    func start(seconds: UInt64 = 10) {
        stop()
        searching = true
        let b = NWBrowser(for: .bonjour(type: "_hdhomerun._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.resolve(results) }
        }
        b.start(queue: .main)
        browser = b
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if !Task.isCancelled { self?.stop() }
        }
    }

    func stop() {
        stopTask?.cancel(); stopTask = nil
        browser?.cancel(); browser = nil
        connections.values.forEach { $0.cancel() }; connections = [:]
        searching = false
    }

    private func resolve(_ results: Set<NWBrowser.Result>) {
        for r in results {
            guard case .service(let name, _, _, _) = r.endpoint, connections[name] == nil, !tuners.contains(where: { $0.id == name }) else { continue }
            let params = NWParameters.tcp
            (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4       // a plain address a person can read
            let conn = NWConnection(to: r.endpoint, using: params)
            connections[name] = conn
            conn.stateUpdateHandler = { [weak self] state in
                guard case .ready = state, let remote = conn.currentPath?.remoteEndpoint, case .hostPort(let host, _) = remote else { return }
                let address = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
                Task { @MainActor in
                    self?.add(Tuner(id: name, name: name, host: address))
                    conn.cancel()
                }
            }
            conn.start(queue: .main)
        }
    }

    private func add(_ t: Tuner) { if !tuners.contains(where: { $0.id == t.id }) { tuners.append(t) } }
}
