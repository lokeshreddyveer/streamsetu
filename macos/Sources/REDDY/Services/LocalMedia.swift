import Foundation
import CryptoKit
import AVFoundation

/// Files and folders on this device, and folders on a WebDAV server: what can be played from them and how they are listed.
/// None of this touches playlists or the catalogue; a file plays like a movie that belongs to no playlist.
enum LocalMedia {
    /// A fixed stand-in "playlist" for everything that is not from a playlist.
    static let sourceID = UUID(uuidString: "00000000-0000-4000-8000-00000000F11E")!

    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "ts", "m2ts", "mts", "flv", "wmv", "mpg", "mpeg", "3gp", "ogv", "divx", "vob"]
    static let subtitleExtensions: Set<String> = ["srt", "vtt", "ass", "ssa", "sub"]

    static func isVideo(_ name: String) -> Bool { videoExtensions.contains((name as NSString).pathExtension.lowercased()) }
    static func isSubtitle(_ name: String) -> Bool { subtitleExtensions.contains((name as NSString).pathExtension.lowercased()) }

    /// The same file gets the same id every time, so its resume position is remembered.
    static func itemID(_ key: String) -> String {
        "local:" + SHA256.hash(data: Data(key.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    /// "My.Movie.2020.1080p.mkv" → "My Movie 2020 1080p".
    static func title(fromFileName name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let t = stem.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? name : t
    }

    /// Subtitle files that belong to a video in the same folder: "Movie.srt", "Movie.en.srt", "Movie.English.vtt".
    static func sidecars(of video: String, among names: [String]) -> [String] {
        let stem = ((video as NSString).deletingPathExtension).lowercased()
        return names.filter { isSubtitle($0) }.filter {
            let s = (($0 as NSString).deletingPathExtension).lowercased()
            return s == stem || s.hasPrefix(stem + ".")
        }.sorted()
    }

    /// How far a video must be turned clockwise to stand upright (phones store portrait video sideways and say so in a flag): 0, 90, 180 or 270.
    static func rotationDegrees(of url: URL) async -> Int {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first, let t = try? await track.load(.preferredTransform) else { return 0 }
        return rotationDegrees(a: Double(t.a), b: Double(t.b))
    }

    static func rotationDegrees(a: Double, b: Double) -> Int {
        let d = Int((atan2(b, a) * 180 / .pi).rounded())
        let n = ((d % 360) + 360) % 360
        return [0, 90, 180, 270].min { abs($0 - n) < abs($1 - n) } ?? 0
    }

    /// The video filter that turns a picture by that many degrees (nil when it is upright).
    static func rotationFilter(_ degrees: Int) -> String? {
        switch degrees {
        case 90: return "lavfi=[transpose=clock]"
        case 180: return "lavfi=[hflip,vflip]"
        case 270: return "lavfi=[transpose=cclock]"
        default: return nil
        }
    }

    /// The subtitle files next to a video on disk (empty when the folder cannot be read).
    static func sidecarURLs(for video: URL) -> [URL] {
        let dir = video.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return sidecars(of: video.lastPathComponent, among: names).map { dir.appendingPathComponent($0) }
    }
}

/// One line of a folder listing.
struct MediaEntry: Identifiable, Hashable, Sendable {
    let name: String
    let isFolder: Bool
    let size: Int64?
    /// A file URL, or the address on the server.
    let location: URL
    var id: String { location.absoluteString }
}

/// Keeps access to files the system let us open, for as long as they are in use.
final class ScopedAccess: @unchecked Sendable {
    static let shared = ScopedAccess()
    private let lock = NSLock()
    private var held: [String: URL] = [:]
    private var oneOff: URL?

    /// Keeps a folder open for as long as it is a saved source.
    func hold(_ url: URL) { lock.withLock { if held[url.path] == nil, url.startAccessingSecurityScopedResource() { held[url.path] = url } } }
    func release(_ url: URL) { lock.withLock { if let u = held.removeValue(forKey: url.path) { u.stopAccessingSecurityScopedResource() } } }
    /// A single opened file: the previous single file is let go.
    func holdOneOff(_ url: URL) {
        lock.withLock {
            oneOff?.stopAccessingSecurityScopedResource()
            oneOff = url.startAccessingSecurityScopedResource() ? url : nil
        }
    }
}

/// A saved place to browse: a folder on this device or a WebDAV server.
struct FileSource: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case folder, webdav }
    var id = UUID()
    var kind: Kind
    var name: String
    var bookmark: Data?
    var address: String?
    var username: String?
    var credentialRef: String { "files.\(id.uuidString)" }
}

final class FileSourceStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let credentials: CredentialStore
    private static let key = "files.sources.v1"
    init(defaults: UserDefaults = .standard, credentials: CredentialStore) { self.defaults = defaults; self.credentials = credentials }

    func all() -> [FileSource] {
        guard let d = defaults.data(forKey: Self.key), let list = try? JSONDecoder().decode([FileSource].self, from: d) else { return [] }
        return list
    }
    private func write(_ list: [FileSource]) { if let d = try? JSONEncoder().encode(list) { defaults.set(d, forKey: Self.key) } }

    func add(_ s: FileSource, password: String? = nil) {
        var list = all(); list.append(s); write(list)
        if let password, !password.isEmpty { try? credentials.save(Credentials(username: s.username, password: password, url: nil), ref: s.credentialRef) }
    }
    func remove(_ s: FileSource) {
        write(all().filter { $0.id != s.id })
        try? credentials.delete(ref: s.credentialRef)
        if let u = folderURL(s) { ScopedAccess.shared.release(u) }
    }
    func password(for s: FileSource) -> String? { (try? credentials.load(ref: s.credentialRef))??.password }

    static func bookmark(for folder: URL) -> Data? {
        #if os(macOS)
        return try? folder.bookmarkData(options: .withSecurityScope)
        #else
        return try? folder.bookmarkData()
        #endif
    }

    /// The folder a saved source points at, opened for reading.
    func folderURL(_ s: FileSource) -> URL? {
        guard s.kind == .folder, let data = s.bookmark else { return nil }
        var stale = false
        #if os(macOS)
        let opts: URL.BookmarkResolutionOptions = .withSecurityScope
        #else
        let opts: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: data, options: opts, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        ScopedAccess.shared.hold(url)
        return url
    }
}

enum MediaListing {
    /// A folder on this device: sub-folders and videos (and subtitles, so they can be matched), folders first.
    static func local(_ folder: URL) throws -> [MediaEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        return urls.compactMap { u -> MediaEntry? in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let isDir = v?.isDirectory ?? false
            guard isDir || LocalMedia.isVideo(u.lastPathComponent) || LocalMedia.isSubtitle(u.lastPathComponent) else { return nil }
            return MediaEntry(name: u.lastPathComponent, isFolder: isDir, size: v?.fileSize.map(Int64.init), location: u)
        }.sorted(by: order)
    }

    static func order(_ a: MediaEntry, _ b: MediaEntry) -> Bool {
        a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// Reads folders on a WebDAV server (Nextcloud, many NAS boxes) and plays their files. The login travels as an HTTP header, never in the address.
struct WebDAVClient: Sendable {
    let base: URL
    let username: String?
    let password: String?

    var headers: [String: String] {
        guard let username, !username.isEmpty else { return [:] }
        let token = Data("\(username):\(password ?? "")".utf8).base64EncodedString()
        return ["Authorization": "Basic \(token)"]
    }

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    func list(_ folder: URL) async throws -> [MediaEntry] {
        var req = URLRequest(url: folder, timeoutInterval: 20)
        req.httpMethod = "PROPFIND"
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("<?xml version=\"1.0\"?><propfind xmlns=\"DAV:\"><prop><displayname/><resourcetype/><getcontentlength/></prop></propfind>".utf8)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw Failure(message: "The server refused the login. Check the name and password.") }
        guard code == 207 || code == 200 else { throw Failure(message: "The server answered \(code). Is this a WebDAV address?") }
        return Self.parse(data, folder: folder)
    }

    /// Reads a multi-status answer into the folders, videos and subtitles under `folder`.
    static func parse(_ data: Data, folder: URL) -> [MediaEntry] {
        let p = PropfindParser()
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.delegate = p
        xml.parse()
        let here = folder.path.removingPercentEncoding?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        return p.items.compactMap { item -> MediaEntry? in
            guard let url = URL(string: item.href, relativeTo: folder)?.absoluteURL else { return nil }
            let path = url.path.removingPercentEncoding?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            if path == here { return nil }                          // the folder itself
            let name = item.name.isEmpty ? (path as NSString).lastPathComponent : item.name
            guard item.isFolder || LocalMedia.isVideo(name) || LocalMedia.isSubtitle(name) else { return nil }
            return MediaEntry(name: name, isFolder: item.isFolder, size: item.size, location: url)
        }.sorted(by: MediaListing.order)
    }

    /// Fetches a small file (a subtitle) to a temporary place so the player can read it.
    func download(_ url: URL) async -> URL? {
        var req = URLRequest(url: url, timeoutInterval: 20)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200, data.count < 5_000_000 else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("sub-\(UUID().uuidString)-\(url.lastPathComponent)")
        return (try? data.write(to: out)) == nil ? nil : out
    }
}

private final class PropfindParser: NSObject, XMLParserDelegate {
    struct Item { var href = "", name = "", isFolder = false, size: Int64? }
    var items: [Item] = []
    private var current: Item?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if element == "response" { current = Item() }
        if element == "collection" { current?.isFolder = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "href": current?.href = t
        case "displayname": current?.name = t
        case "getcontentlength": current?.size = Int64(t)
        case "response": if let c = current { items.append(c) }; current = nil
        default: break
        }
    }
}
