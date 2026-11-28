import Foundation

/// Reading the clip's playlists. Apple serves each clip as a playlist of renditions, each rendition being one fragmented MP4 read by byte ranges,
/// so the whole clip is one small file that can be saved and played from disk.
enum MusicMotionPlaylist {
    struct Variant: Equatable { var url: URL; var width: Int; var bandwidth: Int; var isH264: Bool }

    /// The renditions of a master playlist, in file order. Frame-only streams are skipped.
    static func variants(in master: String, base: URL) -> [Variant] {
        let lines = master.components(separatedBy: .newlines)
        var out: [Variant] = []
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = line.dropFirst("#EXT-X-STREAM-INF:".count)
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty || lines[j].hasPrefix("#") { j += 1 }
                if j < lines.count, let url = URL(string: lines[j].trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL {
                    let width = attribute("RESOLUTION", in: attrs).flatMap { $0.split(separator: "x").first.flatMap { Int($0) } } ?? 0
                    let bw = attribute("AVERAGE-BANDWIDTH", in: attrs).flatMap(Int.init) ?? attribute("BANDWIDTH", in: attrs).flatMap(Int.init) ?? 0
                    out.append(Variant(url: url, width: width, bandwidth: bw, isH264: (attribute("CODECS", in: attrs) ?? "").contains("avc1")))
                }
                i = j
            }
            i += 1
        }
        return out
    }

    /// A rendition sharp enough for a cover but light to fetch: H.264 (every device decodes it), at least 480 px wide, the smallest of those.
    static func pick(_ variants: [Variant]) -> Variant? {
        let usable = variants.filter { $0.isH264 && $0.width >= 480 }
        if let v = usable.min(by: { ($0.bandwidth, $0.width) < ($1.bandwidth, $1.width) }) { return v }
        let h264 = variants.filter(\.isH264)
        return h264.max(by: { $0.width < $1.width }) ?? variants.min(by: { $0.bandwidth < $1.bandwidth })
    }

    /// The one media file a rendition's playlist points at, when it is a single file read by ranges.
    static func mediaFile(in media: String, base: URL) -> URL? {
        var names = Set<String>()
        for raw in media.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MAP:"), let uri = attribute("URI", in: line.dropFirst("#EXT-X-MAP:".count)) { names.insert(uri) }
            else if !line.isEmpty, !line.hasPrefix("#") { names.insert(line) }
        }
        guard names.count == 1, let name = names.first, let url = URL(string: name, relativeTo: base)?.absoluteURL else { return nil }
        return url
    }

    static func isPlaylist(_ url: URL) -> Bool { url.pathExtension.lowercased() == "m3u8" }

    private static func attribute(_ key: String, in attrs: Substring) -> String? {
        guard let r = attrs.range(of: key + "=") else { return nil }
        let rest = attrs[r.upperBound...]
        if rest.hasPrefix("\"") {
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: "\"") else { return nil }
            return String(body[..<end])
        }
        return String(rest.prefix { $0 != "," })
    }
}

/// Clips on disk: one file per clip under the Music folder, the least recently used removed first once the folder passes its limit, and the
/// folder kept out of backups because every file can be fetched again.
struct MusicMotionClipCache: Sendable {
    static let limitBytes = 150 * 1024 * 1024
    static let maxClipBytes = 20 * 1024 * 1024

    let folder: URL
    var limit = MusicMotionClipCache.limitBytes

    init(folder: URL = MusicStorage.subfolder("MotionArtwork"), limit: Int = MusicMotionClipCache.limitBytes) { self.folder = folder; self.limit = limit }

    struct Item: Equatable { var url: URL; var size: Int; var used: Date }

    func fileURL(forKey key: String) -> URL { folder.appendingPathComponent(MusicHash.sha256(key, prefix: 16) + ".mp4") }

    /// The saved file for a key, marked as just used.
    func existing(forKey key: String, now: Date = Date()) -> URL? {
        let url = fileURL(forKey: key)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        return url
    }

    /// Saves the bytes whole, or not at all.
    @discardableResult
    func store(_ data: Data, forKey key: String, now: Date = Date()) -> URL? {
        guard !data.isEmpty, data.count <= Self.maxClipBytes else { return nil }
        MusicStorage.ensureUnbacked(folder)
        let url = fileURL(forKey: key)
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        trim()
        return url
    }

    func items() -> [Item] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension == "mp4" }.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            return Item(url: u, size: v.fileSize ?? 0, used: v.contentModificationDate ?? .distantPast)
        }
    }

    var totalBytes: Int { items().reduce(0) { $0 + $1.size } }

    /// Which files to remove so the rest fits the limit: oldest use first.
    static func victims(_ items: [Item], limit: Int) -> [Item] {
        var total = items.reduce(0) { $0 + $1.size }
        var out: [Item] = []
        for item in items.sorted(by: { $0.used < $1.used }) where total > limit { out.append(item); total -= item.size }
        return out
    }

    func trim() { for v in Self.victims(items(), limit: limit) { try? FileManager.default.removeItem(at: v.url) } }

    func clear() { try? FileManager.default.removeItem(at: folder) }
}

/// Fetches a clip's bytes: playlist, then the one file. Every address must be https and public, and the file must be under the size cap.
struct MusicMotionClipLoader: Sendable {
    typealias Fetch = @Sendable (URL, Int) async throws -> Data
    var fetch: Fetch

    init(fetch: @escaping Fetch = MusicMotionClipLoader.network) { self.fetch = fetch }

    static let network: Fetch = { url, maxBytes in
        var r = URLRequest(url: url)
        r.timeoutInterval = 20
        let (d, resp) = try await MusicTransfer.data(for: r, maxBytes: maxBytes)
        guard (200..<300).contains(resp.statusCode) else { throw MusicError.network("HTTP \(resp.statusCode)") }
        return d
    }

    static func allowed(_ url: URL) -> Bool { url.scheme?.lowercased() == "https" && MusicTransfer.isAllowed(url) }

    func data(for clipURL: URL) async throws -> Data {
        guard Self.allowed(clipURL) else { throw MusicError.network("bad address") }
        var file = clipURL
        if MusicMotionPlaylist.isPlaylist(clipURL) {
            let master = String(decoding: try await fetch(clipURL, 400_000), as: UTF8.self)
            let variants = MusicMotionPlaylist.variants(in: master, base: clipURL)
            var media = clipURL
            if let v = MusicMotionPlaylist.pick(variants) {
                guard Self.allowed(v.url) else { throw MusicError.network("bad address") }
                media = v.url
            }
            let list = String(decoding: try await fetch(media, 400_000), as: UTF8.self)
            guard let f = MusicMotionPlaylist.mediaFile(in: list, base: media), Self.allowed(f) else { throw MusicError.network("unreadable clip") }
            file = f
        }
        let data = try await fetch(file, MusicMotionClipCache.maxClipBytes)
        guard !data.isEmpty, data.count <= MusicMotionClipCache.maxClipBytes else { throw MusicError.network("clip too large") }
        return data
    }
}
