import Foundation

/// The two AcoustID keys. The application key says which app is calling; the user key says for whom. Both live in the Keychain, are sent in request headers (a key
/// in a URL would end up in logs), and are never written to a log, a file or the source. The user pastes their own user key in Settings; the application key is the
/// developer's, registered once with AcoustID.
struct AcoustIDKeys: Sendable {
    static let userAccount = "acoustid.userkey"
    static let applicationAccount = "acoustid.appkey"
    var store: any ScrobbleSecretStore = ScrobbleKeychainStore()

    var userKey: String? { clean(store.read(Self.userAccount)) }
    var applicationKey: String? { clean(store.read(Self.applicationAccount)) ?? BuiltInAcoustID.applicationKey() }

    private func clean(_ s: String?) -> String? { s.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } }

    /// A key is a short run of letters and digits; anything else (a pasted URL, a sentence) is refused.
    static func isPlausible(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return (8...40).contains(t.count) && t.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static let linkAccount = "acoustid.link"

    /// The link this device asked for, while there is one (a pasted key has none).
    var link: AcoustIDLinkRecord? {
        store.read(Self.linkAccount).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(AcoustIDLinkRecord.self, from: $0) }
    }

    /// The key lookups may send: a pasted key, or a linked key once it is approved. A key still waiting for approval is never sent.
    var activeUserKey: String? {
        guard let k = userKey else { return nil }
        guard let l = link else { return k }
        return l.state == .approved ? k : nil
    }

    func storePendingLink(key: String, record: AcoustIDLinkRecord) {
        // The record is written first: a key with no record would count as a pasted one and be used before approval.
        guard let d = try? JSONEncoder().encode(record), let s = String(data: d, encoding: .utf8) else { return }
        store.write(s, account: Self.linkAccount)
        store.write(key, account: Self.userAccount)
    }

    func markLinkApproved() {
        guard var l = link else { return }
        l.state = .approved
        if let d = try? JSONEncoder().encode(l), let s = String(data: d, encoding: .utf8) { store.write(s, account: Self.linkAccount) }
    }

    func clearUser() { store.remove(Self.userAccount); store.remove(Self.linkAccount) }

    func setUserKey(_ s: String) -> Bool {
        guard Self.isPlausible(s) else { return false }
        store.remove(Self.linkAccount)
        store.write(s.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.userAccount); return true
    }
    func setApplicationKey(_ s: String) -> Bool { guard Self.isPlausible(s) else { return false }; store.write(s.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.applicationAccount); return true }
    func removeUserKey() { clearUser() }
}

/// At most three requests a second, as AcoustID asks.
actor AcoustIDRateGate {
    static let shared = AcoustIDRateGate()
    static let interval: TimeInterval = 0.34
    private var next = Date.distantPast
    func wait() async {
        let now = Date()
        let start = max(now, next)
        next = start.addingTimeInterval(Self.interval)
        let delay = start.timeIntervalSince(now)
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }
}

struct AcoustIDClient: Sendable {
    static let endpoint = URL(string: "https://api.acoustid.org/v2/lookup")!
    var http: MusicHTTP = MusicHTTP()
    var keys = AcoustIDKeys()

    /// The form body of a lookup: the fingerprint, its duration and which details to return. Keys are not in it.
    static func body(fingerprint: String, duration: Int) -> Data {
        var c = URLComponents()
        c.queryItems = [URLQueryItem(name: "duration", value: String(duration)), URLQueryItem(name: "fingerprint", value: fingerprint), URLQueryItem(name: "meta", value: "recordings releasegroups")]
        return Data((c.percentEncodedQuery ?? "").utf8)
    }

    private func scrub(_ s: String) -> String { AcoustIDRedactor.redact(s, keys: [keys.applicationKey, keys.userKey]) }

    static let requestLinkEndpoint = URL(string: "https://api.acoustid.org/v2/user/request_link")!
    static let linkStatusEndpoint = URL(string: "https://api.acoustid.org/v2/user/link_status")!

    /// Asks for a user key to be linked to this application. The application key goes in its header; the reply holds the key and the code the person approves.
    func requestLink(device: String) async throws -> AcoustIDLinkRequest {
        guard let app = keys.applicationKey else { throw AcoustIDError.needsApplicationKey }
        var c = URLComponents()
        c.queryItems = [URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "device", value: String(device.prefix(100)))]
        let body = Data((c.percentEncodedQuery ?? "").utf8)
        let reply = try await send(url: Self.requestLinkEndpoint, headers: ["Content-Type": "application/x-www-form-urlencoded", "Acoustid-App-Key": app], body: body)
        return try AcoustIDLinkParser.requestLink(reply).get()
    }

    /// Where a linked key stands: both keys travel in headers.
    func linkStatus(userKey: String) async throws -> AcoustIDLinkState {
        guard let app = keys.applicationKey else { throw AcoustIDError.needsApplicationKey }
        let reply = try await send(url: Self.linkStatusEndpoint, headers: ["Content-Type": "application/x-www-form-urlencoded", "Acoustid-App-Key": app, "Acoustid-User-Key": userKey], body: Data("format=json".utf8))
        return try AcoustIDLinkParser.status(reply).get()
    }

    private func send(url: URL, headers: [String: String], body: Data) async throws -> Data {
        await AcoustIDRateGate.shared.wait()
        try Task.checkCancellation()
        do { return try await ScrobbleHTTP.send(http, url: url, method: "POST", headers: headers, body: body).data }
        catch let e as ScrobbleSendError { throw AcoustIDError.network(scrub(e.message)) }
    }

    /// Looks a fingerprint up. Retries once after a rate-limit answer; any other failure is returned as it is.
    func lookup(fingerprint: String, duration: Int) async throws -> [AcoustIDRecording] {
        guard let app = keys.applicationKey else { throw AcoustIDError.needsApplicationKey }
        var headers = ["Content-Type": "application/x-www-form-urlencoded", "Acoustid-App-Key": app]
        if let user = keys.activeUserKey { headers["Acoustid-User-Key"] = user }
        for attempt in 0..<2 {
            await AcoustIDRateGate.shared.wait()
            try Task.checkCancellation()
            let reply: (status: Int, data: Data)
            do { reply = try await ScrobbleHTTP.send(http, url: Self.endpoint, method: "POST", headers: headers, body: Self.body(fingerprint: fingerprint, duration: duration)) }
            catch let e as ScrobbleSendError { throw AcoustIDError.network(scrub(e.message)) }
            switch AcoustIDParser.lookup(reply.data) {
            case .success(let r): return r
            case .failure(.rateLimited) where attempt == 0: try await Task.sleep(nanoseconds: 1_000_000_000); continue
            case .failure(let e):
                if reply.status == 429 { throw AcoustIDError.rateLimited }
                throw e
            }
        }
        throw AcoustIDError.rateLimited
    }
}
