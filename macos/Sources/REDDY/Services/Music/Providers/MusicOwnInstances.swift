import Foundation

/// What the person said about a Piped or Invidious server they run themselves: up to two API addresses per kind, and whether they confirmed
/// that a private-network address is their own server. The addresses are a device setting; they are never synced, backed up or exported.
struct MusicOwnInstances: Equatable, Sendable {
    static let pipedKey = "music.ownInstances.piped"
    static let invidiousKey = "music.ownInstances.invidious"
    static let ownNetworkKey = "music.ownInstances.ownNetwork"
    static let maxPerKind = 2

    enum Problem: Error, Equatable, Sendable {
        case empty, notAnAddress, wrongScheme, credentials, badPath, needsOwnNetworkTick, needsHTTPS
        var message: String {
            switch self {
            case .empty: Localized.string("Enter an address.")
            case .notAnAddress: Localized.string("That is not a web address.")
            case .wrongScheme: Localized.string("The address must start with https:// or http://")
            case .credentials: Localized.string("Leave out the user name and password.")
            case .badPath: Localized.string("The address has a part the app cannot use.")
            case .needsOwnNetworkTick: Localized.string("Tick \"This is my own server on my network\" to use an address on your own network.")
            case .needsHTTPS: Localized.string("Use an https:// address, or an address on your own network.")
            }
        }
    }

    var piped: [String] = []
    var invidious: [String] = []
    var ownNetwork = false

    func addresses(_ kind: YouTubeInstances.Kind) -> [String] { kind == .piped ? piped : invidious }

    /// The addresses that pass validation, in the order given, at most two per kind.
    func urls(_ kind: YouTubeInstances.Kind) -> [URL] {
        var seen = Set<String>(), out: [URL] = []
        for raw in addresses(kind) {
            guard case .success(let u) = Self.validate(raw, ownNetwork: ownNetwork), seen.insert(u.absoluteString).inserted else { continue }
            out.append(u)
            if out.count == Self.maxPerKind { break }
        }
        return out
    }

    /// The hosts that a stream URL may use even though they are on a private network: only the ones typed here, only with the tick.
    var allowedPrivateHosts: Set<String> {
        guard ownNetwork else { return [] }
        let all = urls(.piped) + urls(.invidious)
        return Set(all.compactMap { $0.host?.lowercased() }.map(MusicOwnHosts.normalised).filter { MusicNetworkPolicy.isPrivateHost($0) })
    }

    // MARK: validation

    /// A clean base address: https (or http for an address on the person's own network), a host, no login, no query, no odd path, no trailing slash.
    static func validate(_ raw: String, ownNetwork: Bool) -> Result<URL, Problem> {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .failure(.empty) }
        if t.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\\" || $0.asciiValue.map { $0 < 0x20 } == true }) { return .failure(.notAnAddress) }
        guard let comps = URLComponents(string: t), let scheme = comps.scheme?.lowercased() else { return .failure(.notAnAddress) }
        guard scheme == "https" || scheme == "http" else { return .failure(.wrongScheme) }
        guard let host = comps.host, !host.isEmpty else { return .failure(.notAnAddress) }
        if comps.user != nil || comps.password != nil { return .failure(.credentials) }
        let authority = t.dropFirst(scheme.count + 3).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if authority.contains("@") { return .failure(.credentials) }
        if comps.query != nil || comps.fragment != nil { return .failure(.badPath) }
        if let port = comps.port, !(1...65535).contains(port) { return .failure(.notAnAddress) }
        var path = comps.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if !path.isEmpty {
            let lower = path.lowercased()
            if lower.contains("%2e") || lower.contains("%2f") || lower.contains("%5c") || lower.contains("%00") || lower.contains("//") { return .failure(.badPath) }
            if path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) { return .failure(.badPath) }
        }
        let isPrivate = MusicNetworkPolicy.isPrivateHost(host)
        if isPrivate && !ownNetwork { return .failure(.needsOwnNetworkTick) }
        if scheme == "http" && !isPrivate { return .failure(.needsHTTPS) }
        var out = URLComponents()
        out.scheme = scheme
        out.host = host
        out.port = comps.port
        out.percentEncodedPath = path
        guard let url = out.url else { return .failure(.notAnAddress) }
        return .success(url)
    }

    /// Splits what was typed into one field into at most two addresses (separated by comma, semicolon, space or new line).
    static func split(_ text: String) -> [String] {
        let parts = text.split(whereSeparator: { ",; \n\t".contains($0) }).map(String.init).filter { !$0.isEmpty }
        return Array(parts.prefix(maxPerKind))
    }

    // MARK: storage

    static func load(_ d: UserDefaults = .standard) -> MusicOwnInstances {
        MusicOwnInstances(piped: (d.stringArray(forKey: pipedKey) ?? []).prefix(maxPerKind).map { $0 },
                          invidious: (d.stringArray(forKey: invidiousKey) ?? []).prefix(maxPerKind).map { $0 },
                          ownNetwork: d.bool(forKey: ownNetworkKey))
    }

    func save(_ d: UserDefaults = .standard) {
        for (key, list) in [(Self.pipedKey, piped), (Self.invidiousKey, invidious)] {
            let clean = Array(list.prefix(Self.maxPerKind))
            if clean.isEmpty { d.removeObject(forKey: key) } else { d.set(clean, forKey: key) }
        }
        if ownNetwork { d.set(true, forKey: Self.ownNetworkKey) } else { d.removeObject(forKey: Self.ownNetworkKey) }
        if d === UserDefaults.standard { MusicOwnHosts.set(allowedPrivateHosts.union(SubsonicServers.privateHosts(d))) }
    }

    static func removeAll(_ d: UserDefaults = .standard) {
        MusicOwnInstances().save(d)
    }

    /// The saved setting, with the private-host allow-list brought in line with it.
    static func current(_ d: UserDefaults = .standard) -> MusicOwnInstances {
        let v = load(d)
        if d === UserDefaults.standard { MusicOwnHosts.set(v.allowedPrivateHosts.union(SubsonicServers.privateHosts(d))) }
        return v
    }
}

/// The hosts a transfer may reach although they are on a private network. One small set, filled only from the person's own server addresses.
/// It is not a switch: a host that is not in it is judged by `MusicNetworkPolicy` exactly as before.
enum MusicOwnHosts {
    private static let state = Locked<(hosts: Set<String>, loaded: Bool)>((hosts: [], loaded: false))

    static func normalised(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if h.hasSuffix(".") { h.removeLast() }
        return h
    }

    static func set(_ hosts: Set<String>) { let clean = Set(hosts.map(normalised)); state.withLock { $0 = (hosts: clean, loaded: true) } }

    /// True for a private host the person configured as their own server. The first call reads the saved setting.
    static func allows(host: String) -> Bool {
        let snapshot = state.withLock { s in (s.hosts, s.loaded) }
        if !snapshot.1 { return MusicOwnInstances.current().allowedPrivateHosts.union(SubsonicServers.privateHosts()).contains(normalised(host)) }
        return snapshot.0.contains(normalised(host))
    }

    static func allows(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        return allows(host: host)
    }
}

// MARK: status

/// What a live check of one own server found.
enum MusicOwnStatus: Equatable, Sendable {
    case working(latencyMs: Int)
    case notReachable
    case blocked

    var line: String {
        switch self {
        case .working(let ms): Localized.string("Working (%d ms)", ms)
        case .notReachable: Localized.string("Not reachable")
        case .blocked: Localized.string("Reached but cannot provide audio (blocked by YouTube?)")
        }
    }

    /// An error from the lookup means the server was reached when it answered with an HTTP status or a reply that is not the API's.
    static func status(forError error: Error) -> MusicOwnStatus {
        guard let e = error as? MusicError else { return .notReachable }
        switch e {
        case .notFound, .refused, .rateLimited, .notSignedIn: return .blocked
        case .network(let s): return s.hasPrefix("HTTP ") || s == "unexpected reply" ? .blocked : .notReachable
        default: return .notReachable
        }
    }
}

struct MusicOwnInstanceStatus: Equatable, Sendable {
    var url: URL
    var status: MusicOwnStatus?
    var line: String { status?.line ?? Localized.string("Not checked yet") }
}

enum MusicOwnProbe {
    /// The same one-call probe the public servers get, with the same 6 second limit, and the answer sorted into the three states.
    static func run(_ kind: YouTubeInstances.Kind, base: URL, http: MusicHTTP, seconds: TimeInterval = YouTubeInstances.probeSeconds,
                    clock: @escaping @Sendable () -> Date = { Date() }) async -> MusicOwnStatus {
        let start = clock()
        do {
            let streams: Int = try await ytmWithTimeout(seconds) {
                switch kind {
                case .piped:
                    let obj = try await http.getObject(base.appendingPathComponent("streams").appendingPathComponent(YouTubeInstances.probeVideoID))
                    return PipedProvider.parseStreams(obj).count
                case .invidious:
                    let obj = try await http.getObject(base.appendingPathComponent("api/v1/videos").appendingPathComponent(YouTubeInstances.probeVideoID), query: ["local": "true"])
                    return InvidiousProvider.parseStreams(obj, base: base).count
                }
            }
            return streams > 0 ? .working(latencyMs: max(0, Int(clock().timeIntervalSince(start) * 1000))) : .blocked
        } catch {
            return MusicOwnStatus.status(forError: error)
        }
    }
}

// MARK: ordering and retry book

/// Which own servers to try and when. Order is the order the person gave, never speed: a slow server is still theirs. A server leaves the
/// list only after repeated hard failures, and is tried again after five minutes.
struct MusicOwnBook: Sendable {
    static let hardFailureLimit = 3
    static let retryAfter: TimeInterval = 5 * 60

    struct Entry: Sendable, Equatable {
        var url: URL
        var failures = 0
        var suspendedUntil: Date?
        var status: MusicOwnStatus?
        var probedAt: Date?
    }

    private(set) var entries: [Entry] = []

    /// Follows the saved list, keeping what is known about addresses that stay.
    mutating func sync(_ urls: [URL]) {
        entries = urls.map { u in entries.first { $0.url == u } ?? Entry(url: u) }
    }

    func usable(now: Date) -> [URL] {
        entries.filter { ($0.suspendedUntil ?? .distantPast) <= now }.map(\.url)
    }

    func needsProbe(_ url: URL, now: Date) -> Bool {
        guard let e = entries.first(where: { $0.url == url }), (e.suspendedUntil ?? .distantPast) <= now else { return false }
        guard let at = e.probedAt else { return true }
        let ttl: TimeInterval = { if case .working? = e.status { return YouTubeInstances.healthTTL } else { return YouTubeInstances.emptyTTL } }()
        return now.timeIntervalSince(at) >= ttl
    }

    mutating func recordProbe(_ url: URL, _ status: MusicOwnStatus, now: Date) {
        guard let i = entries.firstIndex(where: { $0.url == url }) else { return }
        entries[i].status = status
        entries[i].probedAt = now
        if case .working = status { entries[i].failures = 0; entries[i].suspendedUntil = nil } else { fail(i, now: now) }
    }

    mutating func recordSuccess(_ url: URL, now: Date) {
        guard let i = entries.firstIndex(where: { $0.url == url }) else { return }
        entries[i].failures = 0
        entries[i].suspendedUntil = nil
        if entries[i].status == nil || entries[i].status == .notReachable || entries[i].status == .blocked { entries[i].status = .working(latencyMs: 0) }
    }

    mutating func recordFailure(_ url: URL, now: Date) {
        guard let i = entries.firstIndex(where: { $0.url == url }) else { return }
        fail(i, now: now)
    }

    private mutating func fail(_ i: Int, now: Date) {
        entries[i].failures += 1
        if entries[i].failures >= Self.hardFailureLimit { entries[i].suspendedUntil = now.addingTimeInterval(Self.retryAfter) }
    }

    func statuses() -> [MusicOwnInstanceStatus] { entries.map { MusicOwnInstanceStatus(url: $0.url, status: $0.status) } }
}
