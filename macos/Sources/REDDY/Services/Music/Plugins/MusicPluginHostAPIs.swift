import Foundation
import CryptoKit
import Security

// The Swift side of everything a plugin can touch: network, storage, crypto, system info and logging. The JavaScript the plugin sees is only a thin
// wrapper; every permission is checked again here, so a plugin that reaches around the wrapper still gets nothing.

struct PluginMessageError: Error, Sendable { let message: String }

// MARK: - Network policy

enum MusicPluginPolicy {
    static let maxResponseBytes = 5 * 1024 * 1024
    static let maxRequestBodyBytes = 1024 * 1024

    /// `api.example.com` or `*.example.com`: at least two labels, letters / digits / hyphens, and not an IP address or `localhost`.
    static func isValidHostPattern(_ pattern: String) -> Bool {
        var p = pattern
        if p.hasPrefix("*.") { p.removeFirst(2) }
        guard p == p.lowercased(), p.count <= 253 else { return false }
        let labels = p.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for l in labels {
            guard (1...63).contains(l.utf8.count), l.first != "-", l.last != "-" else { return false }
            guard l.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }) else { return false }
        }
        // A numeric last label would be an IPv4 address.
        if let last = labels.last, last.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) { return false }
        return true
    }

    static func hostAllowed(_ host: String, patterns: [String]) -> Bool {
        let h = host.lowercased()
        for p in patterns {
            if p.hasPrefix("*.") { if h.hasSuffix(String(p.dropFirst(1))) && h.count > p.count - 1 { return true } }
            else if h == p { return true }
        }
        return false
    }

    /// The only gate for plugin network access: https, default port, no credentials in the address, and a listed host.
    static func validate(urlString: String, allowedHosts: [String]) throws -> URL {
        guard let comps = URLComponents(string: urlString), let url = comps.url, let scheme = comps.scheme?.lowercased(), let host = comps.host, !host.isEmpty
        else { throw PluginMessageError(message: "that is not a valid address") }
        guard scheme == "https" else { throw PluginMessageError(message: "plugins may only use https addresses") }
        guard comps.user == nil, comps.password == nil else { throw PluginMessageError(message: "addresses with a user name are not allowed") }
        guard comps.port == nil || comps.port == 443 else { throw PluginMessageError(message: "only the standard https port is allowed") }
        guard hostAllowed(host, patterns: allowedHosts) else { throw PluginMessageError(message: "the plugin is not allowed to contact \(host)") }
        return url
    }
}

/// Default transport for plugins: through the app's HTTP client (proxy, secure DNS), no cookies or cache, and a redirect to a host outside the plugin's list is refused, so an allowed host cannot bounce
/// a request (and its headers) somewhere else.
struct PluginGuardedTransport: MusicHTTPTransport {
    let allowedHosts: [String]
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var r = request
        r.httpShouldHandleCookies = false
        r.cachePolicy = .reloadIgnoringLocalCacheData
        if r.timeoutInterval > 20 { r.timeoutInterval = 20 }
        let hosts = allowedHosts
        do {
            let (d, resp) = try await HTTPClient.app.fetch(r, maxBytes: URLSessionTransport.maxBytes, allowRedirect: { url in
                (try? MusicPluginPolicy.validate(urlString: url.absoluteString, allowedHosts: hosts)) != nil
            })
            guard let h = resp as? HTTPURLResponse else { throw MusicError.network("bad response") }
            return (d, h)
        } catch is CancellationError { throw MusicError.cancelled
        } catch let e as MusicError { throw e
        } catch let e as URLError where e.code == .cancelled { throw MusicError.cancelled
        } catch { throw MusicError.network((error as NSError).localizedDescription) }
    }
}

// MARK: - Log ring

/// The last few console lines of one plugin, so the person (and a bug report) can see what it said without any log leaving the device.
final class PluginLogRing: @unchecked Sendable {
    struct Entry: Sendable, Hashable { let date: Date; let level: String; let message: String }
    static let capacity = 200
    private let lock = NSLock()
    private var items: [Entry] = []
    func append(level: String, _ message: String) {
        let lvl = ["log", "info", "warn", "error", "debug"].contains(level) ? level : "log"
        lock.lock(); defer { lock.unlock() }
        items.append(Entry(date: Date(), level: lvl, message: String(message.prefix(1000))))
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
    }
    var entries: [Entry] { lock.lock(); defer { lock.unlock() }; return items }
    func clear() { lock.lock(); items.removeAll(); lock.unlock() }
}

// MARK: - Storage

/// One small JSON file per plugin, `{key: json text}`. Capped so a plugin cannot fill the disk.
final class PluginStorage: @unchecked Sendable {
    static let maxBytes = 256 * 1024
    static let maxKeys = 256
    static let maxKeyLength = 128
    private let url: URL
    private let lock = NSLock()
    private var values: [String: String]

    init(url: URL) {
        self.url = url
        if let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode([String: String].self, from: d) { values = v } else { values = [:] }
    }
    func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func set(_ key: String, json: String) throws {
        guard !key.isEmpty, key.count <= Self.maxKeyLength else { throw PluginMessageError(message: "storage keys must be 1 to 128 characters") }
        lock.lock(); defer { lock.unlock() }
        var next = values; next[key] = json
        guard next.count <= Self.maxKeys else { throw PluginMessageError(message: "storage is full (too many keys)") }
        let data = try encode(next)
        guard data.count <= Self.maxBytes else { throw PluginMessageError(message: "storage is full (256 KB limit)") }
        try write(data); values = next
    }
    func remove(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard values[key] != nil else { return }
        var next = values; next[key] = nil
        try write(try encode(next)); values = next
    }
    func wipe() { lock.lock(); values = [:]; try? FileManager.default.removeItem(at: url); lock.unlock() }
    private func encode(_ v: [String: String]) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return try e.encode(v)
    }
    private func write(_ d: Data) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: url, options: .atomic)
        } catch { throw PluginMessageError(message: "storage could not be saved") }
    }
}

// MARK: - Keychain (secrets such as tokens)

enum PluginKeychain {
    static let service = MusicKeychain.service
    private static func account(_ plugin: String, _ key: String) -> String { "plugin.\(plugin).\(key)" }
    /// The keys a plugin stored, so uninstalling it can remove them all.
    private static func indexAccount(_ plugin: String) -> String { "plugin.\(plugin).__keys" }
    private static func keys(_ plugin: String) -> [String] {
        MusicKeychain.shared.read(indexAccount(plugin)).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }
    private static func saveKeys(_ plugin: String, _ keys: [String]) {
        let text = (try? JSONEncoder().encode(keys.sorted())).flatMap { String(data: $0, encoding: .utf8) }
        MusicKeychain.shared.write(indexAccount(plugin), keys.isEmpty ? nil : text)
    }
    static func get(plugin: String, key: String) -> String? { MusicKeychain.shared.read(account(plugin, key)) }
    @discardableResult static func set(plugin: String, key: String, value: String) -> Bool {
        guard MusicKeychain.shared.write(account(plugin, key), value) else { return false }
        var k = keys(plugin)
        if !k.contains(key) { k.append(key); saveKeys(plugin, k) }
        return true
    }
    static func remove(plugin: String, key: String) {
        MusicKeychain.shared.remove(account(plugin, key))
        saveKeys(plugin, keys(plugin).filter { $0 != key })
    }
    /// Removes every secret the plugin ever stored (used when it is uninstalled).
    static func removeAll(plugin: String) {
        for k in keys(plugin) { MusicKeychain.shared.remove(account(plugin, k)) }
        MusicKeychain.shared.remove(indexAccount(plugin))
    }
}

// MARK: - Host APIs

/// Everything the JavaScript wrappers call into. Methods that can fail synchronously return a string starting with `errorMark`, which the wrapper turns into a JS exception.
final class PluginHostAPIs: @unchecked Sendable {
    static let errorMark = "\u{0}!"
    static let maxConcurrentFetches = 8
    static let maxCryptoInput = 1024 * 1024

    let manifest: MusicPluginManifest
    let logs: PluginLogRing
    let storage: PluginStorage
    private let http: MusicHTTP
    private let lock = NSLock()
    private var inFlight = 0

    init(manifest: MusicPluginManifest, storageURL: URL, http: MusicHTTP, logs: PluginLogRing) {
        self.manifest = manifest; self.storage = PluginStorage(url: storageURL); self.http = http; self.logs = logs
    }

    private static func err(_ s: String) -> String { errorMark + s }

    var permissionsJSON: String {
        let p = manifest.permissions
        return "{\"network\":\(p.network),\"storage\":\(p.storage),\"crypto\":\(p.crypto)}"
    }

    var systemJSON: String {
        #if os(macOS)
        let platform = "macos"
        #else
        let platform = "ios"
        #endif
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        let obj: [String: Any] = ["platform": platform, "appVersion": version, "locale": Locale.current.identifier, "apiVersion": MusicPluginLimits.supportedAPIVersion]
        let d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return String(decoding: d, as: UTF8.self)
    }

    func log(level: String, message: String) { logs.append(level: level, message) }

    // MARK: storage / secrets

    func storageGet(_ key: String) -> String? {
        guard manifest.permissions.storage else { return Self.err("this plugin has no storage permission") }
        return storage.get(key)
    }
    func storageSet(_ key: String, _ json: String) -> String? {
        guard manifest.permissions.storage else { return Self.err("this plugin has no storage permission") }
        do { try storage.set(key, json: json) } catch let e as PluginMessageError { return Self.err(e.message) } catch { return Self.err("storage failed") }
        return nil
    }
    func storageRemove(_ key: String) -> String? {
        guard manifest.permissions.storage else { return Self.err("this plugin has no storage permission") }
        do { try storage.remove(key) } catch { return Self.err("storage failed") }
        return nil
    }
    func secretGet(_ key: String) -> String? {
        guard manifest.permissions.storage else { return Self.err("this plugin has no storage permission") }
        return PluginKeychain.get(plugin: manifest.id, key: key)
    }
    func secretSet(_ key: String, _ value: String) -> String? {
        guard manifest.permissions.storage else { return Self.err("this plugin has no storage permission") }
        guard !key.isEmpty, key.count <= 128, value.utf8.count <= 16 * 1024 else { return Self.err("secret too large") }
        return PluginKeychain.set(plugin: manifest.id, key: key, value: value) ? nil : Self.err("secret could not be saved")
    }
    func secretRemove(_ key: String) -> String? {
        guard manifest.permissions.storage else { return Self.err("this plugin has no storage permission") }
        PluginKeychain.remove(plugin: manifest.id, key: key); return nil
    }

    // MARK: crypto

    private static func decode(_ s: String, _ enc: String) -> Data? {
        switch enc {
        case "utf8": return Data(s.utf8)
        case "base64": return Data(base64Encoded: s)
        case "hex":
            guard s.utf8.count % 2 == 0 else { return nil }
            var out = Data(); var i = s.startIndex
            while i < s.endIndex {
                let j = s.index(i, offsetBy: 2)
                guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
                out.append(b); i = j
            }
            return out
        default: return nil
        }
    }
    private static func encode(_ d: Data, _ enc: String) -> String? {
        switch enc {
        case "hex": return MusicHash.hex(d)
        case "base64": return d.base64EncodedString()
        case "utf8": return String(data: d, encoding: .utf8)
        default: return nil
        }
    }

    /// ops: md5, sha1, sha256, hmacSha256 (key in `key`), b64enc, b64dec, random (`data` holds the byte count).
    func crypto(op: String, data: String, key: String, inEnc: String, outEnc: String) -> String {
        guard manifest.permissions.crypto else { return Self.err("this plugin has no crypto permission") }
        guard data.utf8.count <= Self.maxCryptoInput else { return Self.err("input too large") }
        let result: Data
        switch op {
        case "random":
            guard let n = Int(data), (1...1024).contains(n) else { return Self.err("random bytes: ask for 1 to 1024") }
            result = SymmetricKey(size: SymmetricKeySize(bitCount: n * 8)).withUnsafeBytes { Data($0) }
        case "b64enc":
            result = Data(data.utf8)
            return result.base64EncodedString()
        case "b64dec":
            guard let d = Data(base64Encoded: data), let s = String(data: d, encoding: .utf8) else { return Self.err("not valid base64 text") }
            return s
        case "md5", "sha1", "sha256", "hmacSha256":
            guard let input = Self.decode(data, inEnc) else { return Self.err("input does not match its encoding") }
            switch op {
            case "md5": result = Data(Insecure.MD5.hash(data: input))
            case "sha1": result = Data(Insecure.SHA1.hash(data: input))
            case "sha256": result = Data(SHA256.hash(data: input))
            default:
                guard let k = Self.decode(key, inEnc) else { return Self.err("key does not match its encoding") }
                result = Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: k)))
            }
        default: return Self.err("unknown crypto operation")
        }
        return Self.encode(result, outEnc) ?? Self.err("bad output encoding")
    }

    // MARK: network

    private func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard inFlight < Self.maxConcurrentFetches else { return false }
        inFlight += 1; return true
    }
    private func end() { lock.lock(); inFlight -= 1; lock.unlock() }

    /// Validates synchronously, then sends through the MusicHTTP transport. `completion` gets a JSON string
    /// `{status, url, headers, text|base64}` or a message. It may be called on any thread.
    func startFetch(_ urlString: String, optionsJSON: String, completion: @escaping @Sendable (Result<String, PluginMessageError>) -> Void) {
        let request: URLRequest; let wantsBase64: Bool; let hosts = manifest.permissions.networkHosts
        do {
            guard manifest.permissions.network else { throw PluginMessageError(message: "this plugin has no network permission") }
            let url = try MusicPluginPolicy.validate(urlString: urlString, allowedHosts: hosts)
            let opts = ((try? JSONSerialization.jsonObject(with: Data(optionsJSON.utf8))) as? [String: Any]) ?? [:]
            let method = ((opts["method"] as? String) ?? "GET").uppercased()
            guard ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"].contains(method) else { throw PluginMessageError(message: "method not allowed") }
            var r = URLRequest(url: url); r.httpMethod = method; r.timeoutInterval = 20
            r.setValue(http.userAgent, forHTTPHeaderField: "User-Agent")
            if let h = opts["headers"] as? [String: Any] {
                guard h.count <= 32 else { throw PluginMessageError(message: "too many headers") }
                for (k, v) in h {
                    let lk = k.lowercased()
                    guard let s = v as? String, !["host", "content-length", "connection", "transfer-encoding"].contains(lk), !k.contains("\n"), !s.contains("\n"), !s.contains("\r")
                    else { throw PluginMessageError(message: "header \(k) is not allowed") }
                    r.setValue(s, forHTTPHeaderField: k)
                }
            }
            if let b = opts["body"] as? String {
                guard method != "GET", method != "HEAD" else { throw PluginMessageError(message: "a GET request cannot have a body") }
                guard b.utf8.count <= MusicPluginPolicy.maxRequestBodyBytes else { throw PluginMessageError(message: "request body too large") }
                r.httpBody = Data(b.utf8)
            }
            request = r; wantsBase64 = (opts["responseType"] as? String) == "base64"
        } catch let e as PluginMessageError { completion(.failure(e)); return } catch { completion(.failure(PluginMessageError(message: "bad request"))); return }
        guard begin() else { completion(.failure(PluginMessageError(message: "too many requests at once"))); return }
        let transport = http.transport
        Task { [self] in
            defer { end() }
            do {
                let (data, resp) = try await transport.data(for: request)
                if let final = resp.url?.absoluteString, (try? MusicPluginPolicy.validate(urlString: final, allowedHosts: hosts)) == nil {
                    completion(.failure(PluginMessageError(message: "the reply came from a host the plugin may not contact"))); return
                }
                guard data.count <= MusicPluginPolicy.maxResponseBytes else { completion(.failure(PluginMessageError(message: "the reply is larger than 5 MB"))); return }
                var headers: [String: String] = [:]
                for (k, v) in resp.allHeaderFields { if let ks = k as? String, let vs = v as? String { headers[ks.lowercased()] = vs } }
                var obj: [String: Any] = ["status": resp.statusCode, "url": resp.url?.absoluteString ?? "", "headers": headers]
                if wantsBase64 { obj["base64"] = data.base64EncodedString() } else { obj["text"] = String(decoding: data, as: UTF8.self) }
                guard let out = try? JSONSerialization.data(withJSONObject: obj) else { completion(.failure(PluginMessageError(message: "bad reply"))); return }
                completion(.success(String(decoding: out, as: UTF8.self)))
            } catch let e as MusicError {
                completion(.failure(PluginMessageError(message: e.errorDescription ?? "network problem")))
            } catch { completion(.failure(PluginMessageError(message: "network problem"))) }
        }
    }
}
