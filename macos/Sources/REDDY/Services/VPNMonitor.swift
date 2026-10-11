import Foundation
import Network
import CFNetwork
import Observation

/// What counts as a VPN, and what to do when one drops. Pure, so it is tested without a network.
enum VPNRules {
    static let prefixes = ["tun", "tap", "ppp", "ipsec", "utun", "wg"]

    /// True when any network interface the system lists looks like a VPN tunnel ("utun3", "ppp0", "ipsec0"...).
    static func looksLikeVPN(interfaces: [String]) -> Bool {
        interfaces.contains { name in prefixes.contains { name.lowercased().hasPrefix($0) } }
    }

    /// Playback is paused only when a VPN that was on has gone away, the person asked for that, and a stream is actually playing.
    static func shouldPause(wasOn: Bool, isOn: Bool, enabled: Bool, playing: Bool) -> Bool { wasOn && !isOn && enabled && playing }
}

/// Watches whether a system VPN is connected. The app does not create, configure or see inside the VPN: it only notices it, shows the
/// state, and (if the person asks) pauses playback when the VPN drops so nothing keeps streaming outside it.
@MainActor @Observable
final class VPNMonitor {
    private(set) var isOn = false
    private let monitor = NWPathMonitor()
    /// Called when a VPN that was on goes away.
    var onDrop: () -> Void = {}

    init() {
        isOn = Self.currentlyOn()
        monitor.pathUpdateHandler = { [weak self] _ in
            let now = VPNMonitor.currentlyOn()
            Task { @MainActor in self?.update(now) }
        }
        monitor.start(queue: DispatchQueue(label: "app.streamsetu.vpnmonitor", qos: .utility))
    }

    private func update(_ now: Bool) {
        let was = isOn
        isOn = now
        if was && !now { onDrop() }
    }

    /// The system's own list of network interfaces that carry traffic ("scoped" settings), read through CFNetwork.
    nonisolated static func currentlyOn() -> Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
              let scoped = settings["__SCOPED__"] as? [String: Any] else { return false }
        return VPNRules.looksLikeVPN(interfaces: Array(scoped.keys))
    }
}
