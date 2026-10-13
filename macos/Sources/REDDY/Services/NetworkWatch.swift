import Foundation
import Network

/// How the device is connected right now.
enum NetworkLink: Equatable, Sendable { case none, wifi, cellular, wired, other }

enum NetworkReaction: Equatable, Sendable {
    case ignore
    /// The connection went away while something was starting or playing: say so and wait.
    case markOffline
    /// The connection came back while the stream was stuck or had failed: start it again.
    case resume
    /// Wi-Fi to mobile data (or back): connections made on the old network are dead, so look again shortly and restart if the stream is stuck.
    case checkAfterSwitch
}

/// What to do when the connection changes during playback. Pure, so it is tested without a network.
enum NetworkRecovery {
    static func reaction(from old: NetworkLink, to new: NetworkLink, state: PlaybackState, hasStream: Bool) -> NetworkReaction {
        guard hasStream, old != new else { return .ignore }
        if new == .none { return state.isBusy || state == .playing ? .markOffline : .ignore }
        if old == .none {
            switch state { case .playing, .paused, .idle, .ended: return .ignore; default: return .resume }
        }
        return .checkAfterSwitch
    }

    /// After a network switch: restart only a stream that is stuck, never one that is playing.
    static func shouldRestartAfterSwitch(state: PlaybackState) -> Bool {
        switch state { case .buffering, .recovering, .resolving, .preparing, .failed: true; default: false }
    }

    /// A failure that looks like a lost connection is not retried while the device is offline: waiting costs nothing, retries are wasted.
    static func waitsForConnection(kind: PlaybackError.Kind, online: Bool) -> Bool {
        !online && [.network, .timeout, .providerUnavailable, .nameLookup].contains(kind)
    }
}

/// Watches the device's connection. Cheap: the system tells it when something changes, and it does nothing in between.
@MainActor final class NetworkWatch {
    private(set) var link: NetworkLink = .other          // assumed online until the system says otherwise
    var isOnline: Bool { link != .none }
    var onChange: (_ old: NetworkLink, _ new: NetworkLink) -> Void = { _, _ in }
    private let monitor = NWPathMonitor()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let next = NetworkWatch.link(of: path)
            Task { @MainActor in self?.apply(next) }
        }
        monitor.start(queue: DispatchQueue(label: "app.streamsetu.networkwatch", qos: .utility))
    }

    private var seenFirst = false

    private func apply(_ next: NetworkLink) {
        // The system's first answer is the starting state, not a change: nothing was disturbed, so nothing should restart.
        if !seenFirst { seenFirst = true; link = next; return }
        let old = link
        guard next != old else { return }
        link = next
        onChange(old, next)
    }

    nonisolated static func link(of path: NWPath) -> NetworkLink {
        guard path.status == .satisfied else { return .none }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .other
    }
}
