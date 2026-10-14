import Foundation

/// A second way to find a provider's server when this network's own name lookup fails (a router, ISP or filter that blocks or cannot resolve the name).
/// It asks a public encrypted resolver, over HTTPS to its fixed address, so it works even when the local DNS is broken. Used only after a name-lookup
/// failure, never on the normal path. Plain http streams only: with https the certificate would not match an address.
enum SecureDNS {
    private static let resolvers = [
        "https://1.1.1.1/dns-query?name=%@&type=A",
        "https://8.8.8.8/resolve?name=%@&type=A",
    ]

    /// IPv4 addresses from a DNS-over-HTTPS JSON answer, leaving out addresses that mean "blocked".
    static func parse(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let answers = root["Answer"] as? [[String: Any]] else { return [] }
        return answers.compactMap { a -> String? in
            guard (a["type"] as? Int) == 1, let ip = a["data"] as? String, isUsable(ip) else { return nil }
            return ip
        }
    }

    static func isUsable(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return false }
        if p == [0, 0, 0, 0] || p[0] == 127 || p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 169 && p[1] == 254) { return false }
        return true
    }

    static func isIPAddress(_ host: String) -> Bool { host.contains(":") || host.split(separator: ".").allSatisfy { Int($0) != nil } }

    /// The same address with the server's name replaced by `ip`, and the `Host` header the server expects. Nil for https or addresses that are already numbers.
    static func rewrite(_ url: URL, to ip: String) -> (url: URL, hostHeader: String)? {
        guard url.scheme == "http", let host = url.host, !isIPAddress(host), var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let header = url.port.map { "\(host):\($0)" } ?? host
        c.host = ip
        guard let out = c.url else { return nil }
        return (out, header)
    }

    static func resolve(_ host: String, session: URLSession = .shared) async -> String? {
        let encoded = host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? host
        for template in resolvers {
            guard let url = URL(string: String(format: template, encoded)) else { continue }
            var req = URLRequest(url: url, timeoutInterval: 6)
            req.setValue("application/dns-json", forHTTPHeaderField: "Accept")
            if let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200, let ip = parse(data).first { return ip }
        }
        return nil
    }
}
