import Foundation
import Observation

// Ties the pieces together for the screen: this device's identity, the paired list, the host (off by default), the client and discovery.

@MainActor @Observable
final class MusicDevices {
    private static var cached: MusicDevices?
    static let allowKey = "music.devices.allowControl"

    static func shared(player: any MusicRemoteControllable) -> MusicDevices {
        if let cached { return cached }
        let d = MusicDevices(player: player)
        cached = d
        d.restore()
        return d
    }

    let paired: MusicPairedDevices
    let host: MusicRemoteHost
    let client: MusicRemoteClient
    let discovery: MusicDeviceDiscovery
    let deviceName: String
    /// Off until the person turns it on; the choice is remembered.
    private(set) var allowControl: Bool
    @ObservationIgnored private let defaults: UserDefaults

    init(player: any MusicRemoteControllable, store: any MusicRemoteSecretStore = MusicRemoteKeychain(), defaults: UserDefaults = .standard) {
        let paired = MusicPairedDevices(store: store)
        let name = Self.defaultName()
        self.paired = paired
        self.deviceName = name
        self.defaults = defaults
        self.allowControl = defaults.bool(forKey: Self.allowKey)
        self.host = MusicRemoteHost(deviceID: { paired.ownDeviceID }, deviceName: name, paired: paired, player: player)
        self.client = MusicRemoteClient(deviceID: { paired.ownDeviceID }, deviceName: name, paired: paired)
        self.discovery = MusicDeviceDiscovery(ownDeviceID: { paired.ownDeviceID })
        paired.onRevoked = { [weak self] d in
            guard let self else { return }
            if d.role == .controller { self.host.disconnect(deviceID: d.deviceID) }
            else if self.client.remoteID == d.deviceID { self.client.disconnect() }
        }
    }

    /// Brings the host back up after a launch, only if the person had left the switch on.
    func restore() { if allowControl { host.start() } }

    func setAllowControl(_ on: Bool) {
        allowControl = on
        defaults.set(on, forKey: Self.allowKey)
        if on { host.start() } else { host.stop() }
    }

    private static func defaultName() -> String {
        var n = ProcessInfo.processInfo.hostName
        if n.hasSuffix(".local") { n = String(n.dropLast(6)) }
        n = MusicRemoteSanitizer.text(n)
        return String((n.isEmpty ? "StreamSetu Music" : n).prefix(MusicRemoteLimits.maxName))
    }
}
