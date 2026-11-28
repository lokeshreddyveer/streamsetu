import Foundation
import Compression

// The plugin package format: `plugin.json` + one script. This file holds the manifest model, every validation rule, and the readers that turn
// a folder, a `.sbplugin` zip or a JSON bundle into a checked `MusicPluginBundle`. Nothing here runs plugin code or touches the network.

enum MusicPluginLimits {
    /// Whole package, compressed or not.
    static let maxBundleBytes = 5 * 1024 * 1024
    static let maxManifestBytes = 64 * 1024
    static let maxScriptBytes = 4 * 1024 * 1024
    static let maxArchiveEntries = 256
    static let supportedAPIVersion = 1
    static let manifestFileName = "plugin.json"
}

enum MusicPluginCapability: String, Codable, CaseIterable, Sendable { case metadata, audio, lyrics, scrobble }

/// What a plugin may do besides pure computation. Everything not listed is refused by the host.
struct MusicPluginPermissions: Codable, Hashable, Sendable {
    /// Exact host names, or `*.example.com` for subdomains. Empty means no network at all.
    var networkHosts: [String] = []
    var storage = false
    var crypto = false
    var signIn = false
    var network: Bool { !networkHosts.isEmpty }

    init(networkHosts: [String] = [], storage: Bool = false, crypto: Bool = false, signIn: Bool = false) {
        self.networkHosts = networkHosts; self.storage = storage; self.crypto = crypto; self.signIn = signIn
    }

    // On disk: a list whose items are either a plain name ("storage") or an object ({"name": "network", "hosts": [...]}).
    private struct Item: Codable {
        var name: String; var hosts: [String]?
        init(name: String, hosts: [String]? = nil) { self.name = name; self.hosts = hosts }
        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer().decode(String.self) { name = single; hosts = nil; return }
            let c = try decoder.container(keyedBy: Keys.self)
            name = try c.decode(String.self, forKey: .name); hosts = try c.decodeIfPresent([String].self, forKey: .hosts)
        }
        enum Keys: String, CodingKey { case name, hosts }
        func encode(to encoder: Encoder) throws {
            if hosts == nil { var c = encoder.singleValueContainer(); try c.encode(name); return }
            var c = encoder.container(keyedBy: Keys.self); try c.encode(name, forKey: .name); try c.encode(hosts, forKey: .hosts)
        }
    }

    init(from decoder: Decoder) throws {
        let items = try [Item](from: decoder)
        for item in items {
            switch item.name {
            case "network": networkHosts += (item.hosts ?? []).map { $0.lowercased() }
            case "storage": storage = true
            case "crypto": crypto = true
            case "signIn": signIn = true
            default: throw MusicError.plugin("unknown permission \"\(item.name)\"")
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var items: [Item] = []
        if network { items.append(Item(name: "network", hosts: networkHosts)) }
        if storage { items.append(Item(name: "storage")) }
        if crypto { items.append(Item(name: "crypto")) }
        if signIn { items.append(Item(name: "signIn")) }
        try items.encode(to: encoder)
    }
}

struct MusicPluginManifest: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var version: String
    var author: String = ""
    var summary: String = ""
    var apiVersion: Int
    var entry: String = "main.js"
    var capabilities: [MusicPluginCapability]
    var permissions = MusicPluginPermissions()
    var homepage: String? = nil

    private enum Keys: String, CodingKey { case id, name, version, author, summary, apiVersion, entry, capabilities, permissions, homepage }

    init(id: String, name: String, version: String, author: String = "", summary: String = "", apiVersion: Int = 1, entry: String = "main.js",
         capabilities: [MusicPluginCapability], permissions: MusicPluginPermissions = .init(), homepage: String? = nil) {
        self.id = id; self.name = name; self.version = version; self.author = author; self.summary = summary; self.apiVersion = apiVersion
        self.entry = entry; self.capabilities = capabilities; self.permissions = permissions; self.homepage = homepage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        apiVersion = try c.decode(Int.self, forKey: .apiVersion)
        entry = try c.decodeIfPresent(String.self, forKey: .entry) ?? "main.js"
        capabilities = try c.decode([MusicPluginCapability].self, forKey: .capabilities)
        permissions = try c.decodeIfPresent(MusicPluginPermissions.self, forKey: .permissions) ?? .init()
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
    }

    // MARK: validation

    /// Parses and validates `plugin.json`. Throws `MusicError.plugin` with a message fit to show the person.
    static func parse(_ data: Data) throws -> MusicPluginManifest {
        guard data.count <= MusicPluginLimits.maxManifestBytes else { throw MusicError.plugin("plugin.json is too large") }
        let m: MusicPluginManifest
        do { m = try JSONDecoder().decode(MusicPluginManifest.self, from: data) }
        catch let e as MusicError { throw e }
        catch { throw MusicError.plugin("plugin.json is not valid (missing or malformed fields)") }
        try m.validate()
        return m
    }

    func validate() throws {
        guard Self.isValidID(id) else { throw MusicError.plugin("the plugin id must be 2 to 48 characters: lowercase letters, digits and hyphens") }
        guard !name.isEmpty, name.count <= 60 else { throw MusicError.plugin("the plugin name must be 1 to 60 characters") }
        guard !version.isEmpty, version.count <= 32 else { throw MusicError.plugin("the plugin version must be 1 to 32 characters") }
        guard author.count <= 80, summary.count <= 300 else { throw MusicError.plugin("author or summary is too long") }
        guard apiVersion == MusicPluginLimits.supportedAPIVersion else {
            throw MusicError.plugin("this plugin needs plugin API \(apiVersion); this app supports API \(MusicPluginLimits.supportedAPIVersion)")
        }
        guard Self.isValidEntryName(entry) else { throw MusicError.plugin("the entry file name is not allowed") }
        guard !capabilities.isEmpty, Set(capabilities).count == capabilities.count else { throw MusicError.plugin("capabilities must list each of metadata, audio, lyrics, scrobble at most once, and at least one") }
        if let h = homepage, !(h.hasPrefix("https://") && h.count <= 300) { throw MusicError.plugin("the homepage must be an https address") }
        for host in permissions.networkHosts where !MusicPluginPolicy.isValidHostPattern(host) {
            throw MusicError.plugin("\"\(host)\" is not an allowed network host (use a full domain name such as api.example.com or *.example.com)")
        }
        if Set(permissions.networkHosts).count != permissions.networkHosts.count { throw MusicError.plugin("duplicate network host") }
        if permissions.networkHosts.count > 16 { throw MusicError.plugin("too many network hosts (maximum 16)") }
    }

    static func isValidID(_ s: String) -> Bool {
        guard (2...48).contains(s.utf8.count), s.first != "-", s.last != "-" else { return false }
        return s.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
    }

    static func isValidEntryName(_ s: String) -> Bool {
        guard s.count <= 64, s.hasSuffix(".js"), !s.hasPrefix("."), !s.contains("..") else { return false }
        return s.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95 || $0 == 46 }
    }

    // MARK: adapter naming

    /// The first declared capability keeps the plain plugin id; the others get a suffix, because the registry holds one provider per id.
    func adapterID(for cap: MusicPluginCapability) -> String {
        let order = MusicPluginCapability.allCases.filter { capabilities.contains($0) }
        return order.first == cap ? id : "\(id).\(cap.rawValue)"
    }
    var adapterIDs: [String] { MusicPluginCapability.allCases.filter { capabilities.contains($0) }.map { adapterID(for: $0) } }
}

// MARK: - Bundle

/// A checked package: the manifest plus its single script. Other files in the package are ignored, never extracted.
struct MusicPluginBundle: Sendable {
    let manifest: MusicPluginManifest
    let manifestData: Data
    let script: String

    /// A folder, a `.sbplugin` file (zip or JSON bundle).
    static func load(from url: URL) throws -> MusicPluginBundle {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true { return try load(folder: url) }
        guard let size = values?.fileSize else { throw MusicError.plugin("cannot read that file") }
        guard size <= MusicPluginLimits.maxBundleBytes else { throw MusicError.plugin("the plugin is larger than 5 MB") }
        guard let data = try? Data(contentsOf: url) else { throw MusicError.plugin("cannot read that file") }
        return try load(archive: data)
    }

    /// Sniffs the format: `PK` means zip, `{` means JSON bundle.
    static func load(archive data: Data) throws -> MusicPluginBundle {
        guard data.count <= MusicPluginLimits.maxBundleBytes else { throw MusicError.plugin("the plugin is larger than 5 MB") }
        if data.starts(with: [0x50, 0x4B]) { return try load(zip: data) }
        if data.first(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }) == 0x7B { return try load(jsonBundle: data) }
        throw MusicError.plugin("this is not a plugin package")
    }

    static func load(folder: URL) throws -> MusicPluginBundle {
        let manifestData = try readRegular(folder.appendingPathComponent(MusicPluginLimits.manifestFileName), inside: folder, max: MusicPluginLimits.maxManifestBytes)
        let manifest = try MusicPluginManifest.parse(manifestData)
        let script = try readRegular(folder.appendingPathComponent(manifest.entry), inside: folder, max: MusicPluginLimits.maxScriptBytes)
        return try make(manifestData: manifestData, manifest: manifest, script: script)
    }

    static func load(zip data: Data) throws -> MusicPluginBundle {
        let entries = try MusicPluginZip.entries(in: data)
        guard let mEntry = entries.first(where: { $0.name == MusicPluginLimits.manifestFileName }) else { throw MusicError.plugin("the package has no plugin.json") }
        let manifestData = try MusicPluginZip.extract(mEntry, from: data, maxBytes: MusicPluginLimits.maxManifestBytes)
        let manifest = try MusicPluginManifest.parse(manifestData)
        guard let sEntry = entries.first(where: { $0.name == manifest.entry }) else { throw MusicError.plugin("the package has no \(manifest.entry)") }
        let script = try MusicPluginZip.extract(sEntry, from: data, maxBytes: MusicPluginLimits.maxScriptBytes)
        return try make(manifestData: manifestData, manifest: manifest, script: script)
    }

    /// `{ "manifest": {...}, "files": { "main.js": "<base64>" } }`
    static func load(jsonBundle data: Data) throws -> MusicPluginBundle {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let manifestObject = root["manifest"], let files = root["files"] as? [String: String]
        else { throw MusicError.plugin("the bundle needs \"manifest\" and \"files\"") }
        for name in files.keys where !MusicPluginZip.isSafePath(name) { throw MusicError.plugin("unsafe file name in the package") }
        guard files.count <= MusicPluginLimits.maxArchiveEntries else { throw MusicError.plugin("too many files in the package") }
        guard let manifestData = try? JSONSerialization.data(withJSONObject: manifestObject, options: [.sortedKeys]) else { throw MusicError.plugin("plugin manifest is not valid") }
        let manifest = try MusicPluginManifest.parse(manifestData)
        guard let b64 = files[manifest.entry], let script = Data(base64Encoded: b64) else { throw MusicError.plugin("the package has no \(manifest.entry)") }
        guard script.count <= MusicPluginLimits.maxScriptBytes else { throw MusicError.plugin("the script is too large") }
        return try make(manifestData: manifestData, manifest: manifest, script: script)
    }

    private static func make(manifestData: Data, manifest: MusicPluginManifest, script: Data) throws -> MusicPluginBundle {
        guard let text = String(data: script, encoding: .utf8), !text.isEmpty else { throw MusicError.plugin("the script must be non-empty UTF-8 text") }
        return MusicPluginBundle(manifest: manifest, manifestData: manifestData, script: text)
    }

    /// Reads a plain file that really lives inside `folder` (a symlink pointing outside is refused).
    private static func readRegular(_ url: URL, inside folder: URL, max: Int) throws -> Data {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let real = url.resolvingSymlinksInPath().standardizedFileURL
        guard real.path.hasPrefix(root + "/") else { throw MusicError.plugin("a file points outside the plugin folder") }
        let v = try? real.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard v?.isRegularFile == true, let size = v?.fileSize else { throw MusicError.plugin("\(url.lastPathComponent) is missing") }
        guard size <= max else { throw MusicError.plugin("\(url.lastPathComponent) is too large") }
        guard let d = try? Data(contentsOf: real) else { throw MusicError.plugin("cannot read \(url.lastPathComponent)") }
        return d
    }
}

// MARK: - Minimal zip reader

/// Reads stored and deflated entries from a zip held in memory. It never writes entry names to disk (the installer only keeps plugin.json and the
/// entry script and writes them under fixed names), and it rejects any archive that contains an unsafe path at all, so a crafted archive fails loudly.
enum MusicPluginZip {
    struct Entry: Sendable { let name: String; let method: UInt16; let crc: UInt32; let compressedSize: Int; let size: Int; let localOffset: Int }

    /// No absolute paths, drive letters, backslashes, NUL, empty / "." / ".." components.
    static func isSafePath(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 200, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        let bytes = Array(name.utf8)
        if bytes.count >= 2, bytes[1] == 58 { return false }
        var parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        guard !parts.isEmpty else { return false }
        return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> Int? { o >= 0 && o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : nil }
    private static func u32(_ b: [UInt8], _ o: Int) -> Int? {
        o >= 0 && o + 4 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 : nil
    }

    static func entries(in data: Data) throws -> [Entry] {
        let b = [UInt8](data)
        let bad = MusicError.plugin("the plugin archive is damaged")
        guard b.count >= 22 else { throw bad }
        var eocd = -1
        var i = b.count - 22
        let lowest = max(0, b.count - 22 - 65535)
        while i >= lowest { if u32(b, i) == 0x06054B50 { eocd = i; break }; i -= 1 }
        guard eocd >= 0, let count = u16(b, eocd + 10), let cdSize = u32(b, eocd + 12), let cdOffset = u32(b, eocd + 16) else { throw bad }
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF { throw MusicError.plugin("zip64 archives are not supported") }
        guard count <= MusicPluginLimits.maxArchiveEntries else { throw MusicError.plugin("too many files in the package") }
        guard cdOffset + cdSize <= b.count else { throw bad }
        var out: [Entry] = []; var seen = Set<String>()
        var p = cdOffset
        for _ in 0..<count {
            guard u32(b, p) == 0x02014B50, let flags = u16(b, p + 8), let method = u16(b, p + 10), let crc = u32(b, p + 16),
                  let csize = u32(b, p + 20), let size = u32(b, p + 24), let nlen = u16(b, p + 28), let xlen = u16(b, p + 30),
                  let clen = u16(b, p + 32), let local = u32(b, p + 42), p + 46 + nlen <= b.count else { throw bad }
            guard let name = String(bytes: b[(p + 46)..<(p + 46 + nlen)], encoding: .utf8) else { throw MusicError.plugin("unsafe file name in the package") }
            guard isSafePath(name) else { throw MusicError.plugin("unsafe file name in the package: \(name.prefix(40))") }
            guard seen.insert(name).inserted else { throw MusicError.plugin("the archive lists \(name) twice") }
            guard flags & 1 == 0 else { throw MusicError.plugin("encrypted archives are not supported") }
            guard size <= MusicPluginLimits.maxBundleBytes else { throw MusicError.plugin("a file in the package is too large") }
            if !name.hasSuffix("/") { out.append(Entry(name: name, method: UInt16(method), crc: UInt32(crc), compressedSize: csize, size: size, localOffset: local)) }
            p += 46 + nlen + xlen + clen
        }
        return out
    }

    static func extract(_ e: Entry, from data: Data, maxBytes: Int) throws -> Data {
        let b = [UInt8](data)
        let bad = MusicError.plugin("the plugin archive is damaged")
        guard e.size <= maxBytes else { throw MusicError.plugin("\(e.name) is too large") }
        guard u32(b, e.localOffset) == 0x04034B50, let nlen = u16(b, e.localOffset + 26), let xlen = u16(b, e.localOffset + 28) else { throw bad }
        let start = e.localOffset + 30 + nlen + xlen
        guard start >= 0, e.compressedSize >= 0, start + e.compressedSize <= b.count else { throw bad }
        let comp = Array(b[start..<(start + e.compressedSize)])
        var out: [UInt8]
        switch e.method {
        case 0:
            guard comp.count == e.size else { throw bad }
            out = comp
        case 8:
            out = [UInt8](repeating: 0, count: e.size)
            if e.size > 0 {
                guard !comp.isEmpty else { throw bad }
                let n = comp.withUnsafeBufferPointer { src -> Int in
                    out.withUnsafeMutableBufferPointer { dst -> Int in
                        guard let s = src.baseAddress, let d = dst.baseAddress else { return -1 }
                        return compression_decode_buffer(d, e.size, s, comp.count, nil, COMPRESSION_ZLIB)
                    }
                }
                guard n == e.size else { throw bad }
            }
        default: throw MusicError.plugin("unsupported compression in the archive")
        }
        guard crc32(out) == e.crc else { throw MusicError.plugin("the plugin archive failed its integrity check") }
        return Data(out)
    }

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
