import Foundation
import Network

/// Which network addresses count as private, in one place: host names (an addon address, a cover address), raw bytes (a device on the local
/// network) and Network framework endpoints (the loopback proxy's own client).
enum MusicNetworkPolicy {
    /// A host name that is this Mac or a private network: loopback, link-local, private ranges, local-only names and odd numeric spellings.
    static func isPrivateHost(_ rawHost: String) -> Bool {
        var h = rawHost.lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if h.hasSuffix(".") { h.removeLast() }
        if h.isEmpty { return true }
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        for suffix in [".local", ".localdomain", ".lan", ".home", ".home.arpa", ".internal", ".intranet", ".corp"] where h.hasSuffix(suffix) { return true }
        if h.contains(":") { return isPrivateIPv6(h) }
        if !h.contains(".") { return true }                       // a bare name only resolves on a local network
        // Odd numeric spellings of an IPv4 address (decimal or hex) are treated as private rather than decoded.
        if h.hasPrefix("0x") || h.allSatisfy({ $0.isNumber }) { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, let o = parts.map({ Int($0) }) as? [Int], o.allSatisfy({ (0...255).contains($0) }) { return isPrivateIPv4(o) }
        if parts.contains(where: { $0.hasPrefix("0x") }) { return true }
        return false
    }

    private static func isPrivateIPv4(_ o: [Int]) -> Bool {
        switch (o[0], o[1]) {
        case (0, _), (10, _), (127, _): return true
        case (169, 254): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (100, 64...127): return true
        case (192, 0) where o[2] == 0: return true
        default: return o[0] >= 224
        }
    }

    private static func isPrivateIPv6(_ h: String) -> Bool {
        if h == "::" || h == "::1" { return true }
        if h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea") || h.hasPrefix("feb") { return true }
        if h.hasPrefix("::ffff:") {
            let tail = String(h.dropFirst(7))
            let parts = tail.split(separator: ".").compactMap { Int($0) }
            return parts.count == 4 ? isPrivateIPv4(parts) : true
        }
        return false
    }

    /// Raw address bytes (4 for IPv4, 16 for IPv6) that cannot be reached from the internet: private IPv4, loopback, link local, IPv6 unique local.
    static func isPrivateAddress(_ b: [UInt8]) -> Bool {
        if b.count == 4 {
            switch (b[0], b[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        guard b.count == 16 else { return false }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }
        if (b[0] & 0xfe) == 0xfc { return true }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return isPrivateAddress(Array(b[12..<16])) }
        return false
    }

    /// The remote end of a connection is on a private network.
    static func isPrivate(_ endpoint: NWEndpoint?) -> Bool {
        guard case .hostPort(let host, _)? = endpoint else { return false }
        switch host {
        case .ipv4(let a): return isPrivateAddress(Array(a.rawValue))
        case .ipv6(let a): return isPrivateAddress(Array(a.rawValue))
        default: return false
        }
    }

    /// The remote end of a connection is this Mac.
    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback
        default: return false
        }
    }
}
