import Foundation

/// The app may talk plain HTTP to a provider (most IPTV servers offer nothing else), but it must never do so quietly when a login is about to be saved for it.
enum ProviderSecurity {
    /// True for an address that stays on this device or this network (localhost, .local names, private IPv4 ranges), where plain HTTP does not cross the internet.
    static func isLocalNetwork(host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h == "::1" { return true }
        let p = h.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return false }
        return p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 169 && p[1] == 254)
    }

    /// Whether an address is plain HTTP. An address with no scheme counts as plain HTTP: that is what the app would use for it.
    static func usesPlainHTTP(_ address: String) -> (plain: Bool, host: String?) {
        let t = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return (false, nil) }
        let withScheme = t.contains("://") ? t : "http://" + t
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased() else { return (false, nil) }
        return (scheme == "http", url.host)
    }

    /// Whether an address itself carries a login (user:password@host, or username=/password=/token= in the query).
    static func addressCarriesLogin(_ address: String) -> Bool {
        guard let url = URL(string: address.contains("://") ? address : "http://" + address) else { return false }
        if url.user != nil || url.password != nil { return true }
        let names = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name)
        return names.contains { RedirectPolicy.isSecretParameter($0) }
    }

    /// The warning to show before saving, or nil when nothing needs one: the address is encrypted, stays on the local network, or no login is involved.
    static func plainHTTPWarning(address: String, hasLogin: Bool) -> String? {
        let (plain, host) = usesPlainHTTP(address)
        guard plain, hasLogin || addressCarriesLogin(address) else { return nil }
        if let host, isLocalNetwork(host: host) { return nil }
        return "This address does not use HTTPS, so the login for it will cross the network unencrypted. Anyone on the same Wi-Fi, or between you and the provider, could read it. Most IPTV providers offer nothing else, so you can still save it, but use a password you use nowhere else."
    }
}
