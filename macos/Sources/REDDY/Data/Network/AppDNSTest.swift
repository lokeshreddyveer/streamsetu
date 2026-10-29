import Foundation

/// The App DNS test: checks the names StreamSetu actually uses (its playlist and guide servers) as well as a neutral one, asking the chosen resolver directly. Only host names are ever
/// sent: logins, paths, query strings, playlist names and titles are cut off before a name reaches this code.
struct AppDNSTestResult: Equatable, Sendable {
    struct Row: Equatable, Sendable, Identifiable { var id: String { label }; var label: String; var host: String; var resolved: Bool; var detail: String }
    var resolverName: String
    var reachable: Bool
    var milliseconds: Int
    var rows: [Row]
    /// Said only when it can be said truthfully (see `run`).
    var comparison: String?

    var headline: String { reachable ? "\(resolverName) is working" : "\(resolverName) is unavailable" }
    var advice: String { reachable ? "" : "The DNS server could not be reached. Try another provider or turn off App DNS." }
}

enum AppDNSTest {
    /// The system's own answer for a host name, or nil when it cannot be resolved.
    static func systemResolves(_ host: String) async -> Bool {
        await Task.detached {
            var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
            var res: UnsafeMutablePointer<addrinfo>?
            defer { if let res { freeaddrinfo(res) } }
            return getaddrinfo(host, nil, &hints, &res) == 0
        }.value
    }

    /// `hosts` are labelled sources of names ("Playlist", "Guide"); each is reduced to a bare host name first.
    static func run(_ config: AppDNSConfiguration, hosts: [(label: String, address: String)], probe: AppDNSProbe = AppDNSProbe(), systemResolves: (String) async -> Bool = AppDNSTest.systemResolves) async -> AppDNSTestResult {
        // The test asks the chosen resolver even while App DNS is still off, so the person can try before switching on.
        var tried = config; tried.enabled = true
        guard let resolver = tried.resolver else {
            return AppDNSTestResult(resolverName: "Custom DNS", reachable: false, milliseconds: 0, rows: [], comparison: nil)
        }
        var names: [(String, String)] = [("Public host name", "example.com")]
        var seen: Set<String> = ["example.com"]
        for h in hosts { if let host = AppDNSProbe.hostOnly(h.address), seen.insert(host).inserted, !AppDNSLocality.isLocalName(host) { names.append((h.label, host)) } }

        var rows: [AppDNSTestResult.Row] = [], total = 0, answered = 0, differs: [String] = [], sameFailure: [String] = []
        for (label, host) in names {
            let line = await probe.lookup(host, via: resolver)
            total += line.milliseconds
            let addresses = line.v4 + line.v6
            // A private answer for a public name is refused (DNS rebinding), whatever the resolver says.
            let usable = addresses.filter { AppDNSLocality.acceptsAnswer(for: host, address: $0, sourceIsLocal: false) }
            let ok = !usable.isEmpty && line.rcode == 0
            if line.error == nil || !addresses.isEmpty { answered += 1 }
            let detail = ok ? "Resolved · \(usable.count) address\(usable.count == 1 ? "" : "es")" : (!addresses.isEmpty ? "Refused: a public name pointed at a private address" : (line.rcode == 3 ? "Not found" : (line.error ?? "No address")))
            rows.append(.init(label: label, host: host, resolved: ok, detail: detail))
            if !config.enabled {                                   // with App DNS on the device lookup would itself go through App DNS, so it is not a fair comparison
                let sys = await systemResolves(host)
                if ok && !sys { differs.append(label) }
                if !ok && !sys { sameFailure.append(label) }
            }
        }
        var comparison: String?
        if config.enabled { comparison = "The comparison with the device's own DNS is shown while App DNS is off." }
        else if !differs.isEmpty { comparison = "The device's DNS could not resolve: \(differs.joined(separator: ", ")). App DNS may fix this playback problem." }
        else if rows.contains(where: { $0.resolved }) && sameFailure.isEmpty { comparison = "Both App DNS and the device's DNS returned an answer. A playback problem is probably not caused by DNS." }
        return AppDNSTestResult(resolverName: resolver.name, reachable: answered > 0, milliseconds: names.isEmpty ? 0 : total / names.count, rows: rows, comparison: comparison)
    }
}
