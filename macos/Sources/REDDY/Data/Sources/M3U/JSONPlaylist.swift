import Foundation

/// JSON playlists (and HDHomeRun's lineup.json) are turned into the same M3U text the rest of the app already reads, so they get
/// the same categories, guide matching, limits and playback as any playlist.
///
/// Accepted: a list of items, or an object holding one (`channels`, `streams`, `items`, `lineup`, `playlist`, `data`).
/// Each item names its stream (`url`, `URL`, `stream`, `stream_url`, `link`, `src`) and may carry a name (`name`, `title`,
/// `GuideName`), picture (`logo`, `icon`, `image`), group (`group`, `category`), guide id (`tvg_id`, `epg_id`, `id`) and number
/// (`number`, `GuideNumber`, `channel`).
enum JSONPlaylist {
    static let maxBytes: Int64 = 50 * 1024 * 1024

    static func looksLikeJSON(_ head: Data) -> Bool {
        guard let first = head.first(where: { ![0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains($0) }) else { return false }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }

    static func m3u(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var items: [[String: Any]]?
        if let a = root as? [[String: Any]] { items = a }
        else if let o = root as? [String: Any] {
            for k in ["channels", "streams", "items", "lineup", "playlist", "data", "entries"] {
                if let a = o[k] as? [[String: Any]] { items = a; break }
            }
        }
        guard let items else { return nil }
        var out = "#EXTM3U\n"
        var count = 0
        for item in items {
            guard let url = text(item, ["url", "URL", "stream", "stream_url", "streamUrl", "link", "src", "uri"]), url.contains("://") else { continue }
            let name = text(item, ["name", "title", "GuideName", "channel_name", "label"]) ?? "Channel \(count + 1)"
            var attrs = ""
            if let id = text(item, ["tvg_id", "tvg-id", "epg_id", "epgId", "id"]) { attrs += " tvg-id=\"\(clean(id))\"" }
            if let logo = text(item, ["logo", "tvg_logo", "tvg-logo", "icon", "image", "thumbnail", "poster"]) { attrs += " tvg-logo=\"\(clean(logo))\"" }
            if let n = text(item, ["number", "GuideNumber", "channel", "num"]) { attrs += " tvg-chno=\"\(clean(n))\"" }
            if let g = text(item, ["group", "group_title", "category", "genre"]) { attrs += " group-title=\"\(clean(g))\"" }
            out += "#EXTINF:-1\(attrs),\(clean(name))\n\(url.trimmingCharacters(in: .whitespaces))\n"
            count += 1
        }
        return count > 0 ? out : nil
    }

    /// Writes the converted playlist next to the original and returns it, or nil when the JSON is not a playlist.
    static func convert(file: URL) throws -> URL? {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        guard size <= maxBytes else { throw SourceError.invalidResponse("This JSON playlist is too large.") }
        guard let text = m3u(from: try Data(contentsOf: file, options: .mappedIfSafe)) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("json-\(UUID().uuidString).m3u")
        try text.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    private static func text(_ d: [String: Any], _ keys: [String]) -> String? {
        for k in keys {
            if let s = d[k] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
            if let n = d[k] as? NSNumber { return n.stringValue }
            if let a = d[k] as? [String], let s = a.first, !s.isEmpty { return s }
        }
        return nil
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
