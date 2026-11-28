import Foundation
import JavaScriptCore

// One JavaScriptCore context per plugin, confined to its own serial queue. A call goes in as (method, JSON array) and comes back as JSON, with a
// timeout and cancellation. The script only sees what `PluginHostAPIs` hands it; JavaScriptCore itself has no file, process or network access.

/// A JSValue is not Sendable; it is only ever touched on the host's queue, so carrying it in a box is safe.
private final class JSBox: @unchecked Sendable { let value: JSValue; init(_ v: JSValue) { value = v } }

final class MusicPluginHost: @unchecked Sendable {
    static let defaultTimeout: TimeInterval = 20
    static let maxResultBytes = 8 * 1024 * 1024

    let manifest: MusicPluginManifest
    let logs: PluginLogRing
    private let apis: PluginHostAPIs
    private let script: String
    private let queue: DispatchQueue
    private let errorSink: (@Sendable (String) -> Void)?

    // Queue-confined.
    private var context: JSContext?
    private var invoker: JSValue?
    private var loadFailure: String?

    // Lock-protected, so the timeout timer and cancellation work even when the script is stuck in a loop and the queue is blocked.
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var cancelledEarly = Set<Int>()
    private var nextID = 0
    private var retired = false
    private var lastErrorText: String?

    init(manifest: MusicPluginManifest, script: String, storageURL: URL, http: MusicHTTP? = nil, errorSink: (@Sendable (String) -> Void)? = nil) {
        self.manifest = manifest; self.script = script; self.errorSink = errorSink
        let ring = PluginLogRing(); logs = ring
        let transport: MusicHTTPTransport = http?.transport ?? PluginGuardedTransport(allowedHosts: manifest.permissions.networkHosts)
        var h = http ?? MusicHTTP(); h.transport = transport
        apis = PluginHostAPIs(manifest: manifest, storageURL: storageURL, http: h, logs: ring)
        queue = DispatchQueue(label: "streamsetu.music.plugin.\(manifest.id)", qos: .userInitiated)
    }

    var lastError: String? { lock.lock(); defer { lock.unlock() }; return lastErrorText }

    // MARK: calling

    func call(_ method: String, args: [any Sendable] = [], timeout: TimeInterval = MusicPluginHost.defaultTimeout) async throws -> Data {
        let json: Data
        do { json = try JSONSerialization.data(withJSONObject: args as [Any]) } catch { throw MusicError.plugin("arguments are not JSON") }
        return try await callRaw(method, argsJSON: String(decoding: json, as: UTF8.self), timeout: timeout)
    }

    /// `argsJSON` is a JSON array text. Returns the JSON text of whatever the plugin method resolved to (`null` for undefined).
    func callRaw(_ method: String, argsJSON: String, timeout: TimeInterval = MusicPluginHost.defaultTimeout) async throws -> Data {
        guard Self.isValidMethodName(method) else { throw MusicError.plugin("bad method name") }
        if Task.isCancelled { throw MusicError.cancelled }
        let id = takeID()
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                    guard register(id, cont) else { return }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.finish(id, .failure(MusicError.plugin("\(method) timed out after \(String(format: "%g", timeout)) seconds")), early: false)
                    }
                    queue.async { self.run(id, method, argsJSON) }
                }
            } onCancel: {
                self.finish(id, .failure(MusicError.cancelled), early: true)
            }
        } catch {
            if let e = error as? MusicError, case .plugin(let m) = e { noteError(m) }
            throw error
        }
    }

    /// Stops the context; pending calls fail as cancelled. The host cannot be used afterwards.
    func shutdown() {
        lock.lock(); retired = true; let all = pending; pending = [:]; lock.unlock()
        for (_, c) in all { c.resume(throwing: MusicError.cancelled) }
        queue.async { self.invoker = nil; self.context = nil }
    }

    /// Loads the script now (otherwise it loads on the first call) so a broken plugin shows its error at enable time.
    func preload() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.ensureLoaded(); cont.resume() } catch { cont.resume(throwing: error) }
            }
        }
    }

    // MARK: bookkeeping

    static func isValidMethodName(_ s: String) -> Bool {
        guard let f = s.utf8.first, (f >= 65 && f <= 90) || (f >= 97 && f <= 122), s.utf8.count <= 64 else { return false }
        return s.utf8.allSatisfy { ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95 }
    }
    private func takeID() -> Int { lock.lock(); defer { lock.unlock() }; nextID += 1; return nextID }
    private func register(_ id: Int, _ c: CheckedContinuation<Data, Error>) -> Bool {
        lock.lock()
        if retired { lock.unlock(); c.resume(throwing: MusicError.cancelled); return false }
        if cancelledEarly.remove(id) != nil { lock.unlock(); c.resume(throwing: MusicError.cancelled); return false }
        pending[id] = c; lock.unlock(); return true
    }
    private func isPending(_ id: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return pending[id] != nil }
    private func finish(_ id: Int, _ r: Result<Data, Error>, early: Bool) {
        lock.lock()
        let c = pending.removeValue(forKey: id)
        if c == nil, early { cancelledEarly.insert(id) }
        lock.unlock()
        c?.resume(with: r)
    }
    private func noteError(_ m: String) {
        lock.lock(); lastErrorText = m; lock.unlock()
        logs.append(level: "error", m)
        errorSink?(m)
    }

    // MARK: running (queue)

    private func run(_ id: Int, _ method: String, _ argsJSON: String) {
        guard isPending(id) else { return }
        do { try ensureLoaded() } catch { finish(id, .failure(error), early: false); return }
        guard let invoker else { finish(id, .failure(MusicError.plugin("plugin is not loaded")), early: false); return }
        invoker.call(withArguments: [id, method, argsJSON])
    }

    private func ensureLoaded() throws {
        if context != nil { return }
        if let f = loadFailure { throw MusicError.plugin(f) }
        func fail(_ m: String) -> MusicError { loadFailure = m; noteError(m); return MusicError.plugin(m) }
        guard let ctx = JSContext() else { throw fail("the script engine could not start") }
        let ring = logs
        // A custom handler replaces the default one that records `context.exception`, so record it here too or load errors go unseen.
        ctx.exceptionHandler = { c, e in c?.exception = e; ring.append(level: "error", "uncaught: " + (e?.toString() ?? "unknown")) }
        ctx.isInspectable = false
        ctx.name = "plugin.\(manifest.id)"

        let n = JSValue(newObjectIn: ctx)
        let apis = self.apis
        func put(_ name: String, _ block: Any) { n?.setValue(block, forProperty: name) }

        put("log", { (level: String, msg: String) in apis.log(level: level, message: msg) } as @convention(block) (String, String) -> Void)
        put("perms", { () -> String in apis.permissionsJSON } as @convention(block) () -> String)
        put("system", { () -> String in apis.systemJSON } as @convention(block) () -> String)
        put("storageGet", { (k: String) -> String? in apis.storageGet(k) } as @convention(block) (String) -> String?)
        put("storageSet", { (k: String, v: String) -> String? in apis.storageSet(k, v) } as @convention(block) (String, String) -> String?)
        put("storageRemove", { (k: String) -> String? in apis.storageRemove(k) } as @convention(block) (String) -> String?)
        put("secretGet", { (k: String) -> String? in apis.secretGet(k) } as @convention(block) (String) -> String?)
        put("secretSet", { (k: String, v: String) -> String? in apis.secretSet(k, v) } as @convention(block) (String, String) -> String?)
        put("secretRemove", { (k: String) -> String? in apis.secretRemove(k) } as @convention(block) (String) -> String?)
        put("crypto", { (op: String, data: String, key: String, inEnc: String, outEnc: String) -> String in
            apis.crypto(op: op, data: data, key: key, inEnc: inEnc, outEnc: outEnc)
        } as @convention(block) (String, String, String, String, String) -> String)
        put("fetch", { [weak self] (url: String, opts: String, resolve: JSValue, reject: JSValue) in
            let ok = JSBox(resolve), bad = JSBox(reject)
            let q = self?.queue
            apis.startFetch(url, optionsJSON: opts) { result in
                q?.async {
                    switch result {
                    case .success(let s): _ = ok.value.call(withArguments: [s])
                    case .failure(let e): _ = bad.value.call(withArguments: [e.message])
                    }
                }
            }
        } as @convention(block) (String, String, JSValue, JSValue) -> Void)
        put("done", { [weak self] (id: Int, json: String) in
            guard let self else { return }
            if json.utf8.count > Self.maxResultBytes { self.finish(id, .failure(MusicError.plugin("the plugin reply is too large")), early: false); return }
            self.finish(id, .success(Data(json.utf8)), early: false)
        } as @convention(block) (Int, String) -> Void)
        put("fail", { [weak self] (id: Int, message: String, kind: String) in
            guard let self else { return }
            self.finish(id, .failure(Self.mapFailure(message: message, kind: kind, pluginID: self.manifest.id)), early: false)
        } as @convention(block) (Int, String, String) -> Void)

        guard let factory = ctx.evaluateScript(Self.bootstrap), factory.isObject else { throw fail("the script engine could not be prepared") }
        guard let inv = factory.call(withArguments: [n as Any]), inv.isObject else { throw fail("the script engine could not be prepared") }

        ctx.exception = nil
        ctx.evaluateScript(script, withSourceURL: URL(string: "plugin:\(manifest.id)/\(manifest.entry)"))
        if let ex = ctx.exception { ctx.exception = nil; throw fail("the plugin failed to load: " + (ex.toString() ?? "script error")) }
        context = ctx; invoker = inv
    }

    private static func mapFailure(message: String, kind: String, pluginID: String) -> MusicError {
        let text = String(message.prefix(300))
        if kind == "nomethod" { return .unsupported(text) }
        let lower = text.lowercased()
        if lower.hasPrefix("notsignedin") { return .notSignedIn(pluginID) }
        if lower.hasPrefix("notfound") { return .notFound }
        if lower.hasPrefix("ratelimited") { return .rateLimited(retryAfter: nil) }
        return .plugin(text)
    }

    // MARK: the JavaScript wrapper
    // Runs once per context. It captures the native functions in a closure (so the plugin cannot reach them), freezes `host`, and returns `invoke`.

    private static let bootstrap = #"""
    (function (n) {
      "use strict";
      var g = globalThis;
      function chk(r) {
        if (typeof r === "string" && r.charCodeAt(0) === 0 && r.charAt(1) === "!") { throw new Error(r.slice(2)); }
        return r;
      }
      function fmt(a) {
        if (typeof a === "string") { return a; }
        try { var s = JSON.stringify(a); return s === undefined ? String(a) : s; } catch (e) { return String(a); }
      }
      function logger(level) {
        return function () {
          var parts = [];
          for (var i = 0; i < arguments.length; i++) { parts.push(fmt(arguments[i])); }
          n.log(level, parts.join(" "));
        };
      }
      var perms = JSON.parse(n.perms());
      var host = { apiVersion: 1, system: Object.freeze(JSON.parse(n.system())) };

      if (perms.network) {
        host.http = Object.freeze({
          fetch: function (url, opts) {
            return new Promise(function (resolve, reject) {
              n.fetch(String(url), JSON.stringify(opts || {}), function (raw) {
                try {
                  var r = JSON.parse(raw);
                  resolve(Object.freeze({
                    status: r.status, ok: r.status >= 200 && r.status < 300, url: r.url, headers: r.headers,
                    text: function () { return r.text === undefined ? "" : r.text; },
                    json: function () { return JSON.parse(r.text); },
                    base64: function () { return r.base64 === undefined ? "" : r.base64; }
                  }));
                } catch (e) { reject(e); }
              }, function (msg) { reject(new Error(msg)); });
            });
          }
        });
      }
      if (perms.storage) {
        host.storage = Object.freeze({
          get: function (k) { var v = chk(n.storageGet(String(k))); return (v === null || v === undefined) ? null : JSON.parse(v); },
          set: function (k, v) {
            var s = JSON.stringify(v);
            if (s === undefined) { throw new Error("value is not JSON"); }
            var e = n.storageSet(String(k), s); if (e) { chk(e); }
          },
          remove: function (k) { var e = n.storageRemove(String(k)); if (e) { chk(e); } },
          getSecret: function (k) { var v = chk(n.secretGet(String(k))); return (v === null || v === undefined) ? null : v; },
          setSecret: function (k, v) { var e = n.secretSet(String(k), String(v)); if (e) { chk(e); } },
          removeSecret: function (k) { var e = n.secretRemove(String(k)); if (e) { chk(e); } }
        });
      }
      if (perms.crypto) {
        var enc = function (o, which, d) { return (o && o[which]) || d; };
        var digest = function (op) { return function (data, o) { return chk(n.crypto(op, String(data), "", enc(o, "input", "utf8"), enc(o, "output", "hex"))); }; };
        host.crypto = Object.freeze({
          md5: digest("md5"), sha1: digest("sha1"), sha256: digest("sha256"),
          hmacSha256: function (key, data, o) { return chk(n.crypto("hmacSha256", String(data), String(key), enc(o, "input", "utf8"), enc(o, "output", "hex"))); },
          base64Encode: function (text) { return chk(n.crypto("b64enc", String(text), "", "utf8", "utf8")); },
          base64Decode: function (b64) { return chk(n.crypto("b64dec", String(b64), "", "utf8", "utf8")); },
          randomBytes: function (count, o) { return chk(n.crypto("random", String(count), "", "utf8", enc(o, "output", "hex"))); }
        });
      }
      Object.defineProperty(g, "host", { value: Object.freeze(host), writable: false, configurable: false });
      Object.defineProperty(g, "console", { value: Object.freeze({ log: logger("log"), info: logger("info"), warn: logger("warn"), error: logger("error"), debug: logger("debug") }), writable: false, configurable: false });

      return function invoke(id, method, argsJson) {
        try {
          var p = (typeof plugin === "undefined") ? null : plugin;
          if (p === null || typeof p !== "object" || typeof p[method] !== "function") { n.fail(id, "the plugin does not implement " + method, "nomethod"); return; }
          var args = JSON.parse(argsJson);
          Promise.resolve(p[method].apply(p, args)).then(
            function (v) { var s = (v === undefined) ? "null" : JSON.stringify(v); n.done(id, s === undefined ? "null" : s); },
            function (e) { n.fail(id, String((e && e.message) || e), "error"); }
          );
        } catch (e) { n.fail(id, String((e && e.message) || e), "error"); }
      };
    })
    """#
}
