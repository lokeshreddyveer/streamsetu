import Foundation

enum PlaylistFormat: Sendable { case catalog, hlsManifest, invalid }

enum M3UValidator {
    static let maxNameLength = 512
    static let maxURLLength = 4096

    /// An `.m3u8` can be a channel list *or* a single HLS manifest. Look at the content, not the extension.
    static func detect(head: Data) -> PlaylistFormat {
        let text = String(decoding: head.prefix(16 * 1024), as: UTF8.self)
        let t = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        guard t.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            return t.contains("#EXTINF") ? .catalog : .invalid
        }
        let manifestTags = ["#EXT-X-TARGETDURATION", "#EXT-X-STREAM-INF", "#EXT-X-MEDIA-SEQUENCE", "#EXT-X-VERSION", "#EXT-X-MEDIA:"]
        if manifestTags.contains(where: t.contains), !t.contains("#EXTINF:-1 ") && !t.contains("tvg-") { return .hlsManifest }
        return .catalog
    }

    /// Resolves relative stream URLs against the playlist address and rejects entries a player can't open.
    static func validate(_ entry: M3UEntry, base: URL?) -> M3UEntry? {
        guard !entry.url.isEmpty, entry.url.count <= maxURLLength, entry.name.count <= maxNameLength else { return nil }
        var e = entry
        if !e.url.contains("://") {
            guard let base, let resolved = URL(string: e.url, relativeTo: base)?.absoluteURL else { return nil }
            e.url = resolved.absoluteString
        }
        guard let url = URL(string: e.url), SourceURLValidator.isPlayableScheme(url) else { return nil }
        return e
    }
}
