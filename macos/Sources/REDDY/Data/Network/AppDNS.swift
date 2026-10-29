import Foundation
import Network

/// App DNS: StreamSetu looks up server names through an encrypted (DNS-over-HTTPS) resolver the person chose, for StreamSetu's own network traffic only. It is not a VPN, changes no
/// device setting and does not touch other apps. The resolver sees host names and nothing else: no paths, queries, logins or titles.

/// The built-in resolvers. Filtering ones are never chosen for the person: they can block IPTV providers and CDNs.
enum AppDNSProvider: String, CaseIterable, Codable, Sendable {
    case cloudflare = "Cloudflare", google = "Google", quad9 = "Quad9", adguard = "AdGuard", controlD = "Control D", custom = "Custom"

    var summary: String {
        switch self {
        case .cloudflare: "Fast, unfiltered DNS; recommended"
        case .google: "Fast, unfiltered DNS"
        case .quad9: "Blocks known malicious domains"
        case .adguard: "Blocks ads and trackers; may block some IPTV hosts"
        case .controlD: "Unfiltered profile; filtering profiles are set up on controld.com"
        case .custom: "Your own or a third-party DoH resolver"
        }
    }

    /// The DoH address and the IP addresses that reach it without a lookup (so the resolver never has to be found through the DNS that may be blocked).
    var builtIn: (url: URL, bootstrap: [String])? {
        switch self {
        case .cloudflare: (URL(string: "https://cloudflare-dns.com/dns-query")!, ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"])
        case .google: (URL(string: "https://dns.google/dns-query")!, ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"])
        case .quad9: (URL(string: "https://dns.quad9.net/dns-query")!, ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"])
        case .adguard: (URL(string: "https://dns.adguard-dns.com/dns-query")!, ["94.140.14.14", "94.140.15.15", "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff"])
        case .controlD: (URL(string: "https://freedns.controld.com/p0")!, ["76.76.2.0", "76.76.10.0"])
        case .custom: nil
        }
    }
}

/// What the person chose. Off by default; the provider is remembered but inactive until App DNS is on.
struct AppDNSConfiguration: Equatable, Codable, Sendable {
    var enabled = false
    var provider: AppDNSProvider = .cloudflare
    var customName = ""
    var customURL = ""
    /// Optional IP addresses of the custom resolver, one per entry.
    var customBootstrap: [String] = []
    /// Local names (.local, single-label names, local sources) use the device's DNS.
    var localUsesSystem = true

    /// The resolver in use, or nil when App DNS is off or a custom resolver is not valid.
    var resolver: Resolver? {
        guard enabled else { return nil }
        if let b = provider.builtIn { return Resolver(name: provider.rawValue, url: b.url, bootstrap: b.bootstrap) }
        guard case .success(let url) = AppDNSValidator.validate(customURL) else { return nil }
        return Resolver(name: customName.trimmingCharacters(in: .whitespaces).isEmpty ? "Custom DNS" : customName, url: url, bootstrap: customBootstrap.filter { AppDNSValidator.isIPAddress($0) })
    }

    struct Resolver: Equatable, Sendable { var name: String; var url: URL; var bootstrap: [String] }
}

enum AppDNSValidator {
    enum Problem: Error, Equatable, CustomStringConvertible {
        case empty, notHTTPS, hasCredentials, hasFragment, noHost, isAnAddressOfThePlatform
        var description: String {
            switch self {
            case .empty: "Enter the DNS-over-HTTPS address."
            case .notHTTPS: "The address must start with https://."
            case .hasCredentials: "The address cannot contain a user name or password."
            case .hasFragment: "The address cannot contain a # fragment."
            case .noHost: "The address has no server name."
            case .isAnAddressOfThePlatform: "That address is not a resolver."
            }
        }
    }

    static func validate(_ text: String) -> Result<URL, Problem> {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .failure(.empty) }
        guard let url = URL(string: t), let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .failure(.notHTTPS) }
        guard c.scheme?.lowercased() == "https" else { return .failure(.notHTTPS) }
        guard c.user == nil, c.password == nil else { return .failure(.hasCredentials) }
        guard c.fragment == nil else { return .failure(.hasFragment) }
        guard let host = c.host, !host.isEmpty else { return .failure(.noHost) }
        return .success(url)
    }

    static func isIPAddress(_ s: String) -> Bool { IPv4Address(s) != nil || IPv6Address(s) != nil }
}

/// Which names are local and so may use the device's DNS. A name is never local merely because an answer for it was a private address.
enum AppDNSLocality {
    static func isLocalName(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if h.isEmpty { return false }
        if AppDNSValidator.isIPAddress(h.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) { return isPrivateAddress(h) }     // a literal address needs no lookup; a public one is not "local"
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".localhost") || h.hasSuffix(".lan") || h.hasSuffix(".home.arpa") || h.hasSuffix(".internal") { return true }
        return !h.contains(".")                                      // a single-label name such as "nas"
    }

    static func isPrivateAddress(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let v4 = IPv4Address(s) {
            let b = [UInt8](v4.rawValue)
            return b[0] == 10 || b[0] == 127 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254) || b[0] == 0 || (b[0] == 100 && (64...127).contains(b[1]))
        }
        if let v6 = IPv6Address(s) {
            let b = [UInt8](v6.rawValue)
            if b.dropLast().allSatisfy({ $0 == 0 }) && (b.last == 1 || b.last == 0) { return true }     // ::1 and ::
            return (b[0] & 0xFE) == 0xFC || (b[0] == 0xFE && (b[1] & 0xC0) == 0x80)                    // fc00::/7 and fe80::/10
        }
        return false
    }

    /// DNS-rebinding guard: a public name must not resolve to a private address. A local source may.
    static func acceptsAnswer(for host: String, address: String, sourceIsLocal: Bool) -> Bool {
        sourceIsLocal || isLocalName(host) || !isPrivateAddress(address)
    }
}

/// A small DNS message encoder and decoder, enough to ask a DoH resolver for A and AAAA records (RFC 8484, RFC 1035).
enum DNSWire {
    enum RecordType: UInt16 { case a = 1, aaaa = 28 }

    static func query(_ name: String, type: RecordType) -> Data? {
        var d = Data([0, 0, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0])      // id 0 (RFC 8484), recursion desired, one question
        for label in name.split(separator: ".", omittingEmptySubsequences: true) {
            guard let b = label.data(using: .ascii), !b.isEmpty, b.count <= 63 else { return nil }
            d.append(UInt8(b.count)); d.append(b)
        }
        d.append(0); d.append(contentsOf: [UInt8(type.rawValue >> 8), UInt8(type.rawValue & 0xFF), 0, 1])
        return d.count <= 512 ? d : nil
    }

    struct Answer: Equatable { var rcode: Int; var addresses: [String] }

    static func parse(_ data: Data) -> Answer? {
        let b = [UInt8](data)
        guard b.count >= 12 else { return nil }
        let rcode = Int(b[3] & 0x0F), qd = Int(b[4]) << 8 | Int(b[5]), an = Int(b[6]) << 8 | Int(b[7])
        var i = 12
        func skipName() -> Bool {
            while i < b.count {
                let l = Int(b[i])
                if l == 0 { i += 1; return true }
                if l & 0xC0 == 0xC0 { i += 2; return i <= b.count }
                i += 1 + l
            }
            return false
        }
        for _ in 0..<qd { guard skipName(), i + 4 <= b.count else { return nil }; i += 4 }
        var out: [String] = []
        for _ in 0..<an {
            guard skipName(), i + 10 <= b.count else { return nil }
            let type = Int(b[i]) << 8 | Int(b[i + 1]), len = Int(b[i + 8]) << 8 | Int(b[i + 9])
            i += 10
            guard i + len <= b.count else { return nil }
            if type == 1, len == 4, let a = IPv4Address(Data(b[i..<i + 4])) { out.append("\(a)") }
            if type == 28, len == 16, let a = IPv6Address(Data(b[i..<i + 16])) { out.append("\(a)") }
            i += len
        }
        return Answer(rcode: rcode, addresses: out)
    }
}

/// Applies the choice to the process: Apple's default privacy context covers URLSession, Network framework and getaddrinfo lookups the app makes (so AVPlayer's too, as far as it
/// resolves in the app's process). It must run before the first session or player is created. Apple may prefer a resolver the device already requires (Private Relay or a system
/// encrypted DNS profile), so what is promised is that StreamSetu *requests* the chosen resolver.
enum AppDNSController {
    static func apply(_ config: AppDNSConfiguration) {
        let context = NWParameters.PrivacyContext.default
        guard let r = config.resolver else {
            context.requireEncryptedNameResolution(false, fallbackResolver: nil)
            context.flushCache()
            return
        }
        let servers = r.bootstrap.compactMap { ip -> NWEndpoint? in
            if let a = IPv4Address(ip) { return .hostPort(host: .ipv4(a), port: 443) }
            if let a = IPv6Address(ip) { return .hostPort(host: .ipv6(a), port: 443) }
            return nil
        }
        // true: encrypted lookups are required, so when this resolver cannot be reached the lookup fails; it is never quietly sent to the device's DNS.
        context.requireEncryptedNameResolution(true, fallbackResolver: .https(r.url, serverAddresses: servers))
        context.flushCache()
    }

    static func clearCache() { NWParameters.PrivacyContext.default.flushCache() }
}

/// What the screen says about App DNS, from what is known; it never says more than has been verified.
enum AppDNSStatus {
    static func line(_ config: AppDNSConfiguration, mpvInUse: Bool) -> String {
        guard config.enabled else { return "Not active" }
        guard let r = config.resolver else { return "Custom resolver is not valid" }
        return mpvInUse ? "Requested through \(r.name) for library, guide and Apple playback. MPV playback still uses system DNS" : "Requested through \(r.name) for library, guide and playback"
    }

    /// Shown with App DNS on Apple devices: the system can prefer a resolver of its own.
    static let overrideNotice = "A system-wide DNS profile (an app such as Control D or AdGuard) or iCloud Private Relay can take precedence over this setting on iPhone, iPad and Mac. If a CDN is still blocked, check that profile too."

    static let privacyNotice = "When App DNS is on, the DNS provider you choose can see the domain names StreamSetu looks up. It does not receive playlist passwords, stream paths or viewing history in those requests. The provider may still be able to tell which IPTV or CDN service you use from the host name."
}

/// The test: asks the chosen resolver directly (host names only) and times it.
struct AppDNSProbe {
    struct Line: Equatable, Sendable { var host: String; var v4: [String]; var v6: [String]; var rcode: Int?; var error: String?; var milliseconds: Int }

    var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 8; c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// Only a host name is accepted: anything with a path, query, login or port is cut down to its host first.
    static func hostOnly(_ text: String) -> String? {
        if let h = URLComponents(string: text)?.host, !h.isEmpty { return h.lowercased() }
        let bare = text.trimmingCharacters(in: .whitespaces).lowercased()
        return bare.range(of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$"#, options: .regularExpression) != nil ? bare : nil
    }

    /// Reach the resolver at its own IP address (checking its certificate against its name) so the test does not depend on the device's DNS being able to find the resolver. Off in tests, which use `session`.
    var connectByAddress = true

    /// One DoH request and its raw answer: by IP address when the resolver has any, else through the session.
    func fetch(_ url: URL, via resolver: AppDNSConfiguration.Resolver) async throws -> (data: Data, host: String?) {
        if connectByAddress, !resolver.bootstrap.isEmpty, let host = resolver.url.host {
            var path = url.path; if let q = url.query { path += "?" + q }
            var lastError: Error = URLError(.cannotConnectToHost)
            for address in resolver.bootstrap {
                do { return (try await DoHOverAddress.get(host: host, path: path, address: address), host) } catch { lastError = error }
            }
            throw lastError
        }
        var req = URLRequest(url: url); req.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return (data, http.url?.host)
    }

    func lookup(_ host: String, via resolver: AppDNSConfiguration.Resolver) async -> Line {
        let started = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
        var line = Line(host: host, v4: [], v6: [], rcode: nil, error: nil, milliseconds: 0)
        for type in [DNSWire.RecordType.a, .aaaa] {
            guard let q = DNSWire.query(host, type: type) else { line.error = "Not a valid host name"; return line }
            var c = URLComponents(url: resolver.url, resolvingAgainstBaseURL: false)!
            var items = c.queryItems ?? []
            items.append(URLQueryItem(name: "dns", value: q.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")))
            c.queryItems = items
            do {
                let (data, answeredBy) = try await fetch(c.url!, via: resolver)
                guard answeredBy == resolver.url.host else { line.error = "The resolver did not answer correctly"; continue }
                guard let a = DNSWire.parse(data) else { line.error = "The answer could not be read"; continue }
                line.rcode = a.rcode
                if type == .a { line.v4 = a.addresses } else { line.v6 = a.addresses }
            } catch { line.error = "The DNS server could not be reached" }
        }
        line.milliseconds = ms()
        return line
    }
}


/// A plain HTTPS GET to an IP address, with the TLS name set to the resolver's own host name so its certificate is checked as normal. Used by the App DNS test only.
enum DoHOverAddress {
    struct Failure: Error { let reason: String }

    static func get(host: String, path: String, address: String, timeout: TimeInterval = 6) async throws -> Data {
        let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nAccept: application/dns-message\r\nConnection: close\r\nUser-Agent: StreamSetu\r\n\r\n"
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            Exchange(host: host, address: address, request: request, timeout: timeout, cont: cont).start()
        }
    }

    /// One request and its answer; all its state is touched only on its own queue.
    private final class Exchange: @unchecked Sendable {
        let conn: NWConnection, queue = DispatchQueue(label: "app.streamsetu.dns-probe"), request: String, timeout: TimeInterval
        var cont: CheckedContinuation<Data, Error>?, buffer = Data()
        init(host: String, address: String, request: String, timeout: TimeInterval, cont: CheckedContinuation<Data, Error>) {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
            conn = NWConnection(host: NWEndpoint.Host(address), port: 443, using: NWParameters(tls: tls))
            self.request = request; self.timeout = timeout; self.cont = cont
        }
        func start() {
            conn.stateUpdateHandler = { [self] state in
                switch state {
                case .ready: conn.send(content: Data(request.utf8), completion: .contentProcessed { [self] e in if let e { finish(.failure(e)) } else { read() } })
                case .failed(let e): finish(.failure(e))
                case .waiting(let e): finish(.failure(e))               // no route or a refused connection: do not wait for it
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(.failure(Failure(reason: "timed out"))) }
        }
        func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
                if let data { buffer.append(data) }
                if let error { finish(.failure(error)); return }
                if isComplete || DoHOverAddress.complete(buffer) { finish(DoHOverAddress.parse(buffer)); return }
                read()
            }
        }
        func finish(_ r: Result<Data, Error>) {
            queue.async { [self] in
                guard let c = cont else { return }
                cont = nil; conn.cancel(); c.resume(with: r)
            }
        }
    }

    /// Whether the whole response has arrived (headers plus a body of the stated length, or a closing chunk).
    static func complete(_ data: Data) -> Bool {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: data[..<split.lowerBound], as: UTF8.self).lowercased()
        let body = data[split.upperBound...]
        if let r = head.range(of: "content-length:"), let n = Int(head[r.upperBound...].prefix(while: { $0 != "\r" }).trimmingCharacters(in: .whitespaces)) { return body.count >= n }
        if head.contains("transfer-encoding: chunked") { return body.suffix(5) == Data("0\r\n\r\n".utf8) }
        return false
    }

    /// The body of a 200 response (de-chunked), or a failure.
    static func parse(_ data: Data) -> Result<Data, Error> {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return .failure(Failure(reason: "no answer")) }
        let head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
        guard head.hasPrefix("HTTP/1.1 200") || head.hasPrefix("HTTP/1.0 200") else { return .failure(Failure(reason: "status \(head.prefix(12))")) }
        var body = Data(data[split.upperBound...])
        if head.lowercased().contains("transfer-encoding: chunked") {
            var out = Data(), rest = body[...]
            while let eol = rest.range(of: Data("\r\n".utf8)) {
                let size = Int(String(decoding: rest[..<eol.lowerBound], as: UTF8.self).split(separator: ";").first.map(String.init) ?? "", radix: 16) ?? 0
                if size == 0 { break }
                let start = eol.upperBound
                guard rest.count >= start - rest.startIndex + size else { return .failure(Failure(reason: "short answer")) }
                out.append(rest[start..<(start + size)]); rest = rest[(start + size + 2)...]
            }
            body = out
        }
        return .success(body)
    }
}
