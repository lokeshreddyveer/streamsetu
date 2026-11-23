import Foundation
import Network

/// A tiny HTTP server on 127.0.0.1 inside the test process. The web view tests load these pages and never the real site.
final class ServiceFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fixture-server")
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var cookies: [String] = []
    private(set) var port: UInt16 = 0
    /// A short audio file served at /tone.wav and played by /media (made by the test).
    var media = Data()

    let isTLS: Bool
    init(tls: Bool = false) throws {
        isTLS = tls
        if tls {
            let params = try Self.tlsParameters()
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: params)
        } else { listener = try loopbackListener() }
    }

    /// A TLS server identity made on the spot: a self-signed certificate for 127.0.0.1, created with the system's openssl in a temporary folder, imported in memory only. No browser or system trusts it, which is the point.
    static func tlsParameters() throws -> NWParameters {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("netflix-tls-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func run(_ args: [String]) throws {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl"); p.arguments = args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw NSError(domain: "fixture", code: Int(p.terminationStatus)) }
        }
        let key = dir.appendingPathComponent("k.pem").path, cert = dir.appendingPathComponent("c.pem").path, p12 = dir.appendingPathComponent("i.p12").path
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=127.0.0.1"])
        try run(["pkcs12", "-export", "-out", p12, "-inkey", key, "-in", cert, "-passout", "pass:test"])
        var importOptions: [String: Any] = [kSecImportExportPassphrase as String: "test"]
        if #available(macOS 15, *) { importOptions[kSecImportToMemoryOnly as String] = true }          // nothing is added to a keychain
        var items: CFArray?
        let status = SecPKCS12Import(try Data(contentsOf: URL(fileURLWithPath: p12)) as CFData, importOptions as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first, let identityRef = first[kSecImportItemIdentity as String] else { throw NSError(domain: "fixture-import", code: Int(status)) }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, sec_identity_create(identityRef as! SecIdentity)!)
        return NWParameters(tls: options)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var done = false
            listener.stateUpdateHandler = { [weak self] s in
                guard let self, !done else { return }
                switch s {
                case .ready: done = true; self.port = self.listener.port?.rawValue ?? 0; k.resume()
                case .failed(let e): done = true; k.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
    func hits(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path] ?? 0 }
    var base: URL { URL(string: "\(isTLS ? "https" : "http")://127.0.0.1:\(port)")! }
    func url(_ path: String) -> URL { URL(string: "\(isTLS ? "https" : "http")://127.0.0.1:\(port)\(path)")! }
    /// The same server under a different host name, which the policy does not allow in the app.
    func otherHost(_ path: String) -> String { "http://localhost:\(port)\(path)" }
    /// The fixture's stand-in for the provider's regional page: the loopback name "localhost" (the site itself is 127.0.0.1), so the two hosts differ
    /// deterministically while one listener serves both. A test that expects the policy to cancel it asserts the page's hit count stays 0.
    func regionalHost(_ path: String) -> String { "http://localhost:\(port)\(path)" }
    /// A host no listener serves and no policy allows ("unexpected external"): it only ever appears in an address the policy cancels.
    func unexpectedHost(_ path: String) -> String { "http://unexpected.test:\(port)\(path)" }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        var buffer = Data()
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, err in
                guard let self else { return }
                if let data { buffer.append(data) }
                if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") { self.respond(text, c); return }
                if done || err != nil { c.cancel(); return }
                read()
            }
        }
        read()
    }

    private func hitCount(_ route: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[route] ?? 0 }
    private func query(_ path: String, _ name: String) -> String? {
        URLComponents(string: "http://x" + path)?.queryItems?.first { $0.name == name }?.value
    }

    private func html(_ body: String, title: String = "fixture") -> Data { Data("<!doctype html><html><head><title>\(title)</title></head><body>\(body)</body></html>".utf8) }

    private func respond(_ request: String, _ c: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let route = path.split(separator: "?").first.map(String.init) ?? path
        let cookie = lines.first { $0.lowercased().hasPrefix("cookie:") }?.dropFirst(7).trimmingCharacters(in: .whitespaces) ?? ""
        lock.lock(); counts[route, default: 0] += 1; lock.unlock()
        var status = 200, headers: [String: String] = ["Content-Type": "text/html; charset=utf-8", "Connection": "close"], body = html("ok", title: route), delay = 0.0
        switch route {
        case "/home": body = html("<p>home</p>", title: "home")
        case "/redirect": status = 302; headers["Location"] = "/home"; body = Data()
        case "/redirect-out": status = 302; headers["Location"] = otherHost("/elsewhere"); body = Data()
        // Path-aware region fixtures. The site is 127.0.0.1 and its own pages live under the whole segment /in; "/us", "/uk" are the per-country pages of
        // the same host. A cancelled hop means the next requests are never made (a test asserts hits stay 0).
        case "/": switch query(path, "to") {
            case "in": status = 302; headers["Location"] = "/in/home"; body = Data()
            case "us": status = 302; headers["Location"] = "/us"; body = Data()
            case "uk": status = 302; headers["Location"] = "/uk/home"; body = Data()
            default: body = html("<p>root</p>", title: "root")
            }
        case "/in/chain-a": status = 301; headers["Location"] = "/in/chain-b"; body = Data()
        case "/in/chain-b": status = 302; headers["Location"] = "/in/home"; body = Data()
        case "/in/to-root-in": status = 302; headers["Location"] = "/?to=in"; body = Data()
        case "/in/to-root-us": status = 302; headers["Location"] = "/?to=us"; body = Data()
        case "/in/to-root-uk": status = 302; headers["Location"] = "/?to=uk"; body = Data()
        case "/in/to-root-stable": status = 302; headers["Location"] = "/"; body = Data()
        case "/in/to-us": status = 302; headers["Location"] = "/us"; body = Data()
        case "/in/to-us-chain": status = 301; headers["Location"] = "/us"; body = Data()                    // the real chain continues to /us/next, never requested
        case "/us": status = 302; headers["Location"] = "/us/next"; body = Data()
        case "/in/to-india": status = 302; headers["Location"] = "/india"; body = Data()
        case "/in/to-inevil": status = 302; headers["Location"] = "/in.evil"; body = Data()
        case "/in/to-encoded": status = 302; headers["Location"] = "/%69n"; body = Data()
        case "/in/to-encoded-us": status = 302; headers["Location"] = "/%75s"; body = Data()
        case "/in/to-traversal": status = 302; headers["Location"] = "/in/../us"; body = Data()
        case "/in/to-doubleslash": status = 302; headers["Location"] = "http://127.0.0.1:\(port)//in"; body = Data()          // an empty first segment on the service's own host (a bare "//in" would be a host)
        case "/in/to-other-path": status = 302; headers["Location"] = "/sports/shows"; body = Data()
        case "/in/to-region-once": if hitCount(route) == 1 { status = 302; headers["Location"] = "/us" } else { status = 302; headers["Location"] = "/in/home" }; body = Data()
        case "/in/to-unexpected": status = 302; headers["Location"] = unexpectedHost("/x"); body = Data()
        case "/in/to-lookalike":
            let h = query(path, "h") ?? "evil.test"
            status = 302; headers["Location"] = "http://\(h):\(port)/us"; body = Data()
        case "/in/idle-to-us": body = html("<script>setTimeout(function(){location.href='/us'},600)</script><p>idle</p>", title: "idle-to-us")
        case "/in/idle-link-us": body = html("<a id=\"r\" href=\"/us\">r</a>", title: "idle-link-us")
        case "/in/idle-link-other": body = html("<a id=\"r\" href=\"/sports/shows\">r</a>", title: "idle-link-other")
        case "/in/500": status = 500; body = html("broken", title: "500")
        case "/404": status = 404; body = html("not found", title: "404")
        case "/500": status = 500; body = html("broken", title: "500")
        case "/slow": delay = 1.5; body = html("slow", title: "slow")
        case "/popup": body = html("<a id=\"l\" target=\"_blank\" href=\"/home\">open</a><a id=\"x\" target=\"_blank\" href=\"\(otherHost("/popped"))\">out</a>", title: "popup")
        case "/links": body = html("<a id=\"mail\" href=\"mailto:someone@example.com\">m</a><a id=\"ext\" href=\"\(otherHost("/ext"))\">e</a><a id=\"custom\" href=\"myapp://open\">c</a><a id=\"in\" href=\"/home\">i</a>", title: "links")
        case "/download": headers["Content-Type"] = "text/plain"; headers["Content-Disposition"] = "attachment; filename=\"a.txt\""; body = Data("file".utf8)
        case "/zip": headers["Content-Type"] = "application/zip"; body = Data(repeating: 0, count: 64)
        case "/cookie-set": headers["Set-Cookie"] = "sid=abc123; Max-Age=3600; Path=/"; body = html("set", title: "set")
        case "/cookie-echo": body = html("<p id=\"c\">\(cookie)</p>", title: "cookie:" + cookie)
        case "/media": body = html("<audio id=\"a\" src=\"/tone.wav\" loop></audio>", title: "media")
        case "/media-replay": body = html("<audio id=\"a\" src=\"/tone.wav\" loop></audio><script>setInterval(function(){document.getElementById('a').play().catch(function(){})},150)</script>", title: "media-replay")          // a page that keeps asking to play, like autoplay-next or a retried play
        case "/tone.wav": headers["Content-Type"] = "audio/wav"; body = media
        case "/a", "/b", "/c": body = html("<p>\(route)</p>", title: route)
        default: break
        }
        let head = "HTTP/1.1 \(status) X\r\n" + headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\nContent-Length: \(body.count)\r\n\r\n"
        let send = { c.send(content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() }) }
        if delay > 0 { queue.asyncAfter(deadline: .now() + delay, execute: send) } else { send() }
    }

    /// A port with nothing listening on it (connection refused), standing in for "the site cannot be reached".
    static func unreachablePort() throws -> UInt16 {
        let l = try loopbackListener()
        l.newConnectionHandler = { $0.cancel() }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var port: UInt16 = 0
        l.stateUpdateHandler = { if case .ready = $0 { port = l.port?.rawValue ?? 0; sem.signal() } }
        l.start(queue: .global())
        sem.wait(); l.cancel()
        Thread.sleep(forTimeInterval: 0.2)
        return port
    }
}
typealias NetflixFixtureServer = ServiceFixtureServer

/// Reads the app's own source files for the source-scan tests.
enum ServiceSources {
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/REDDY") }
    /// Every Swift file under the given folders (relative to Sources/REDDY), minus the named files.
    static func text(_ dirs: [String], excluding: Set<String> = []) throws -> String {
        var out = ""
        for d in dirs {
            let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(d).path).filter { $0.hasSuffix(".swift") && !excluding.contains($0) }.sorted()
            for f in files { out += try String(contentsOf: root.appendingPathComponent(d).appendingPathComponent(f), encoding: .utf8) + "\n" }
        }
        return out
    }
    /// What runs a service's web view: the runtime and session code (the test-only store provider is excluded).
    static func runtime() throws -> String {
        try text(["Services/Streaming/Runtime", "Services/Streaming/Session", "Features/Netflix"], excluding: ["TestIsolatedDataStoreProvider.swift"])
    }
}
