import Foundation

/// What a pasted address most likely is, and the fields to fill in for it. Pure and conservative: when it is not sure it says
/// "playlist link", which is what most pasted addresses are.
struct DetectedSource: Equatable, Sendable {
    var kind: AddSourceKind
    var server = ""
    var username = ""
    var password = ""
    var url = ""
    /// One short sentence for the person, e.g. "Looks like an Xtream login."
    var note: String
}

enum SourceDetector {

    static func detect(_ raw: String) -> DetectedSource? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\n"), !text.contains(" "), let c = URLComponents(string: text), let scheme = c.scheme?.lowercased(), c.host?.isEmpty == false else { return nil }
        let path = c.path.lowercased()
        let ext = (path as NSString).pathExtension
        let query = Dictionary((c.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let port = c.port
        let origin = "\(scheme)://\(c.host!)" + (port.map { ":\($0)" } ?? "")

        // Streams that are not web pages or playlists at all.
        if !["http", "https"].contains(scheme) {
            guard SourceURLValidator.playableSchemes.contains(scheme) else { return nil }
            return DetectedSource(kind: .stream, url: text, note: "Looks like a single stream address.")
        }

        // Xtream: get.php / player_api.php / xmltv.php with a login in the query.
        if ["get.php", "player_api.php", "xmltv.php"].contains((path as NSString).lastPathComponent), let u = query["username"], let p = query["password"], !u.isEmpty, !p.isEmpty {
            let prefix = (c.path as NSString).deletingLastPathComponent
            return DetectedSource(kind: .xtream, server: origin + (prefix == "/" ? "" : prefix), username: u, password: p, note: "Looks like an Xtream login. The server, username and password are filled in.")
        }
        if port == 32400 || query["x-plex-token"] != nil || path.contains("/web/index.html") && port == 32400 {
            return DetectedSource(kind: .plex, server: origin, password: query["x-plex-token"] ?? "", note: "Looks like a Plex server." + (query["x-plex-token"] == nil ? " Add your access token." : ""))
        }
        if port == 9981 || path.hasPrefix("/tvheadend") || path.hasPrefix("/playlist/channels") || path.hasPrefix("/xmltv/channels") {
            return DetectedSource(kind: .tvheadend, server: origin, note: "Looks like a TVHeadend server. Add its username and password if it asks for one.")
        }
        if path.hasPrefix("/emby") { return DetectedSource(kind: .emby, server: origin, note: "Looks like an Emby server.") }
        if port == 8096 || path.hasPrefix("/jellyfin") {
            return DetectedSource(kind: .jellyfin, server: origin, note: "Looks like a Jellyfin server (Emby uses the same port; change the type if it is Emby).")
        }
        if path.hasSuffix("/c") || path.hasSuffix("/c/") || path.contains("/stalker_portal") || path.hasSuffix("/portal.php") {
            return DetectedSource(kind: .stalker, server: text, note: "Looks like a Stalker or MAG portal. Add the box's MAC address.")
        }
        if path.hasPrefix("/web/") || path.hasPrefix("/api/getservices") || path.hasPrefix("/api/getallservices") {
            return DetectedSource(kind: .enigma2, server: origin, note: "Looks like an Enigma2 receiver (OpenWebif). Add a username and password if it asks.")
        }
        if path.hasSuffix("/lineup.json") || port == 5004 || (c.host ?? "").lowercased().contains("hdhomerun") {
            return DetectedSource(kind: .hdhomerun, server: c.host ?? "", note: "Looks like an HDHomeRun tuner.")
        }
        if ext == "json" { return DetectedSource(kind: .m3uURL, url: text, note: "Looks like a JSON playlist.") }
        if StreamCapabilities.isMediaFile(extension: ext) { return DetectedSource(kind: .stream, url: text, note: "Looks like a single stream address.") }
        if ["m3u", "m3u8"].contains(ext) || query["type"] == "m3u" || query["type"] == "m3u_plus" || path.contains("playlist") {
            return DetectedSource(kind: .m3uURL, url: text, note: "Looks like an M3U playlist link.")
        }
        return DetectedSource(kind: .m3uURL, url: text, note: "Treated as a playlist link. If it is something else, choose the type above.")
    }

    /// True for an address that is one stream rather than a playlist, so the app plays it instead of trying to read it as a list.
    static func isDirectStream(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if !["http", "https"].contains(scheme) { return SourceURLValidator.playableSchemes.contains(scheme) }
        return StreamCapabilities.isMediaFile(extension: url.pathExtension)
    }
}
