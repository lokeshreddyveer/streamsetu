import Foundation

/// An HTTP or SOCKS5 proxy for the app's own requests (playlists, guides, details, pictures) and for the MPV player.
/// Apple's own player cannot be pointed at a proxy by an app; streams it plays use the system's network settings.
struct ProxyConfig: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case off = "Off", http = "HTTP", socks5 = "SOCKS5" }
    var kind: Kind = .off
    var host = ""
    var port = 0

    var isActive: Bool { kind != .off && !host.trimmingCharacters(in: .whitespaces).isEmpty && (1...65535).contains(port) }

    /// For URLSessionConfiguration.connectionProxyDictionary.
    var connectionDictionary: [AnyHashable: Any]? {
        guard isActive else { return nil }
        let h = host.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .off: return nil
        case .http: return ["HTTPEnable": 1, "HTTPProxy": h, "HTTPPort": port, "HTTPSEnable": 1, "HTTPSProxy": h, "HTTPSPort": port]
        case .socks5: return ["SOCKSEnable": 1, "SOCKSProxy": h, "SOCKSPort": port]
        }
    }

    /// MPV (FFmpeg underneath) only speaks to HTTP proxies.
    var mpvValue: String? { isActive && kind == .http ? "http://\(host.trimmingCharacters(in: .whitespaces)):\(port)" : nil }
}
