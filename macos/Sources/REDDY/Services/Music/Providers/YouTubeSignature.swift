import Foundation
import JavaScriptCore

// Makes YouTube streams that arrive with a `signatureCipher`, or with a throttling `n` parameter, playable.
//
// The signature and `n` transforms live in YouTube's player script (base.js). We download that script through MusicHTTP, cut out only the
// two small functions we need (see YouTubePlayerScript), and run them in a bare JavaScriptCore context with no host objects, no network and
// no timers. Inputs and outputs are plain strings, and nothing else from the page is ever evaluated.
//
// NOT VERIFIED AGAINST THE LIVE SCRIPT: no live check against the real YouTube player script has been done. The real script changes often, so
// the extraction patterns are best effort. When they stop matching, `playerScriptChanged` is reported, the failure is remembered for 30
// minutes so YouTube is not hammered, and the caller falls through to the other audio providers.

enum YouTubeSignatureError: Error, Equatable, Sendable {
    case playerScriptChanged
    case scriptTimedOut
    case scriptFailed(String)
    case badCipher
}

// MARK: pure URL layer

enum YouTubeSignature {
    struct Cipher: Equatable, Sendable { var s: String; var sp: String; var url: String }

    /// Splits a `signatureCipher` value (`s=...&sp=sig&url=...`, percent-encoded) into its parts. `sp` defaults to "signature".
    static func parseCipher(_ cipher: String) -> Cipher? {
        var s: String?, sp: String?, url: String?
        for pair in cipher.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            switch kv[0] {
            case "s": s = value
            case "sp": sp = value
            case "url": url = value
            default: break
            }
        }
        guard let s, !s.isEmpty, let url, url.hasPrefix("https://") || url.hasPrefix("http://") else { return nil }
        return Cipher(s: s, sp: (sp?.isEmpty == false ? sp : nil) ?? "signature", url: url)
    }

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? value
    }

    /// The `n` query value of a media URL, if any.
    static func nParameter(in url: String) -> String? {
        guard let r = url.range(of: #"[?&]n=[^&]*"#, options: .regularExpression) else { return nil }
        let v = String(url[r].dropFirst(3))
        return v.removingPercentEncoding ?? v
    }

    /// Replaces the `n` value (when one is present and a replacement is given) and appends the deciphered signature under its parameter name.
    static func rebuild(url: String, signatureParam: String?, signature: String?, n: String?) -> String {
        var out = url
        if let n, let r = out.range(of: #"([?&])n=[^&]*"#, options: .regularExpression) {
            let lead = out[r].first.map(String.init) ?? "&"
            out.replaceSubrange(r, with: lead + "n=" + encode(n))
        }
        if let signatureParam, let signature, !signature.isEmpty {
            // Remove a stale value first so the parameter appears once.
            out = out.replacingOccurrences(of: "[?&]" + NSRegularExpression.escapedPattern(for: signatureParam) + "=[^&]*", with: "", options: .regularExpression)
            out += (out.contains("?") ? "&" : "?") + signatureParam + "=" + encode(signature)
        }
        return out
    }
}

// MARK: sandboxed JavaScript

private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<String, Error>?
    init(_ c: CheckedContinuation<String, Error>) { cont = c }
    /// True for the first caller only, which also resumes the continuation.
    func finish(_ r: Result<String, Error>) -> Bool {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        guard let c else { return false }
        c.resume(with: r)
        return true
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func add(_ d: Int) { lock.lock(); n += d; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

enum YouTubeJSRunner {
    /// Threads still spinning in a script we gave up on. JavaScriptCore has no public way to interrupt a running script, so a runaway one is
    /// abandoned; after a few of them we stop starting new scripts rather than burn more CPU.
    private static let abandoned = Counter()
    static let maxAbandoned = 3
    static let maxResultLength = 4096

    /// Runs `program` in a fresh context, then evaluates `<function>(<argument>)` and returns the string it produced.
    static func call(program: String, function: String, argument: String, timeout: TimeInterval = 3) async throws -> String {
        guard function.range(of: "^[A-Za-z_$][A-Za-z0-9_$]*$", options: .regularExpression) != nil else { throw YouTubeSignatureError.scriptFailed("bad function name") }
        guard abandoned.value < maxAbandoned else { throw YouTubeSignatureError.scriptFailed("too many stuck scripts") }
        guard let literal = try? JSONSerialization.data(withJSONObject: argument, options: .fragmentsAllowed) else { throw YouTubeSignatureError.scriptFailed("bad argument") }
        let source = program + "\n;" + function + "(" + String(decoding: literal, as: UTF8.self) + ")"
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let gate = OneShot(cont)
            let thread = Thread {
                let result = evaluate(source)
                if !gate.finish(result) { abandoned.add(-1) }
            }
            thread.stackSize = 8 << 20
            thread.qualityOfService = .userInitiated
            thread.start()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                abandoned.add(1)
                if !gate.finish(.failure(YouTubeSignatureError.scriptTimedOut)) { abandoned.add(-1) }
            }
        }
    }

    private static func evaluate(_ source: String) -> Result<String, Error> {
        guard let ctx = JSContext() else { return .failure(YouTubeSignatureError.scriptFailed("no context")) }
        let value = ctx.evaluateScript(source)
        if let ex = ctx.exception { return .failure(YouTubeSignatureError.scriptFailed(ex.toString() ?? "script error")) }
        guard let value, value.isString, let text = value.toString(), text.utf16.count <= maxResultLength else {
            return .failure(YouTubeSignatureError.scriptFailed("unexpected result"))
        }
        return .success(text)
    }
}

// MARK: service

/// Fetches and caches the player script, extracts the two transforms, and turns ciphered or throttled URLs into playable ones.
actor YouTubeSignatureService {
    struct Plan: Equatable, Sendable {
        var hash: String
        var timestamp: Int
        var decipherJS: String
        var nJS: String?
    }

    private let http: MusicHTTP
    private let cacheDirectory: URL?
    private let failureTTL: TimeInterval
    private let planTTL: TimeInterval
    private let jsTimeout: TimeInterval
    private let now: @Sendable () -> Date

    private var plan: Plan?
    private var planAt: Date?
    private var failedUntil: Date?
    private var inflight: Task<Plan, Error>?
    private var nCache: [String: String] = [:]
    static let keptScripts = 3

    init(http: MusicHTTP = MusicHTTP(), cacheDirectory: URL? = YouTubeSignatureService.defaultCacheDirectory,
         failureTTL: TimeInterval = 30 * 60, planTTL: TimeInterval = 3 * 3600, jsTimeout: TimeInterval = 3,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http; self.cacheDirectory = cacheDirectory
        self.failureTTL = failureTTL; self.planTTL = planTTL; self.jsTimeout = jsTimeout; self.now = now
    }

    static var defaultCacheDirectory: URL? { MusicStorage.subfolder("youtube-player") }

    // MARK: public

    /// The timestamp already known, without any network call.
    func cachedTimestamp() -> Int? { plan?.timestamp }

    /// The timestamp to send in the InnerTube player request; nil when the script could not be read.
    func signatureTimestamp() async -> Int? { try? await currentPlan().timestamp }

    /// A playable URL for a format: the plain `url`, or the one rebuilt from `signatureCipher`. The `n` value is transformed in both cases.
    func playableURL(url: String?, cipher: String?) async throws -> String {
        if let cipher {
            guard let parts = YouTubeSignature.parseCipher(cipher) else { throw YouTubeSignatureError.badCipher }
            let p = try await currentPlan()
            let signature = try await YouTubeJSRunner.call(program: p.decipherJS, function: "__ytsig", argument: parts.s, timeout: jsTimeout)
            let n = await transformedN(in: parts.url, plan: p)
            return YouTubeSignature.rebuild(url: parts.url, signatureParam: parts.sp, signature: signature, n: n)
        }
        guard let url else { throw YouTubeSignatureError.badCipher }
        return await unthrottled(url)
    }

    /// Applies the `n` transform when the URL carries one. Never throws: on any failure the URL is returned unchanged.
    func unthrottled(_ url: String) async -> String {
        guard YouTubeSignature.nParameter(in: url) != nil, let p = try? await currentPlan() else { return url }
        guard let n = await transformedN(in: url, plan: p) else { return url }
        return YouTubeSignature.rebuild(url: url, signatureParam: nil, signature: nil, n: n)
    }

    // MARK: n transform

    private func transformedN(in url: String, plan p: Plan) async -> String? {
        guard let js = p.nJS, let n = YouTubeSignature.nParameter(in: url) else { return nil }
        let key = p.hash + ":" + n
        if let hit = nCache[key] { return hit }
        guard let out = try? await YouTubeJSRunner.call(program: js, function: "__ytn", argument: n, timeout: jsTimeout), !out.isEmpty,
              !out.hasPrefix("enhanced_except_") else { return nil }
        if nCache.count > 200 { nCache.removeAll() }
        nCache[key] = out
        return out
    }

    // MARK: plan

    /// Builds the plan from script text. Pure, so tests can feed a fixture. Throws `playerScriptChanged` when a required piece is missing.
    static func buildPlan(hash: String, script: String) throws -> Plan {
        guard let ts = YouTubePlayerScript.signatureTimestamp(in: script), let decipher = YouTubePlayerScript.extractDecipher(from: script) else {
            throw YouTubeSignatureError.playerScriptChanged
        }
        // The `n` transform is optional: without it streams still play, only throttled.
        return Plan(hash: hash, timestamp: ts, decipherJS: decipher, nJS: YouTubePlayerScript.extractNTransform(from: script))
    }

    func currentPlan() async throws -> Plan {
        if let until = failedUntil, until > now() { throw YouTubeSignatureError.playerScriptChanged }
        if let p = plan, let at = planAt, now().timeIntervalSince(at) < planTTL { return p }
        if let t = inflight { return try await t.value }
        let task = Task { try await self.loadPlan() }
        inflight = task
        defer { inflight = nil }
        do {
            let p = try await task.value
            plan = p; planAt = now(); failedUntil = nil
            return p
        } catch YouTubeSignatureError.playerScriptChanged {
            failedUntil = now().addingTimeInterval(failureTTL)
            throw YouTubeSignatureError.playerScriptChanged
        }
    }

    private func loadPlan() async throws -> Plan {
        let hash = try await discoverHash()
        let script = try await scriptText(hash: hash)
        return try Self.buildPlan(hash: hash, script: script)
    }

    private func discoverHash() async throws -> String {
        let headers = ["Accept-Language": "en-US,en;q=0.8"]
        if let u = URL(string: "https://www.youtube.com/iframe_api"),
           let data = try? await http.get(u, headers: headers), let text = String(data: data, encoding: .utf8),
           let h = YouTubePlayerScript.playerHash(inIframeAPI: text) { return h }
        guard let u = URL(string: "https://www.youtube.com/embed/jNQXAC9IVRw") else { throw YouTubeSignatureError.playerScriptChanged }
        let data = try await http.get(u, headers: headers)
        guard let text = String(data: data, encoding: .utf8), let path = YouTubePlayerScript.scriptPath(inPage: text),
              let h = YouTubePlayerScript.hash(fromScriptPath: path) else { throw YouTubeSignatureError.playerScriptChanged }
        return h
    }

    // MARK: script cache

    private func scriptText(hash: String) async throws -> String {
        if let dir = cacheDirectory, let d = try? Data(contentsOf: dir.appendingPathComponent(hash + ".js")), let s = String(data: d, encoding: .utf8), !s.isEmpty { return s }
        guard let url = YouTubePlayerScript.scriptURL(hash: hash) else { throw YouTubeSignatureError.playerScriptChanged }
        let data = try await http.get(url)
        guard let text = String(data: data, encoding: .utf8), text.utf8.count > 1000 else { throw YouTubeSignatureError.playerScriptChanged }
        store(data, hash: hash)
        return text
    }

    private func store(_ data: Data, hash: String) {
        guard let dir = cacheDirectory else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(hash + ".js"), options: .atomic)
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { $0.pathExtension == "js" }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.keptScripts) { try? fm.removeItem(at: url) }
    }
}
