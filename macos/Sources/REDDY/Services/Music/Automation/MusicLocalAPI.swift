import Foundation
import Network
import Security

// A control door for trusted programs on THIS Mac only: a tiny HTTP server on 127.0.0.1 (never reachable from the network). It is off until the person turns it on, every request
// needs the secret token, and what a request may do is limited by the "Local control" permissions. The command-line tool Scripts/streamsetu-ctl uses it.

@MainActor @Observable
final class MusicLocalAPI {
    static let shared = MusicLocalAPI()
    static let enabledKey = "music.automation.api.enabled"
    static let portKey = "music.automation.api.port"
    static let tokenAccount = "automation.api.token"
    static let defaultPort = 47600

    private(set) var running = false
    private(set) var lastError: String?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var store: any ScrobbleSecretStore = ScrobbleKeychainStore()
    @ObservationIgnored private weak var hub: MusicHub?

    var port: Int { let p = UserDefaults.standard.integer(forKey: Self.portKey); return (1024...65535).contains(p) ? p : Self.defaultPort }
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// The token, made on first use and kept in the Keychain. Shown only when the person asks to see it.
    var token: String {
        if let t = store.read(Self.tokenAccount), t.count >= 32 { return t }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let t = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        store.write(t, account: Self.tokenAccount)
        return t
    }
    func resetToken() { store.remove(Self.tokenAccount); if running { stop(); if let hub { start(hub: hub) } } }

    func setEnabled(_ on: Bool, hub: MusicHub) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start(hub: hub) } else { stop() }
    }

    func start(hub: MusicHub) {
        self.hub = hub
        guard isEnabled, listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: UInt16(port))!)
            l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.accept(c) } }
            l.stateUpdateHandler = { [weak self] st in
                Task { @MainActor in
                    switch st {
                    case .ready: self?.running = true; self?.lastError = nil
                    case .failed(let e): self?.running = false; self?.lastError = e.localizedDescription; self?.listener = nil
                    default: break
                    }
                }
            }
            l.start(queue: .main)
            listener = l
        } catch { lastError = error.localizedDescription }
    }

    func stop() { listener?.cancel(); listener = nil; running = false }

    private func accept(_ c: NWConnection) {
        // Only connections that come from this Mac.
        if case .hostPort(let host, _) = c.endpoint {
            let h = "\(host)"
            guard h.hasPrefix("127.") || h.hasPrefix("::1") || h.contains("localhost") else { c.cancel(); return }
        }
        c.start(queue: .main)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self, let data, let req = String(data: data, encoding: .utf8) else { c.cancel(); return }
                let reply = self.respond(to: req)
                c.send(content: reply, completion: .contentProcessed { _ in c.cancel() })
            }
        }
    }

    /// One request in, one reply out. Pure enough to test: `MusicLocalAPIRouter` does the parsing.
    func respond(to raw: String) -> Data {
        let req = MusicLocalAPIRouter.parse(raw)
        guard let req else { return MusicLocalAPIRouter.reply(400, ["error": "bad request"]) }
        guard MusicLocalAPIRouter.authorised(req, token: token) else { return MusicLocalAPIRouter.reply(401, ["error": "missing or wrong token"]) }
        guard let hub else { return MusicLocalAPIRouter.reply(503, ["error": "not ready"]) }
        switch (req.method, req.path) {
        case ("GET", "/v1/state"):
            let r = MusicAutomation.perform(MusicCommandCall(name: "nowPlaying"), from: .localAPI, hub: hub)
            return MusicLocalAPIRouter.reply(r.ok ? 200 : 403, r.ok ? r.data.merging(["message": r.message]) { a, _ in a } : ["error": r.message])
        case ("POST", "/v1/command"):
            guard let call = MusicLocalAPIRouter.call(from: req.body) else { return MusicLocalAPIRouter.reply(400, ["error": "send {\"name\":\"next\"}"]) }
            let r = MusicAutomation.perform(call, from: .localAPI, hub: hub)
            return MusicLocalAPIRouter.reply(r.ok ? 200 : 403, r.ok ? ["ok": "true", "message": r.message] : ["error": r.message])
        default: return MusicLocalAPIRouter.reply(404, ["error": "not found"])
        }
    }
}

enum MusicLocalAPIRouter {
    struct Request: Equatable { var method: String; var path: String; var headers: [String: String]; var body: String }

    static func parse(_ raw: String) -> Request? {
        let parts = raw.components(separatedBy: "\r\n\r\n")
        let lines = parts[0].components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ")
        guard let first, first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        return Request(method: String(first[0]).uppercased(), path: String(first[1]).components(separatedBy: "?")[0], headers: headers, body: parts.dropFirst().joined(separator: "\r\n\r\n"))
    }

    /// "Authorization: Bearer <token>", compared without leaking where it differs.
    static func authorised(_ r: Request, token: String) -> Bool {
        guard let h = r.headers["authorization"], h.hasPrefix("Bearer ") else { return false }
        let given = Array(h.dropFirst(7).utf8), want = Array(token.utf8)
        guard given.count == want.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(given, want) { diff |= a ^ b }
        return diff == 0
    }

    static func call(from body: String) -> MusicCommandCall? {
        guard let d = body.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let name = o["name"] as? String, name.count < 40 else { return nil }
        return MusicCommandCall(name: name, argument: (o["arg"] as? String).map { String($0.prefix(200)) } ?? (o["arg"] as? NSNumber)?.stringValue)
    }

    static func reply(_ code: Int, _ json: [String: String]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let status = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 503: "Service Unavailable"][code] ?? "OK"
        let head = "HTTP/1.1 \(code) \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
