import Foundation
#if canImport(WebKit)
import WebKit
#endif

// Turning a ciphered or throttled stream URL into a playable one.
//
// Two paths, tried in this order:
//  1. Community registries of per-player entry points (the player hash maps to a signature call template and the name of the class that
//     runs the `n` transform). They are fetched only when playback needs them, merged, cached on disk, and every entry is checked against
//     strict shapes before use, because the values end up inside JavaScript that runs in a web view. This path is switched by a setting
//     that is ON by default.
//  2. Our own extraction from the player script (`YouTubeSignatureService`), which also stays as the fallback when the registry path
//     fails for any reason.
// Neither path has been checked against the live player script from here; both fail closed (the caller moves to the next client).

enum YouTubeMusicSettings {
    static let useCipherRegistryKey = "music.ytmusic.useCipherRegistry"
    /// Default ON: when the key was never written the registry path is used.
    static func useCipherRegistry(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: useCipherRegistryKey) == nil ? true : defaults.bool(forKey: useCipherRegistryKey)
    }
    static func setUseCipherRegistry(_ on: Bool, defaults: UserDefaults = .standard) { defaults.set(on, forKey: useCipherRegistryKey) }
}

struct YTMCipherEntry: Sendable, Equatable { var sig: String; var nClass: String; var sts: Int? }

actor YouTubeCipherRegistry {
    static let sources: [URL] = [
        "https://raw.githubusercontent.com/ZemerTeam/zemer-cipher/master/library/src/main/assets/player_configs.json",
        "https://raw.githubusercontent.com/MetrolistGroup/faraday/master/registry/player_configs.json"
    ].compactMap(URL.init(string:))

    private let http: MusicHTTP
    private let cacheFile: URL?
    private let minRefreshGap: TimeInterval
    private let now: @Sendable () -> Date
    private var table: [String: YTMCipherEntry] = [:]
    private var loadedDisk = false
    private var lastRefresh: Date?

    init(http: MusicHTTP = MusicHTTP(), cacheFile: URL? = YouTubeCipherRegistry.defaultCacheFile, minRefreshGap: TimeInterval = 300,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http; self.cacheFile = cacheFile; self.minRefreshGap = minRefreshGap; self.now = now
    }

    static var defaultCacheFile: URL? { MusicStorage.subfolder("youtube-player").appendingPathComponent("player_configs.json") }

    // MARK: validation (a security control: values reach executed JavaScript)

    static func validHash(_ s: String) -> Bool { s.range(of: "^[0-9a-f]{8}$", options: .regularExpression) != nil }
    static func validSig(_ s: String) -> Bool { s.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]{0,7}\(\d{1,6},\d{1,6},INPUT\)$"#, options: .regularExpression) != nil }
    static func validClass(_ s: String) -> Bool { s.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]{0,7}$"#, options: .regularExpression) != nil }

    /// Keeps only entries whose hash, signature template and class name pass the strict shapes. Aliases map to the same entry.
    static func parse(_ data: Data) -> [String: YTMCipherEntry] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let players = root["players"] as? [String: Any] else { return [:] }
        var out: [String: YTMCipherEntry] = [:]
        for (hash, raw) in players {
            guard validHash(hash), let e = raw as? [String: Any], let sig = e["sig"] as? String, validSig(sig),
                  let cls = e["nClass"] as? String, validClass(cls) else { continue }
            let sts = (e["sts"] as? Int) ?? (e["sts"] as? String).flatMap(Int.init)
            let entry = YTMCipherEntry(sig: sig, nClass: cls, sts: sts.flatMap { $0 >= 1000 ? $0 : nil })
            out[hash] = entry
            for alias in (e["aliases"] as? [String]) ?? [] where validHash(alias) { out[alias] = entry }
        }
        return out
    }

    // MARK: lookup

    /// The entry for a player hash. Reads the disk cache first; fetches the registries only when the hash is unknown and the last fetch
    /// is older than the refresh gap.
    func entry(forHash hash: String) async -> YTMCipherEntry? {
        guard Self.validHash(hash) else { return nil }
        loadDiskIfNeeded()
        if let e = table[hash] { return e }
        await refresh()
        return table[hash]
    }

    /// Fetches both registries (later one wins ties), merges into the table and writes the cache. Returns true when anything changed.
    @discardableResult
    func refresh(force: Bool = false) async -> Bool {
        if !force, let l = lastRefresh, now().timeIntervalSince(l) < minRefreshGap { return false }
        lastRefresh = now()
        var merged = table
        for url in Self.sources {
            guard let d = try? await http.get(url) else { continue }
            for (k, v) in Self.parse(d) { merged[k] = v }
        }
        guard merged != table else { return false }
        table = merged
        persist()
        return true
    }

    private func loadDiskIfNeeded() {
        guard !loadedDisk else { return }
        loadedDisk = true
        if let f = cacheFile, let d = try? Data(contentsOf: f) { table = Self.parse(d) }
    }

    private func persist() {
        guard let f = cacheFile else { return }
        var players: [String: Any] = [:]
        for (h, e) in table {
            var o: [String: Any] = ["sig": e.sig, "nClass": e.nClass]
            if let s = e.sts { o["sts"] = s }
            players[h] = o
        }
        guard let d = try? JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "players": players]) else { return }
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: f, options: .atomic)
    }
}

// MARK: running the player

/// Evaluates the player's own functions. The built-in implementation uses a hidden web view; tests inject a stub.
protocol YTMCipherRunner: Sendable {
    func prepare(script: String, entry: YTMCipherEntry, key: String) async throws
    func decipher(_ scrambled: String) async throws -> String
    func transformN(_ value: String) async throws -> String
    func teardown() async
}

enum YTMCipherRunnerError: Error { case unavailable, loadFailed, exportsMissing, timedOut }

enum YTMPlayerExports {
    /// Inserts export code immediately before the final `})(_yt_player);` so it lives inside the player's closure; appends if that marker is absent.
    static func inject(into script: String, entry: YTMCipherEntry) -> String {
        let code = """
        ;window.__ytmSig=function(INPUT){return \(entry.sig)};
        window.__ytmN=function(v){try{var K=(typeof g!=="undefined"&&typeof g.\(entry.nClass)==="function")?g.\(entry.nClass):\(entry.nClass);var u=new K("https://x.googlevideo.com/videoplayback?n="+encodeURIComponent(v),true);return u.get("n")||v}catch(e){return v}};
        """
        // The main player script ends with the closure call below; the TV variant ends with `.call(this)`.
        for marker in ["})(_yt_player);", "}).call(this);"] {
            if let r = script.range(of: marker, options: .backwards) {
                var s = script
                s.insert(contentsOf: code, at: r.lowerBound)
                return s
            }
        }
        return script + "\n" + code
    }
}

#if canImport(WebKit)
@MainActor private final class YTMWebHost: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var loadWaiter: CheckedContinuation<Void, Error>?
    private(set) var preparedKey: String?
    private var lastUse = Date()

    private func ensureWeb() async throws -> WKWebView {
        if let web { return web }
        let w = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        w.navigationDelegate = self
        web = w
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loadWaiter = c
            w.loadHTMLString("<html><body></body></html>", baseURL: URL(string: "https://www.youtube.com/"))
        }
        return w
    }

    func prepare(script: String, entry: YTMCipherEntry, key: String) async throws {
        if preparedKey == key, web != nil { lastUse = Date(); return }
        teardown()
        let w = try await ensureWeb()
        _ = try await w.evaluateJavaScript("var _yt_player={};" + YTMPlayerExports.inject(into: script, entry: entry))
        // Prove the exports work: n must change a probe string into another URL-safe string, and the signature call must answer with a string.
        let n = try await w.evaluateJavaScript("window.__ytmN('ytmProbe0123456789')") as? String
        let sig = try? await w.evaluateJavaScript("window.__ytmSig('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')") as? String
        let nWorks = n.map { $0 != "ytmProbe0123456789" && $0.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil } ?? false
        guard nWorks || sig != nil else { teardown(); throw YTMCipherRunnerError.exportsMissing }
        preparedKey = key
        lastUse = Date()
    }

    func call(_ fn: String, _ arg: String) async throws -> String {
        guard let w = web, preparedKey != nil,
              let lit = try? JSONSerialization.data(withJSONObject: arg, options: .fragmentsAllowed) else { throw YTMCipherRunnerError.unavailable }
        lastUse = Date()
        guard let out = try await w.evaluateJavaScript("window.\(fn)(\(String(decoding: lit, as: UTF8.self)))") as? String else { throw YTMCipherRunnerError.exportsMissing }
        return out
    }

    func idleFor() -> TimeInterval { Date().timeIntervalSince(lastUse) }

    func teardown() {
        web?.navigationDelegate = nil
        web = nil; preparedKey = nil
        loadWaiter?.resume(throwing: YTMCipherRunnerError.loadFailed); loadWaiter = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.loadWaiter?.resume(); self.loadWaiter = nil }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.loadWaiter?.resume(throwing: error); self.loadWaiter = nil }
    }
}

/// Hidden web view runner. Built on demand, torn down after ten idle minutes. Per-call timeout 5 s, load and prepare 15 s.
final class YTMWebViewCipherRunner: YTMCipherRunner, @unchecked Sendable {
    private let host = MainActorBox()
    private final class MainActorBox: @unchecked Sendable {
        @MainActor lazy var value = YTMWebHost()
    }
    init() {}

    func prepare(script: String, entry: YTMCipherEntry, key: String) async throws {
        let h = host
        try await ytmWithTimeout(15) { try await h.value.prepare(script: script, entry: entry, key: key) }
        scheduleIdleTeardown()
    }
    func decipher(_ scrambled: String) async throws -> String {
        let h = host
        return try await ytmWithTimeout(5) { try await h.value.call("__ytmSig", scrambled) }
    }
    func transformN(_ value: String) async throws -> String {
        let h = host
        return try await ytmWithTimeout(5) { try await h.value.call("__ytmN", value) }
    }
    func teardown() async { let h = host; await MainActor.run { h.value.teardown() } }

    private func scheduleIdleTeardown() {
        let h = host
        Task { @MainActor in
            while true {
                try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                if h.value.preparedKey == nil { return }
                if h.value.idleFor() > 600 { h.value.teardown(); return }
            }
        }
    }
}
#endif

// MARK: solver

/// Gives the stream resolver one place to ask for a signature timestamp and playable URLs, whichever path can serve them.
actor YTMStreamURLSolver {
    private let http: MusicHTTP
    private let registry: YouTubeCipherRegistry
    private let signature: YouTubeSignatureService
    private let runner: YTMCipherRunner?
    private let useRegistry: @Sendable () -> Bool
    private let cacheDirectory: URL?
    private let now: @Sendable () -> Date
    private var currentHash: (hash: String, at: Date)?
    private var prepared: String?
    private var lastHeal: Date?
    private var derivedEntries: [String: YTMCipherEntry] = [:]
    private static let hashTTL: TimeInterval = 15 * 60
    private static let scriptTTL: TimeInterval = 6 * 3600

    init(http: MusicHTTP = MusicHTTP(), registry: YouTubeCipherRegistry? = nil, signature: YouTubeSignatureService? = nil, runner: YTMCipherRunner? = nil,
         useRegistry: @escaping @Sendable () -> Bool = { YouTubeMusicSettings.useCipherRegistry() },
         cacheDirectory: URL? = YouTubeSignatureService.defaultCacheDirectory, now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http
        self.registry = registry ?? YouTubeCipherRegistry(http: http)
        self.signature = signature ?? YouTubeSignatureService(http: http)
        #if canImport(WebKit)
        self.runner = runner ?? YTMWebViewCipherRunner()
        #else
        self.runner = runner
        #endif
        self.useRegistry = useRegistry; self.cacheDirectory = cacheDirectory; self.now = now
    }

    // MARK: timestamp

    func signatureTimestamp() async -> Int? {
        if useRegistry(), let h = await playerHash(), let e = await registry.entry(forHash: h), let sts = e.sts { return sts }
        return await signature.signatureTimestamp()
    }

    // MARK: URLs

    /// Plain URL with the `n` value transformed, or a ciphered one rebuilt with its deciphered signature.
    func playableURL(url: String?, cipher: String?) async throws -> String {
        if useRegistry(), let viaRegistry = try? await registryURL(url: url, cipher: cipher) { return viaRegistry }
        return try await signature.playableURL(url: url, cipher: cipher)
    }

    /// Transforms a bare `n` value (used for live manifest paths). Returns the input when nothing could transform it.
    func transformN(_ value: String) async -> String {
        let probe = "https://x.googlevideo.com/videoplayback?n=" + YouTubeSignature.encode(value)
        let out = try? await playableURL(url: probe, cipher: nil)
        return out.flatMap { YouTubeSignature.nParameter(in: $0) } ?? value
    }

    /// After a deciphered URL was rejected: forget the current player, drop cached scripts and refresh the registries. At most once per 5 minutes.
    func selfHeal() async {
        if let l = lastHeal, now().timeIntervalSince(l) < 300 { return }
        lastHeal = now()
        currentHash = nil; prepared = nil
        if let dir = cacheDirectory, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files where f.lastPathComponent.hasPrefix("ytm_player_") { try? FileManager.default.removeItem(at: f) }
        }
        await runner?.teardown()
        await registry.refresh(force: true)
    }

    // MARK: registry path

    private func playerHash() async -> String? {
        if let c = currentHash, now().timeIntervalSince(c.at) < Self.hashTTL { return c.hash }
        guard let u = URL(string: "https://www.youtube.com/iframe_api"),
              let d = try? await http.get(u, headers: ["Accept-Language": "en-US,en;q=0.8"]), let text = String(data: d, encoding: .utf8),
              let h = YouTubePlayerScript.playerHash(inIframeAPI: text), YouTubeCipherRegistry.validHash(h) else { return nil }
        currentHash = (h, now())
        return h
    }

    private func script(hash: String) async -> String? {
        let file = cacheDirectory?.appendingPathComponent("ytm_player_\(hash).js")
        if let file, let attrs = try? FileManager.default.attributesOfItem(atPath: file.path), let m = attrs[.modificationDate] as? Date,
           now().timeIntervalSince(m) < Self.scriptTTL, let d = try? Data(contentsOf: file), let s = String(data: d, encoding: .utf8), !s.isEmpty { return s }
        guard let url = YouTubePlayerScript.scriptURL(hash: hash), let d = try? await http.get(url), d.count > 1000, let s = String(data: d, encoding: .utf8) else { return nil }
        if let file {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: file, options: .atomic)
        }
        return s
    }

    private func registryURL(url: String?, cipher: String?) async throws -> String {
        guard let runner, let hash = await playerHash() else { throw YTMCipherRunnerError.unavailable }
        var found = await registry.entry(forHash: hash) ?? derivedEntries[hash]
        // A player the registries do not know yet: find the entry points in the script itself.
        if found == nil, let s = await script(hash: hash), let e = YouTubeEntryExtractor.entry(fromScript: s) { derivedEntries[hash] = e; found = e }
        guard let entry = found else { throw YTMCipherRunnerError.unavailable }
        if prepared != hash {
            guard let s = await script(hash: hash) else { throw YTMCipherRunnerError.loadFailed }
            try await runner.prepare(script: s, entry: entry, key: hash)
            prepared = hash
        }
        if let cipher {
            guard let parts = YouTubeSignature.parseCipher(cipher) else { throw YouTubeSignatureError.badCipher }
            let sig = try await runner.decipher(parts.s)
            var n: String?
            if let nv = YouTubeSignature.nParameter(in: parts.url) { n = try? await runner.transformN(nv) }
            return YouTubeSignature.rebuild(url: parts.url, signatureParam: parts.sp, signature: sig, n: n)
        }
        guard let url else { throw YouTubeSignatureError.badCipher }
        guard let nv = YouTubeSignature.nParameter(in: url) else { return url }
        let n = try await runner.transformN(nv)
        return YouTubeSignature.rebuild(url: url, signatureParam: nil, signature: nil, n: n == nv ? nil : n)
    }
}
