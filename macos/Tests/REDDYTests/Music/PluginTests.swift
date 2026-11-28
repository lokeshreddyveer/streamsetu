import Testing
import Foundation
@testable import REDDY

// Plugin runtime tests: pure logic only. Network is a canned-reply stub, there is no audio, and temp folders are removed after each test.

private final class StubTransport: MusicHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requested: [URL] = []
    let body: String
    init(body: String = "{}") { self.body = body }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request.url)
        let url = request.url ?? URL(fileURLWithPath: "/")
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), resp)
    }
    private func record(_ u: URL?) { lock.lock(); if let u { requested.append(u) }; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requested.count }
}

private func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("plugintests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func manifest(id: String = "demo", caps: [MusicPluginCapability] = [.metadata], hosts: [String] = [], storage: Bool = false, crypto: Bool = false, signIn: Bool = false) -> MusicPluginManifest {
    MusicPluginManifest(id: id, name: "Demo", version: "1.0.0", author: "Test", summary: "A test plugin", capabilities: caps,
                        permissions: MusicPluginPermissions(networkHosts: hosts, storage: storage, crypto: crypto, signIn: signIn))
}

private func manifestJSON(id: String = "demo", apiVersion: Int = 1, extra: String = "") -> Data {
    Data("""
    {"id":"\(id)","name":"Demo","version":"1.0.0","author":"T","summary":"s","apiVersion":\(apiVersion),"entry":"main.js","capabilities":["metadata","audio"],
     "permissions":[{"name":"network","hosts":["api.example.com"]},"storage"\(extra)]}
    """.utf8)
}

private func makeHost(_ script: String, _ m: MusicPluginManifest, dir: URL, transport: MusicHTTPTransport? = nil) -> MusicPluginHost {
    var http: MusicHTTP? = nil
    if let transport { var h = MusicHTTP(); h.transport = transport; http = h }
    return MusicPluginHost(manifest: m, script: script, storageURL: dir.appendingPathComponent("s.json"), http: http)
}

/// Builds a zip with stored (uncompressed) entries, enough to exercise the reader.
private func zip(_ files: [(String, Data)]) -> Data {
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
    var out: [UInt8] = []; var central: [UInt8] = []
    for (name, data) in files {
        let nameBytes = Array(name.utf8); let crc = Int(MusicPluginZip.crc32([UInt8](data))); let offset = out.count
        out += le32(0x04034B50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc) + le32(data.count) + le32(data.count) + le16(nameBytes.count) + le16(0) + nameBytes + [UInt8](data)
        central += le32(0x02014B50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc) + le32(data.count) + le32(data.count)
            + le16(nameBytes.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + nameBytes
    }
    let cdOffset = out.count
    out += central
    out += le32(0x06054B50) + le16(0) + le16(0) + le16(files.count) + le16(files.count) + le32(central.count) + le32(cdOffset) + le16(0)
    return Data(out)
}

@Suite("Plugin manifest") struct PluginManifestTests {
    @Test func validManifestParses() throws {
        let m = try MusicPluginManifest.parse(manifestJSON())
        #expect(m.id == "demo" && m.capabilities == [.metadata, .audio])
        #expect(m.permissions.networkHosts == ["api.example.com"] && m.permissions.storage && !m.permissions.crypto)
        #expect(m.adapterIDs == ["demo", "demo.audio"])
    }
    @Test func badIDsAreRejected() {
        for id in ["Demo", "../evil", "a", "-x", "x-", "has space", "dot.id", String(repeating: "a", count: 49)] {
            #expect(throws: MusicError.self) { try MusicPluginManifest.parse(manifestJSON(id: id)) }
        }
    }
    @Test func badAPIVersionIsRejected() {
        #expect(throws: MusicError.self) { try MusicPluginManifest.parse(manifestJSON(apiVersion: 2)) }
        #expect(throws: MusicError.self) { try MusicPluginManifest.parse(manifestJSON(apiVersion: 0)) }
    }
    @Test func unknownPermissionAndBadHostsAreRejected() {
        #expect(throws: MusicError.self) { try MusicPluginManifest.parse(manifestJSON(extra: ",\"filesystem\"")) }
        for host in ["127.0.0.1", "localhost", "*", "*.com", "http://x.com", "a b.com", "EXAMPLE.com"] {
            #expect(!MusicPluginPolicy.isValidHostPattern(host), "\(host)")
        }
        #expect(MusicPluginPolicy.isValidHostPattern("*.example.com") && MusicPluginPolicy.isValidHostPattern("api.example.com"))
    }
    @Test func oversizePackageIsRejected() {
        let big = Data("{".utf8) + Data(repeating: 0x20, count: MusicPluginLimits.maxBundleBytes + 1)
        #expect(throws: MusicError.self) { try MusicPluginBundle.load(archive: big) }
        let hugeManifest = Data(repeating: 0x20, count: MusicPluginLimits.maxManifestBytes + 1)
        #expect(throws: MusicError.self) { try MusicPluginManifest.parse(hugeManifest) }
    }
}

@Suite("Plugin packages") struct PluginPackageTests {
    @Test func zipAndJSONBundleLoad() throws {
        let script = Data("var plugin = {};".utf8)
        let b = try MusicPluginBundle.load(archive: zip([("plugin.json", manifestJSON()), ("main.js", script)]))
        #expect(b.manifest.id == "demo" && b.script == "var plugin = {};")
        let obj: [String: Any] = ["manifest": try JSONSerialization.jsonObject(with: manifestJSON()), "files": ["main.js": script.base64EncodedString()]]
        let j = try MusicPluginBundle.load(archive: try JSONSerialization.data(withJSONObject: obj))
        #expect(j.manifest.id == "demo")
    }
    @Test func zipSlipAndTraversalAreRejected() {
        for bad in ["../evil.js", "/etc/passwd", "a/../../b.js", "..\\x.js", "C:/x.js", "a//b.js"] {
            let z = zip([("plugin.json", manifestJSON()), ("main.js", Data("x".utf8)), (bad, Data("x".utf8))])
            #expect(throws: MusicError.self, "\(bad)") { try MusicPluginBundle.load(archive: z) }
        }
        let obj: [String: Any] = ["manifest": (try? JSONSerialization.jsonObject(with: manifestJSON())) ?? [:], "files": ["main.js": "eA==", "../x": "eA=="]]
        #expect(throws: MusicError.self) { try MusicPluginBundle.load(archive: try JSONSerialization.data(withJSONObject: obj)) }
    }
    @Test func corruptZipIsRejected() {
        var z = [UInt8](zip([("plugin.json", manifestJSON()), ("main.js", Data("hello".utf8))]))
        if let i = z.firstIndex(of: UInt8(ascii: "h")) { z[i] = UInt8(ascii: "j") }
        #expect(throws: MusicError.self) { try MusicPluginBundle.load(archive: Data(z)) }
    }
    @Test func folderSymlinkOutsideIsRejected() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let outside = dir.appendingPathComponent("outside.js"); try Data("x".utf8).write(to: outside)
        let folder = dir.appendingPathComponent("p"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifestJSON().write(to: folder.appendingPathComponent("plugin.json"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("main.js"), withDestinationURL: outside)
        #expect(throws: MusicError.self) { try MusicPluginBundle.load(folder: folder) }
    }
}

@Suite("Plugin permissions") struct PluginPermissionTests {
    @Test func policyEnforcesSchemeHostPortAndCredentials() throws {
        let hosts = ["api.example.com", "*.cdn.example.org"]
        _ = try MusicPluginPolicy.validate(urlString: "https://api.example.com/x?q=1", allowedHosts: hosts)
        _ = try MusicPluginPolicy.validate(urlString: "https://a.cdn.example.org/x", allowedHosts: hosts)
        for bad in ["http://api.example.com/x", "https://evil.com/x", "https://cdn.example.org/x", "https://api.example.com.evil.com/", "https://api.example.com:8443/x",
                    "https://user:pw@api.example.com/x", "file:///etc/passwd", "ftp://api.example.com/", "not a url"] {
            #expect(throws: PluginMessageError.self, "\(bad)") { try MusicPluginPolicy.validate(urlString: bad, allowedHosts: hosts) }
        }
    }

    @Test func blockedHostAndHttpNeverReachTheTransport() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubTransport()
        let script = """
        var plugin = { async tryUrl(u) { try { await host.http.fetch(u); return "reached"; } catch (e) { return "blocked: " + e.message; } } };
        """
        let h = makeHost(script, manifest(hosts: ["api.example.com"]), dir: dir, transport: stub)
        for u in ["https://evil.com/", "http://api.example.com/"] {
            let out = String(decoding: try await h.call("tryUrl", args: [u]), as: UTF8.self)
            #expect(out.contains("blocked"), "\(u): \(out)")
        }
        #expect(stub.count == 0)
        let ok = String(decoding: try await h.call("tryUrl", args: ["https://api.example.com/ok"]), as: UTF8.self)
        #expect(ok.contains("reached") && stub.count == 1)
    }

    @Test func missingPermissionsRemoveTheAPIs() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let script = "var plugin = { async probe() { return [typeof host.http, typeof host.storage, typeof host.crypto, typeof host.system]; } };"
        let h = makeHost(script, manifest(), dir: dir)
        let out = String(decoding: try await h.call("probe"), as: UTF8.self)
        #expect(out == "[\"undefined\",\"undefined\",\"undefined\",\"object\"]")
    }

    @Test func oversizeResponseIsRefused() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let big = String(repeating: "a", count: MusicPluginPolicy.maxResponseBytes + 10)
        let script = "var plugin = { async go() { try { await host.http.fetch('https://api.example.com/'); return 'ok'; } catch (e) { return e.message; } } };"
        let h = makeHost(script, manifest(hosts: ["api.example.com"]), dir: dir, transport: StubTransport(body: big))
        let out = String(decoding: try await h.call("go"), as: UTF8.self)
        #expect(out.contains("larger than 5 MB"))
    }
}

@Suite("Plugin runtime") struct PluginRuntimeTests {
    static let searchScript = """
    var plugin = {
      async searchTracks(query, page) {
        var r = await host.http.fetch("https://api.example.com/search?q=" + encodeURIComponent(query));
        var data = r.json();
        return { items: data.results.map(function (x) { return { id: x.id, title: x.name, durationMs: x.ms, artists: [{ id: "a1", name: x.artist }],
                  thumbnails: [{ url: "https://img.example.com/1.jpg", width: 300, height: 300 }, { url: "http://insecure.example.com/2.jpg" }] }; }),
                 totalCount: 1, next: { kind: "page", page: 2, size: 30 } };
      }
    };
    """
    static let canned = #"{"results":[{"id":"t1","name":"Song One","ms":201000,"artist":"Band"}]}"#

    @Test func cannedSearchMapsThroughTheAdapter() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = manifest(hosts: ["api.example.com"])
        let host = makeHost(Self.searchScript, m, dir: dir, transport: StubTransport(body: Self.canned))
        let adapters = MusicPluginAdapters.make(manifest: m, host: host)
        let meta = try #require(adapters.first as? PluginMetadataAdapter)
        #expect(meta.info.kind == .plugin && meta.info.id == "demo")
        #expect(meta.info.privacyNote.contains("api.example.com"))
        let page = try await meta.searchTracks("hello world", page: nil)
        #expect(page.items.count == 1)
        let t = try #require(page.items.first)
        #expect(t.id == "t1" && t.providerID == "demo" && t.title == "Song One" && t.durationMs == 201000 && t.artistLine == "Band")
        #expect(t.thumbnails.map(\.url) == ["https://img.example.com/1.jpg"])
        #expect(page.next == .page(2, size: 30) && page.totalCount == 1)
    }

    @Test func secondaryCapabilitiesGetSuffixedIDs() {
        let m = manifest(caps: [.metadata, .audio, .lyrics, .scrobble], hosts: ["api.example.com"])
        let host = makeHost("var plugin = {};", m, dir: tempDir())
        let ids = MusicPluginAdapters.make(manifest: m, host: host).map(\.id)
        #expect(ids == ["demo", "demo.audio", "demo.lyrics", "demo.scrobble"])
    }

    @Test func missingMethodIsUnsupported() async throws {
        let host = makeHost("var plugin = {};", manifest(), dir: tempDir())
        await #expect(throws: MusicError.self) { _ = try await host.call("searchTracks", args: ["x", NSNull()]) }
        let meta = PluginMetadataAdapter(core: PluginAdapterCore(manifest: manifest(), host: host, capability: .metadata))
        do { _ = try await meta.featured(); Issue.record("expected unsupported") } catch let e as MusicError { #expect(e == .unsupported("the plugin does not implement featured")) }
    }

    @Test func thrownErrorsMapToTypedErrors() async throws {
        let script = "var plugin = { async a() { throw new Error('notSignedIn'); }, async b() { throw new Error('boom'); } };"
        let host = makeHost(script, manifest(), dir: tempDir())
        do { _ = try await host.call("a"); Issue.record("expected throw") } catch let e as MusicError { #expect(e == .notSignedIn("demo")) }
        do { _ = try await host.call("b"); Issue.record("expected throw") } catch let e as MusicError { #expect(e == .plugin("boom")) }
        #expect(host.lastError == "boom")
    }

    @Test func slowCallTimesOut() async throws {
        let host = makeHost("var plugin = { hang() { return new Promise(function () {}); }, quick() { return 7; } };", manifest(), dir: tempDir())
        let started = Date()
        do { _ = try await host.call("hang", timeout: 0.3); Issue.record("expected timeout") }
        catch let e as MusicError { if case .plugin(let m) = e { #expect(m.contains("timed out")) } else { Issue.record("wrong error \(e)") } }
        #expect(Date().timeIntervalSince(started) < 5)
        // The host stays usable after a timeout.
        #expect(String(decoding: try await host.call("quick"), as: UTF8.self) == "7")
    }

    @Test func cancellationStopsTheCall() async throws {
        let host = makeHost("var plugin = { hang() { return new Promise(function () {}); } };", manifest(), dir: tempDir())
        let task = Task { try await host.call("hang", timeout: 30) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; Issue.record("expected cancel") } catch let e as MusicError { #expect(e == .cancelled) }
    }

    @Test func storageRoundTripsAndEnforcesTheCap() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let script = """
        var plugin = {
          async save(v) { host.storage.set("k", v); return host.storage.get("k"); },
          async fill(n) { try { host.storage.set("big", "x".repeat(n)); return "stored"; } catch (e) { return e.message; } },
          async survives() { return host.storage.get("k"); }
        };
        """
        let m = manifest(storage: true)
        let h = makeHost(script, m, dir: dir)
        #expect(String(decoding: try await h.call("save", args: [["a": 1]]), as: UTF8.self) == "{\"a\":1}")
        let over = String(decoding: try await h.call("fill", args: [300 * 1024]), as: UTF8.self)
        #expect(over.contains("256 KB"))
        #expect(String(decoding: try await h.call("fill", args: [1000]), as: UTF8.self) == "\"stored\"")  // call() returns JSON text
        h.shutdown()
        let h2 = makeHost(script, m, dir: dir)
        #expect(String(decoding: try await h2.call("survives"), as: UTF8.self) == "{\"a\":1}")
    }

    @Test func cryptoHelpersWork() async throws {
        let script = """
        var plugin = { async go() { return [host.crypto.md5("abc"), host.crypto.sha1("abc"), host.crypto.sha256("abc"),
          host.crypto.hmacSha256("key", "The quick brown fox jumps over the lazy dog"), host.crypto.base64Encode("hi"), host.crypto.base64Decode("aGk="),
          host.crypto.randomBytes(8).length]; } };
        """
        let h = makeHost(script, manifest(crypto: true), dir: tempDir())
        let any = try JSONSerialization.jsonObject(with: try await h.call("go"))
        let a = try #require(any as? [Any])
        #expect(a[0] as? String == "900150983cd24fb0d6963f7d28e17f72")
        #expect(a[1] as? String == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(a[2] as? String == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(a[3] as? String == "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
        #expect(a[4] as? String == "aGk=" && a[5] as? String == "hi" && a[6] as? Int == 16)
    }

    @Test func consoleLogsGoToTheBoundedRing() async throws {
        let h = makeHost("var plugin = { async spam() { for (var i = 0; i < 500; i++) { console.log('line', i); } return 1; } };", manifest(), dir: tempDir())
        _ = try await h.call("spam")
        #expect(h.logs.entries.count == PluginLogRing.capacity)
        #expect(h.logs.entries.last?.message == "line 499")
    }

    @Test func scriptThatFailsToLoadReportsAnError() async {
        let h = makeHost("this is not javascript (", manifest(), dir: tempDir())
        do { try await h.preload(); Issue.record("expected failure") } catch let e as MusicError { if case .plugin = e {} else { Issue.record("wrong error") } } catch { Issue.record("wrong error") }
    }
}

@MainActor @Suite("Plugin manager") struct PluginManagerTests {
    private func registry() -> MusicRegistry { MusicRegistry(defaults: UserDefaults(suiteName: "plugintests-\(UUID().uuidString)") ?? .standard) }
    private func package() -> Data {
        zip([("plugin.json", manifestJSON()), ("main.js", Data("var plugin = { async genres() { return [{ id: 'g', name: 'Rock' }]; } };".utf8))])
    }

    @Test func installNeverEnablesAndEnableRegistersAdapters() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("demo.sbplugin"); try package().write(to: src)
        let reg = registry()
        let mgr = MusicPluginManager(registry: reg, directory: dir.appendingPathComponent("plugins"))
        let m = try mgr.install(from: src)
        #expect(m.id == "demo" && mgr.plugins.count == 1 && mgr.plugins[0].enabled == false)
        #expect(reg.all.isEmpty && !reg.isEnabled("demo"))
        mgr.setEnabled(true, id: "demo")
        #expect(reg.provider(id: "demo")?.info.kind == .plugin && reg.isEnabled("demo") && reg.provider(id: "demo.audio") != nil)
        let genres = try await reg.metadataProvider(id: "demo")?.genres()
        #expect(genres?.first?.name == "Rock")
        mgr.setEnabled(false, id: "demo")
        #expect(reg.all.isEmpty)
        mgr.remove(id: "demo")
        #expect(mgr.plugins.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("plugins/installed/demo").path))
    }

    @Test func enabledStateSurvivesRelaunch() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("demo.sbplugin"); try package().write(to: src)
        let pdir = dir.appendingPathComponent("plugins")
        let a = MusicPluginManager(registry: registry(), directory: pdir)
        try a.install(from: src); a.setEnabled(true, id: "demo")
        let reg2 = registry()
        let b = MusicPluginManager(registry: reg2, directory: pdir)
        #expect(b.plugins.first?.enabled == true && reg2.provider(id: "demo") != nil)
    }

    @Test func builtInIDsCannotBeTaken() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let z = zip([("plugin.json", manifestJSON(id: "spotify")), ("main.js", Data("var plugin = {};".utf8))])
        let src = dir.appendingPathComponent("x.sbplugin"); try z.write(to: src)
        let mgr = MusicPluginManager(registry: registry(), directory: dir.appendingPathComponent("plugins"))
        #expect(throws: MusicError.self) { try mgr.install(from: src) }
    }

    @Test func remoteInstallNeedsHTTPSAndConfirmation() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubTransport(body: String(decoding: JSONBundle.make(), as: UTF8.self))
        let mgr = MusicPluginManager(registry: registry(), directory: dir.appendingPathComponent("plugins"), transport: stub)
        await #expect(throws: MusicError.self) { try await mgr.install(fromRemote: URL(string: "http://example.com/p.sbplugin")!, confirm: { _ in true }) }
        #expect(stub.count == 0)
        var shown: MusicPluginManifest?
        await #expect(throws: MusicError.self) { try await mgr.install(fromRemote: URL(string: "https://example.com/p.sbplugin")!, confirm: { m in shown = m; return false }) }
        #expect(shown?.id == "demo" && mgr.plugins.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("plugins/installed/demo").path))
        let m = try await mgr.install(fromRemote: URL(string: "https://example.com/p.sbplugin")!, confirm: { _ in true })
        #expect(m.id == "demo" && mgr.plugins.count == 1 && mgr.plugins[0].enabled == false)
    }
}

private enum JSONBundle {
    static func make() -> Data {
        let obj: [String: Any] = ["manifest": (try? JSONSerialization.jsonObject(with: manifestJSON())) ?? [:], "files": ["main.js": Data("var plugin = {};".utf8).base64EncodedString()]]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }
}
