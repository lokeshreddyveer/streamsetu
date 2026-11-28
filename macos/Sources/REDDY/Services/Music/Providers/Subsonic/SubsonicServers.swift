import Foundation

/// One server the person added. The address, user name and salt are device settings (never synced, backed up or exported); the password
/// is in the Keychain under `SubsonicServers.passwordAccount(id)` and nowhere else.
struct SubsonicServer: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var address: String
    var username: String
    var salt: String
    /// The person ticked "This is my own server on my network" for this one.
    var ownNetwork: Bool

    var host: String { URL(string: address)?.host ?? address }
    var label: String { username + "@" + host }
}

/// The saved list of servers (at most three) and the rules for adding one.
enum SubsonicServers {
    static let defaultsKey = "music.subsonic.servers"
    static let max = 3

    enum Problem: Error, Equatable, Sendable {
        case address(MusicOwnInstances.Problem), noUser, noPassword, tooMany, duplicate
        var message: String {
            switch self {
            case .address(let p): p.message
            case .noUser: Localized.string("Enter a user name.")
            case .noPassword: Localized.string("Enter a password.")
            case .tooMany: Localized.string("You can add up to 3 servers.")
            case .duplicate: Localized.string("That server and user are already added.")
            }
        }
    }

    static func passwordAccount(_ serverID: String) -> String { "subsonic.\(serverID).password" }

    /// The address as the person typed it, made into a clean base address: https is assumed when no scheme is given.
    static func validate(_ raw: String, ownNetwork: Bool) -> Result<URL, MusicOwnInstances.Problem> {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = t.isEmpty || t.contains("://") ? t : "https://" + t
        return MusicOwnInstances.validate(withScheme, ownNetwork: ownNetwork)
    }

    static func load(_ d: UserDefaults = .standard) -> [SubsonicServer] {
        guard let data = d.data(forKey: defaultsKey), let list = try? JSONDecoder().decode([SubsonicServer].self, from: data) else { return [] }
        return Array(list.prefix(max))
    }

    static func save(_ list: [SubsonicServer], _ d: UserDefaults = .standard) {
        if list.isEmpty { d.removeObject(forKey: defaultsKey) } else if let data = try? JSONEncoder().encode(Array(list.prefix(max))) { d.set(data, forKey: defaultsKey) }
        if d === UserDefaults.standard { MusicOwnHosts.set(MusicOwnInstances.current(d).allowedPrivateHosts) }
    }

    /// The private-network hosts of servers the person ticked as their own. Joined into the allow-list that transfers and the stream proxy use.
    static func privateHosts(_ d: UserDefaults = .standard) -> Set<String> {
        var out = Set<String>()
        for s in load(d) where s.ownNetwork {
            guard case .success(let u) = validate(s.address, ownNetwork: true), let h = u.host else { continue }
            let n = MusicOwnHosts.normalised(h)
            if MusicNetworkPolicy.isPrivateHost(n) { out.insert(n) }
        }
        return out
    }

    /// Checks what was typed and, when it is fine, saves the server and its password. Returns the saved server.
    @discardableResult
    static func add(address: String, username: String, password: String, ownNetwork: Bool, defaults d: UserDefaults = .standard,
                    keychain: MusicKeychain = .shared) -> Result<SubsonicServer, Problem> {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if user.isEmpty { return .failure(.noUser) }
        if password.isEmpty { return .failure(.noPassword) }
        let url: URL
        switch validate(address, ownNetwork: ownNetwork) { case .success(let u): url = u; case .failure(let p): return .failure(.address(p)) }
        var list = load(d)
        if list.count >= max { return .failure(.tooMany) }
        if list.contains(where: { $0.address == url.absoluteString && $0.username == user }) { return .failure(.duplicate) }
        let server = SubsonicServer(id: SubsonicAuth.makeSalt(length: 8), address: url.absoluteString, username: user, salt: SubsonicAuth.makeSalt(), ownNetwork: ownNetwork)
        guard keychain.write(passwordAccount(server.id), password) else { return .failure(.noPassword) }
        list.append(server)
        save(list, d)
        return .success(server)
    }

    static func remove(id: String, defaults d: UserDefaults = .standard, keychain: MusicKeychain = .shared) {
        keychain.remove(passwordAccount(id))
        save(load(d).filter { $0.id != id }, d)
    }

    static func removeAll(defaults d: UserDefaults = .standard, keychain: MusicKeychain = .shared) {
        for s in load(d) { keychain.remove(passwordAccount(s.id)) }
        save([], d)
    }

    /// A signed session for every saved server that still has its password and a usable address.
    static func sessions(_ servers: [SubsonicServer], password: (String) -> String?) -> [SubsonicSession] {
        servers.compactMap { s in
            guard let pw = password(passwordAccount(s.id)), !pw.isEmpty, case .success(let u) = validate(s.address, ownNetwork: s.ownNetwork) else { return nil }
            return SubsonicSession(serverID: s.id, base: u, user: s.username, password: pw, salt: s.salt)
        }
    }
}

/// What a live check of one server found, in words a person can act on.
enum SubsonicStatus: Equatable, Sendable {
    case working(latencyMs: Int, info: SubsonicServerInfo)
    case wrongLogin
    case notAllowed
    case notASubsonicServer
    case notReachable

    var line: String {
        switch self {
        case .working(let ms, _): Localized.string("Working (%d ms)", ms)
        case .wrongLogin: Localized.string("Wrong user name or password")
        case .notAllowed: Localized.string("This account is not allowed to use the server")
        case .notASubsonicServer: Localized.string("Not a Subsonic or Navidrome server")
        case .notReachable: Localized.string("Not reachable")
        }
    }

    var isWorking: Bool { if case .working = self { true } else { false } }

    static func status(forError e: Error) -> SubsonicStatus {
        guard let m = e as? MusicError else { return .notReachable }
        switch m {
        case .notSignedIn: return .wrongLogin
        case .refused: return .notAllowed
        case .notFound: return .notASubsonicServer
        case .network(let s): return s.hasPrefix("HTTP ") || s == "unexpected reply" || s.hasPrefix("server ") ? .notASubsonicServer : .notReachable
        default: return .notReachable
        }
    }
}

enum SubsonicProbe {
    /// One `ping` call with the same 6 second limit the other own-server checks use.
    static func run(_ session: SubsonicSession, http: MusicHTTP, seconds: TimeInterval = YouTubeInstances.probeSeconds,
                    clock: @escaping @Sendable () -> Date = { Date() }) async -> SubsonicStatus {
        let start = clock()
        do {
            let info: SubsonicServerInfo = try await ytmWithTimeout(seconds) {
                guard let url = session.url("ping") else { throw MusicError.network("bad address") }
                return SubsonicReply.info(try SubsonicReply.envelope(try await http.getObject(url)))
            }
            return .working(latencyMs: max(0, Int(clock().timeIntervalSince(start) * 1000)), info: info)
        } catch {
            return SubsonicStatus.status(forError: error)
        }
    }
}
