import Foundation

/// A debrid service turns a link from a file host (or a magnet link) into a direct address that plays. The person brings their own account: the API token is pasted in Settings and kept
/// in the Keychain, and is sent only to that service. Nothing goes through a server of ours.
enum DebridService: String, CaseIterable, Codable, Sendable, Identifiable {
    case realDebrid, allDebrid, premiumize
    var id: String { rawValue }
    var title: String { switch self { case .realDebrid: "Real-Debrid"; case .allDebrid: "AllDebrid"; case .premiumize: "Premiumize" } }
    /// Where the person finds their API token.
    var tokenHelp: String {
        switch self {
        case .realDebrid: "real-debrid.com/apitoken"
        case .allDebrid: "alldebrid.com/apikeys"
        case .premiumize: "premiumize.me/account"
        }
    }
}

/// What kind of address was given.
enum DebridInput: Equatable, Sendable {
    case link(URL), magnet(String), invalid

    static func parse(_ raw: String) -> DebridInput {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("magnet:?"), t.lowercased().contains("xt=urn:btih:") || t.lowercased().contains("xt=urn:btmh:") { return .magnet(t) }
        if let u = URL(string: t), let s = u.scheme?.lowercased(), s == "http" || s == "https", u.host?.isEmpty == false { return .link(u) }
        return .invalid
    }
}

enum DebridError: LocalizedError, Equatable {
    case noToken, invalid, magnetsNotAllowed, rejected(String), notReady(String), noVideo, network(String)
    var errorDescription: String? {
        switch self {
        case .noToken: "Add your debrid token in Settings first."
        case .invalid: "That is not a link or a magnet link."
        case .magnetsNotAllowed: "Magnet links are not supported in this app."
        case .rejected(let m): m
        case .notReady(let m): m
        case .noVideo: "No video was found in it."
        case .network(let m): m
        }
    }
}

/// One playable result.
struct DebridResult: Equatable, Sendable { let name: String; let url: URL }

struct DebridClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Magnet and torrent links are used only where the app is not distributed through the App Store: the notarized Mac download. The iPhone and iPad apps take links only.
    static var magnetsAllowed: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    static let videoExtensions: Set<String> = ["mp4", "mkv", "avi", "mov", "m4v", "webm", "ts", "m2ts", "wmv", "flv", "mpg", "mpeg"]
    static func isVideo(_ name: String) -> Bool { videoExtensions.contains((name as NSString).pathExtension.lowercased()) }

    let service: DebridService
    let token: String
    var allowMagnets: Bool = DebridClient.magnetsAllowed
    var transport: Transport = DebridClient.live
    /// How long a magnet is waited for while the service fetches it, and how often it is asked.
    var magnetWait: TimeInterval = 45
    var pollEvery: TimeInterval = 2

    static let live: Transport = { request in
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 25
        let (data, response) = try await URLSession(configuration: cfg).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DebridError.network("No answer from the service.") }
        return (data, http)
    }

    /// The direct address(es) for a link or a magnet. A link gives one; a magnet gives its video (the largest one when several).
    func resolve(_ raw: String) async throws -> DebridResult {
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { throw DebridError.noToken }
        switch DebridInput.parse(raw) {
        case .invalid: throw DebridError.invalid
        case .link(let url): return try await unlock(url.absoluteString)
        case .magnet(let m):
            guard allowMagnets else { throw DebridError.magnetsNotAllowed }
            switch service {
            case .realDebrid: return try await realDebridMagnet(m)
            case .allDebrid: return try await allDebridMagnet(m)
            case .premiumize: return try await premiumizeDirect(m)
            }
        }
    }

    // MARK: single link

    private func unlock(_ link: String) async throws -> DebridResult {
        switch service {
        case .realDebrid:
            let j = try await json(post("https://api.real-debrid.com/rest/1.0/unrestrict/link", form: ["link": link]), service: .realDebrid)
            guard let s = j["download"] as? String, let u = URL(string: s) else { throw DebridError.rejected(Self.message(j, service) ?? "Real-Debrid could not unlock that link.") }
            return DebridResult(name: (j["filename"] as? String) ?? u.lastPathComponent, url: u)
        case .allDebrid:
            let j = try await json(get("https://api.alldebrid.com/v4/link/unlock", query: ["agent": "StreamSetu", "link": link]), service: .allDebrid)
            guard let d = j["data"] as? [String: Any], let s = d["link"] as? String, let u = URL(string: s) else { throw DebridError.rejected(Self.message(j, service) ?? "AllDebrid could not unlock that link.") }
            return DebridResult(name: (d["filename"] as? String) ?? u.lastPathComponent, url: u)
        case .premiumize:
            return try await premiumizeDirect(link)
        }
    }

    // MARK: Premiumize (links and cached magnets)

    private func premiumizeDirect(_ src: String) async throws -> DebridResult {
        let j = try await json(post("https://www.premiumize.me/api/transfer/directdl", form: ["src": src]), service: .premiumize)
        guard (j["status"] as? String) == "success" else { throw DebridError.rejected(Self.message(j, .premiumize) ?? "Premiumize could not unlock that.") }
        let files = (j["content"] as? [[String: Any]]) ?? []
        let videos = files.compactMap { f -> (name: String, url: URL, size: Double)? in
            guard let path = f["path"] as? String, Self.isVideo(path), let s = (f["stream_link"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? (f["link"] as? String), let u = URL(string: s) else { return nil }
            return ((path as NSString).lastPathComponent, u, (f["size"] as? Double) ?? Double(f["size"] as? Int ?? 0))
        }
        guard let best = videos.max(by: { $0.size < $1.size }) else { throw DebridError.noVideo }
        return DebridResult(name: best.name, url: best.url)
    }

    // MARK: Real-Debrid magnets

    private func realDebridMagnet(_ magnet: String) async throws -> DebridResult {
        let added = try await json(post("https://api.real-debrid.com/rest/1.0/torrents/addMagnet", form: ["magnet": magnet]), service: .realDebrid)
        guard let id = added["id"] as? String else { throw DebridError.rejected(Self.message(added, .realDebrid) ?? "Real-Debrid did not accept that magnet link.") }
        let deadline = Date().addingTimeInterval(magnetWait)
        var selected = false
        while true {
            let info = try await json(get("https://api.real-debrid.com/rest/1.0/torrents/info/\(id)"), service: .realDebrid)
            let status = (info["status"] as? String) ?? ""
            if status == "waiting_files_selection", !selected {
                let files = (info["files"] as? [[String: Any]]) ?? []
                let videos = files.filter { Self.isVideo(($0["path"] as? String) ?? "") }
                guard let best = videos.max(by: { (($0["bytes"] as? Double) ?? Double($0["bytes"] as? Int ?? 0)) < (($1["bytes"] as? Double) ?? Double($1["bytes"] as? Int ?? 0)) }), let fid = best["id"] else { throw DebridError.noVideo }
                _ = try await send(post("https://api.real-debrid.com/rest/1.0/torrents/selectFiles/\(id)", form: ["files": "\(fid)"]))
                selected = true
            } else if status == "downloaded", let first = (info["links"] as? [String])?.first {
                return try await unlock(first)
            } else if ["magnet_error", "error", "virus", "dead"].contains(status) {
                throw DebridError.rejected("Real-Debrid could not fetch that torrent (\(status)).")
            }
            if Date() >= deadline { throw DebridError.notReady("Real-Debrid is still fetching it (\(status.isEmpty ? "queued" : status)). Try again in a little while: it keeps going in your account.") }
            try await Task.sleep(nanoseconds: UInt64(pollEvery * 1_000_000_000))
        }
    }

    // MARK: AllDebrid magnets

    private func allDebridMagnet(_ magnet: String) async throws -> DebridResult {
        let up = try await json(post("https://api.alldebrid.com/v4/magnet/upload", form: ["agent": "StreamSetu", "magnets[]": magnet]), service: .allDebrid)
        guard let mags = (up["data"] as? [String: Any])?["magnets"] as? [[String: Any]], let first = mags.first, let id = first["id"] as? Int else {
            throw DebridError.rejected(Self.message(up, .allDebrid) ?? "AllDebrid did not accept that magnet link.")
        }
        let deadline = Date().addingTimeInterval(magnetWait)
        while true {
            let st = try await json(get("https://api.alldebrid.com/v4/magnet/status", query: ["agent": "StreamSetu", "id": "\(id)"]), service: .allDebrid)
            let m = (st["data"] as? [String: Any])?["magnets"] as? [String: Any]
            let code = (m?["statusCode"] as? Int) ?? -1
            if code == 4 {
                let links = (m?["links"] as? [[String: Any]]) ?? []
                let videos = links.filter { Self.isVideo(($0["filename"] as? String) ?? "") }
                guard let best = videos.max(by: { (($0["size"] as? Double) ?? Double($0["size"] as? Int ?? 0)) < (($1["size"] as? Double) ?? Double($1["size"] as? Int ?? 0)) }), let link = best["link"] as? String else { throw DebridError.noVideo }
                return try await unlock(link)
            }
            if code >= 5 { throw DebridError.rejected("AllDebrid could not fetch that torrent.") }
            if Date() >= deadline { throw DebridError.notReady("AllDebrid is still fetching it. Try again in a little while: it keeps going in your account.") }
            try await Task.sleep(nanoseconds: UInt64(pollEvery * 1_000_000_000))
        }
    }

    // MARK: plumbing

    private func authorized(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 25)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("StreamSetu", forHTTPHeaderField: "User-Agent")
        return r
    }

    private func get(_ base: String, query: [String: String] = [:]) -> URLRequest {
        var c = URLComponents(string: base)!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return authorized(c.url!)
    }

    private func post(_ base: String, form: [String: String]) -> URLRequest {
        var r = authorized(URL(string: base)!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~[]")
        r.httpBody = form.sorted { $0.key < $1.key }.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }.joined(separator: "&").data(using: .utf8)
        return r
    }

    private func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do { return try await transport(r) } catch let e as DebridError { throw e } catch { throw DebridError.network(error.localizedDescription) }
    }

    private func json(_ r: URLRequest, service: DebridService) async throws -> [String: Any] {
        let (data, http) = try await send(r)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if http.statusCode == 401 || http.statusCode == 403 { throw DebridError.rejected("\(service.title) did not accept the token.") }
        if http.statusCode == 429 { throw DebridError.rejected("\(service.title) says too many requests. Wait a minute.") }
        if http.statusCode >= 500 { throw DebridError.network("\(service.title) is not answering (\(http.statusCode)).") }
        if http.statusCode >= 400, obj.isEmpty { throw DebridError.rejected("\(service.title) answered \(http.statusCode).") }
        if http.statusCode >= 400, let m = Self.message(obj, service) { throw DebridError.rejected(m) }
        return obj
    }

    /// The service's own explanation of a refusal, when it gives one.
    static func message(_ j: [String: Any], _ service: DebridService) -> String? {
        switch service {
        case .realDebrid: return (j["error"] as? String).map { $0.replacingOccurrences(of: "_", with: " ") }
        case .allDebrid: return ((j["error"] as? [String: Any])?["message"] as? String)
        case .premiumize: return j["message"] as? String
        }
    }
}

/// Your debrid account details, kept in the vault.
struct DebridAccount: Equatable, Sendable {
    var service: DebridService = .realDebrid
    var token = ""
    var isComplete: Bool { !token.trimmingCharacters(in: .whitespaces).isEmpty }
}

struct DebridStore: @unchecked Sendable {
    let store: CredentialStore
    private let ref = "debrid"

    func load() -> DebridAccount {
        guard let c = try? store.load(ref: ref), let token = c.password else { return DebridAccount() }
        return DebridAccount(service: DebridService(rawValue: c.username ?? "") ?? .realDebrid, token: token)
    }

    func save(_ a: DebridAccount) {
        if !a.isComplete { try? store.delete(ref: ref); return }
        try? store.save(Credentials(username: a.service.rawValue, password: a.token.trimmingCharacters(in: .whitespaces)), ref: ref)
    }
}
