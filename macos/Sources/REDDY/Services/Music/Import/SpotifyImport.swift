import Foundation
import Compression

// Reading what a person wants to bring over from Spotify. Nothing here needs a Spotify account or key: a public link, the "account data" export
// the person requests from Spotify (zip or one of its JSON files), or a CSV from an export tool. Parsing is pure; only `SpotifyLinkReader` talks to
// the network, and only through MusicHTTP when the person pastes a link.

// MARK: - Models

struct ImportSourceTrack: Codable, Hashable, Sendable, Identifiable {
    /// The Spotify track id when known.
    var spotifyID: String?
    var title: String
    var artists: [String]
    var album: String?
    var durationMs: Int64?
    var explicit: Bool?

    /// Cache key: the Spotify id, or for a track with none (local file, CSV row) a synthetic `~title|first artist`.
    var key: String { spotifyID ?? "~" + ImportMatcher.norm(title) + "|" + ImportMatcher.norm(artists.first ?? "") }
    var id: String { key }
}

enum ImportListKind: String, Codable, Sendable { case playlist, album, liked }

struct ImportList: Codable, Hashable, Sendable, Identifiable {
    var kind: ImportListKind
    var name: String
    var owner: String?
    var coverURL: String?
    /// Only for link reads: what "Update from Spotify" reads again.
    var shareURL: String?
    var tracks: [ImportSourceTrack]
    /// Non-songs and blank titles that were left out.
    var skipped = 0
    /// The page showed only the first 100 and the rest could not be read.
    var truncated = false
    var id: String { name + "|" + kind.rawValue + "|" + (shareURL ?? "") }
}

/// Short codes the screen words in the person's language.
enum ImportError: Error, Equatable, Sendable {
    case `private`, notSpotify, notAList, empty, spotifyChanged, unreadable, csvColumns, busy, nothingRead, gone
    case cooldown(until: Date)
    case network(String)
}

// MARK: - Links

struct SpotifyLink: Equatable, Sendable {
    enum Kind: String, Sendable { case playlist, album, track, artist }
    var kind: Kind
    var id: String

    /// Accepts open.spotify.com links (with `?si=`, a locale prefix, `/embed/`, the old `/user/<name>/playlist/<id>`, no scheme), play.spotify.com and `spotify:<kind>:<id>`.
    /// The kind is the first known word and the id the next segment. Show and episode links, other hosts and empty ids are not Spotify links.
    static func parse(_ raw: String) -> SpotifyLink? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let whole = parseToken(text) { return whole }
        // Share text ("Listen to X on Spotify https://open.spotify.com/track/...") and angle brackets or trailing punctuation around a link.
        let junk = CharacterSet(charactersIn: "<>()[]\"'.,;!?")
        for word in text.components(separatedBy: .whitespacesAndNewlines) {
            let w = word.trimmingCharacters(in: junk)
            let lower = w.lowercased()
            guard lower.hasPrefix("spotify:") || lower.contains("spotify.com/") else { continue }
            if let l = parseToken(w) { return l }
        }
        return nil
    }

    private static func parseToken(_ text: String) -> SpotifyLink? {
        func valid(_ id: String) -> Bool { (1...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
        if text.lowercased().hasPrefix("spotify:") {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            // "spotify:user:<name>:playlist:<id>" is the older playlist form: the kind is the first known word.
            guard let i = parts.indices.dropFirst().first(where: { Kind(rawValue: parts[$0].lowercased()) != nil }), i + 1 < parts.count,
                  let k = Kind(rawValue: parts[i].lowercased()), valid(parts[i + 1]) else { return nil }
            return SpotifyLink(kind: k, id: parts[i + 1])
        }
        let withScheme = text.contains("://") ? text : "https://" + text
        guard let comps = URLComponents(string: withScheme), let host = comps.host?.lowercased(),
              host == "open.spotify.com" || host == "play.spotify.com" || host == "embed.spotify.com" else { return nil }
        let segs = comps.path.split(separator: "/").map(String.init)
        for (i, s) in segs.enumerated() {
            if let k = Kind(rawValue: s.lowercased()) {
                guard i + 1 < segs.count, valid(segs[i + 1]) else { return nil }
                return SpotifyLink(kind: k, id: segs[i + 1])
            }
        }
        return nil
    }

    var canonicalURL: String { "https://open.spotify.com/\(kind.rawValue)/\(id)" }
}

// MARK: - Local file URIs

enum SpotifyLocalURI {
    /// `spotify:local:<artist>:<album>:<title>:<seconds>`, form-encoded. Needs exactly four fields and a non-empty title.
    static func decode(_ uri: String) -> ImportSourceTrack? {
        let prefix = "spotify:local:"
        guard uri.lowercased().hasPrefix(prefix) else { return nil }
        let fields = String(uri.dropFirst(prefix.count)).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4 else { return nil }
        func form(_ s: String) -> String { s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s }
        let title = form(fields[2]).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        let artist = form(fields[0]).trimmingCharacters(in: .whitespaces), album = form(fields[1]).trimmingCharacters(in: .whitespaces)
        let secs = Int(fields[3]) ?? 0
        return ImportSourceTrack(spotifyID: nil, title: title, artists: artist.isEmpty ? [] : [artist], album: album.isEmpty ? nil : album, durationMs: secs > 0 ? Int64(secs) * 1000 : nil, explicit: nil)
    }
}

// MARK: - The embed page

enum SpotifyEmbedParser {
    /// Reads the JSON blob in the embed page's `__NEXT_DATA__` script (see `SpotifyEmbedPage`). A deleted or private list answers 404 or a 200 whose props carry status 404 and no state.
    static func parse(html: Data, link: SpotifyLink) throws -> ImportList {
        let entity = try SpotifyEmbedEntity.parse(html: html, link: link)
        guard link.kind == .playlist || link.kind == .album else { throw ImportError.notAList }
        var tracks: [ImportSourceTrack] = []
        let skipped = max(0, rawRowCount(html) - entity.rows.count)
        let albumName = link.kind == .album ? entity.name : nil
        for r in entity.rows {
            tracks.append(ImportSourceTrack(spotifyID: r.id, title: r.title, artists: r.artists, album: albumName, durationMs: r.durationMs > 0 ? r.durationMs : nil, explicit: r.explicit))
        }
        let cover = entity.covers.max { $0.width < $1.width }?.url
        return ImportList(kind: link.kind == .album ? .album : .playlist, name: entity.name, owner: entity.subtitle, coverURL: cover, shareURL: link.canonicalURL,
                          tracks: tracks, skipped: skipped, truncated: entity.mayBeTruncated)
    }

    /// Rows on the page that are not songs (episodes, local files), so the screen can say how many were left out.
    private static func rawRowCount(_ html: Data) -> Int {
        ((try? SpotifyEmbedPage.entity(html: html))?.array("trackList").count) ?? 0
    }
}

// MARK: - The full playlist (official API, optional)

/// A playlist page on the embed shows 100 songs at most. With the person's own developer app the rest can be read from the official API (only for lists
/// that app may read; otherwise the first 100 are kept and flagged). The web player's own query and token are never used.
enum SpotifyPlaylistAPI {
    static let pageSize = 50

    static func parsePage(_ data: Data) throws -> (total: Int, tracks: [ImportSourceTrack], skipped: Int) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ImportError.spotifyChanged }
        var tracks: [ImportSourceTrack] = [], skipped = 0
        for row in SpotifyMapper.listItems(root) {
            guard let d = (row["item"] as? [String: Any]) ?? (row["track"] as? [String: Any]) else { skipped += 1; continue }
            if (d["is_local"] as? Bool) == true {
                if let uri = d.str("uri"), let t = SpotifyLocalURI.decode(uri) { tracks.append(t) } else { skipped += 1 }
                continue
            }
            guard (d.str("type") ?? "track") == "track", let id = d.str("id"), let name = d.str("name")?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { skipped += 1; continue }
            tracks.append(ImportSourceTrack(spotifyID: id, title: name, artists: d.array("artists").compactMap { $0.str("name") }, album: d.dict("album")?.str("name"),
                                            durationMs: d.int("duration_ms").map(Int64.init), explicit: d["explicit"] as? Bool))
        }
        guard root["items"] != nil else { throw ImportError.spotifyChanged }
        return (root.int("total") ?? tracks.count, tracks, skipped)
    }
}

/// Reads a public link over the network: the embed page, plus the rest of a long playlist when the person added their own developer app.
struct SpotifyLinkReader: Sendable {
    var http: MusicHTTP = MusicHTTP()
    /// The person's developer app, when one is set up. Nil means links are read through the embed page only.
    var auth: SpotifyAuth? = nil
    /// Pause between pages, so reading a long list is not a burst.
    var pageDelay: @Sendable () async -> Void = { try? await Task.sleep(for: .milliseconds(Int.random(in: 400...800))) }

    func read(_ link: SpotifyLink) async throws -> ImportList {
        guard link.kind == .playlist || link.kind == .album else { throw ImportError.notAList }
        guard let url = SpotifyEmbedClient.pageURL(link) else { throw ImportError.notSpotify }
        let embed: Data
        do { embed = try await http.get(url, headers: ["Accept": "text/html"]) }
        catch MusicError.notFound { throw ImportError.private }
        catch let e as MusicError { throw ImportError.network(e.errorDescription ?? "network") }
        var list = try SpotifyEmbedParser.parse(html: embed, link: link)
        guard link.kind == .playlist, list.truncated, let auth, auth.access.hasAppKeys, let token = await auth.apiToken() else { return list }
        // If the API refuses (a list the app may not read) or fails, the first 100 are kept and flagged.
        do {
            var all: [ImportSourceTrack] = [], skipped = 0, offset = 0
            while true {
                let page = try await fetch(id: link.id, offset: offset, token: token)
                all += page.tracks; skipped += page.skipped
                offset += SpotifyPlaylistAPI.pageSize
                if offset >= page.total || page.tracks.count + page.skipped == 0 { break }
                await pageDelay()
            }
            if all.count + skipped >= list.tracks.count { list.tracks = all; list.skipped = skipped; list.truncated = false }
        } catch { /* keep the embed's first page */ }
        return list
    }

    private func fetch(id: String, offset: Int, token: String) async throws -> (total: Int, tracks: [ImportSourceTrack], skipped: Int) {
        guard let url = URL(string: "https://api.spotify.com/v1/playlists/\(id)/items") else { throw ImportError.notSpotify }
        let d = try await http.get(url, query: ["offset": String(offset), "limit": String(SpotifyPlaylistAPI.pageSize)],
                                   headers: ["Authorization": "Bearer " + token, "Accept": "application/json"])
        return try SpotifyPlaylistAPI.parsePage(d)
    }
}

// MARK: - Export files and CSV

enum SpotifyExportReader {
    /// Reads a file the person picked: a zip, one of the JSON files, or a CSV. Liked Songs comes first, playlists follow in Playlist1, Playlist2, ... Playlist10 order.
    static func lists(fromFile data: Data, name: String) throws -> [ImportList] {
        let ext = (name as NSString).pathExtension.lowercased()
        let stem = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
        switch ext {
        case "zip": return try lists(fromZip: data)
        case "csv": return try lists(fromCSV: data, fileName: stem)
        default: return try lists(fromJSON: data)
        }
    }

    static func lists(fromZip data: Data) throws -> [ImportList] {
        let files = try MiniZip.entries(data) { $0.lowercased().hasSuffix(".json") }
        var playlists: [(Int, [ImportList])] = [], liked: [ImportList] = []
        for (name, bytes) in files {
            guard let found = try? lists(fromJSON: bytes), !found.isEmpty else { continue }
            if found.contains(where: { $0.kind == .liked }) { liked += found.filter { $0.kind == .liked } }
            let n = Int(((name as NSString).lastPathComponent).filter(\.isNumber)) ?? 0
            let rest = found.filter { $0.kind != .liked }
            if !rest.isEmpty { playlists.append((n, rest)) }
        }
        let out = liked + playlists.sorted { $0.0 < $1.0 }.flatMap(\.1)
        if out.isEmpty { throw ImportError.nothingRead }
        return out
    }

    /// Told apart by their keys, not by name: `playlists` is a playlists file, `tracks` or `artists` a library file.
    static func lists(fromJSON data: Data) throws -> [ImportList] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ImportError.unreadable }
        var out: [ImportList] = []
        if let pls = root["playlists"] as? [[String: Any]] {
            for p in pls {
                var tracks: [ImportSourceTrack] = [], skipped = 0
                for item in p.array("items") {
                    if let t = item.dict("track") {
                        guard let title = t.str("trackName")?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { skipped += 1; continue }
                        tracks.append(ImportSourceTrack(spotifyID: trackID(t.str("trackUri")), title: title, artists: t.str("artistName").map { [$0] } ?? [], album: t.str("albumName"), durationMs: nil, explicit: nil))
                    } else if let l = item.dict("localTrack"), let uri = l.str("uri"), let t = SpotifyLocalURI.decode(uri) { tracks.append(t) }
                    else { skipped += 1 }
                }
                if !tracks.isEmpty { out.append(ImportList(kind: .playlist, name: p.str("name") ?? "Imported playlist", owner: nil, coverURL: nil, shareURL: nil, tracks: tracks, skipped: skipped)) }
            }
        }
        // Saved albums and followed artists in the library file are deliberately not imported.
        if root["tracks"] != nil || root["artists"] != nil {
            var tracks: [ImportSourceTrack] = [], skipped = 0
            for t in root.array("tracks") {
                guard let title = t.str("track")?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { skipped += 1; continue }
                tracks.append(ImportSourceTrack(spotifyID: trackID(t.str("uri")), title: title, artists: t.str("artist").map { [$0] } ?? [], album: t.str("album"), durationMs: nil, explicit: nil))
            }
            if !tracks.isEmpty { out.insert(ImportList(kind: .liked, name: "Liked Songs", owner: nil, coverURL: nil, shareURL: nil, tracks: tracks, skipped: skipped), at: 0) }
        }
        return out
    }

    private static func trackID(_ uri: String?) -> String? {
        guard let uri, uri.hasPrefix("spotify:track:") else { return nil }
        let id = String(uri.dropFirst("spotify:track:".count)); return id.isEmpty ? nil : id
    }

    /// Exportify, TuneMyMusic and Soundiiz style files. Header names are lower-cased with non-letters removed ("Artist Name(s)" -> artistnames).
    static func lists(fromCSV data: Data, fileName: String) throws -> [ImportList] {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let rows = CSV.parse(text)
        guard let header = rows.first else { throw ImportError.empty }
        let names = header.map { $0.lowercased().filter(\.isLetter) }
        func col(_ options: [String]) -> Int? { for o in options { if let i = names.firstIndex(of: o) { return i } }; return nil }
        guard let titleCol = col(["trackname", "title", "songname", "name", "song", "track"]) else { throw ImportError.csvColumns }
        let artistCol = col(["artistnames", "artistname", "artists", "artist"]), albumCol = col(["albumname", "album"])
        let durCol = col(["durationms", "trackdurationms", "duration", "length", "time"]), explicitCol = col(["explicit"])
        let uriCol = col(["trackuri", "spotifyid", "spotifyuri", "uri"]), listCol = col(["playlistname", "playlist"])
        var order: [String] = [], byList: [String: [ImportSourceTrack]] = [:], skipped: [String: Int] = [:]
        let fallback = fileName.trimmingCharacters(in: .whitespaces).isEmpty ? "Imported playlist" : fileName
        func cell(_ r: [String], _ i: Int?) -> String { i.flatMap { $0 < r.count ? r[$0].trimmingCharacters(in: .whitespacesAndNewlines) : nil } ?? "" }
        for r in rows.dropFirst() where !r.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let list = cell(r, listCol).isEmpty ? fallback : cell(r, listCol)
            if byList[list] == nil { order.append(list); byList[list] = [] }
            let title = cell(r, titleCol)
            guard !title.isEmpty else { skipped[list, default: 0] += 1; continue }
            let artistCell = cell(r, artistCol)
            let sep: Character = artistCell.contains(";") ? ";" : ","
            let artists = artistCell.split(separator: sep).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let ex = cell(r, explicitCol).lowercased()
            let uri = cell(r, uriCol)
            var id: String?
            if uri.hasPrefix("spotify:track:") { id = String(uri.dropFirst("spotify:track:".count)) }
            else if uri.count == 22, uri.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) { id = uri }
            byList[list]?.append(ImportSourceTrack(spotifyID: id, title: title, artists: artists, album: cell(r, albumCol).isEmpty ? nil : cell(r, albumCol),
                                                   durationMs: duration(cell(r, durCol)), explicit: ["true", "yes", "1"].contains(ex) ? true : ["false", "no", "0"].contains(ex) ? false : nil))
        }
        let out = order.compactMap { n -> ImportList? in
            guard let t = byList[n], !t.isEmpty else { return nil }
            return ImportList(kind: .playlist, name: n, owner: nil, coverURL: nil, shareURL: nil, tracks: t, skipped: skipped[n] ?? 0)
        }
        if out.isEmpty { throw ImportError.nothingRead }
        return out
    }

    /// "m:ss" is minutes and seconds; a bare number above 10,000 is milliseconds, otherwise seconds.
    static func duration(_ s: String) -> Int64? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.contains(":") {
            let p = t.split(separator: ":").compactMap { Int($0) }
            guard p.count >= 2 else { return nil }
            return Int64(p.reduce(0) { $0 * 60 + $1 }) * 1000
        }
        guard let n = Double(t), n > 0 else { return nil }
        return n > 10_000 ? Int64(n) : Int64(n * 1000)
    }
}

enum CSV {
    /// RFC 4180 style: quoted cells, doubled quotes, newlines inside quotes. Rows may have different lengths.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false
        let chars = Array(text.unicodeScalars)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" { if i + 1 < chars.count, chars[i + 1] == "\"" { cell.unicodeScalars.append(c); i += 1 } else { quoted = false } }
                else { cell.unicodeScalars.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(cell); cell = "" }
            else if c == "\n" || c == "\r" {
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                row.append(cell); cell = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else { cell.unicodeScalars.append(c) }
            i += 1
        }
        if !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(row) }
        return rows
    }
}

// MARK: - A small zip reader

/// Reads stored and deflated entries (enough for Spotify's export). No zip64, no encryption; anything else is "unreadable".
enum MiniZip {
    static let maxEntryBytes = 200_000_000

    static func entries(_ data: Data, include: (String) -> Bool) throws -> [(name: String, data: Data)] {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : -1 }
        func u32(_ o: Int) -> Int { o + 4 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 : -1 }
        guard b.count >= 22 else { throw ImportError.unreadable }
        var eocd = -1
        var o = b.count - 22
        while o >= max(0, b.count - 22 - 65_535) { if u32(o) == 0x06054b50 { eocd = o; break }; o -= 1 }
        guard eocd >= 0 else { throw ImportError.unreadable }
        let count = u16(eocd + 10), dirOffset = u32(eocd + 16)
        guard count >= 0, dirOffset >= 0, dirOffset < b.count else { throw ImportError.unreadable }
        var out: [(String, Data)] = []
        var p = dirOffset
        for _ in 0..<count {
            guard u32(p) == 0x02014b50 else { throw ImportError.unreadable }
            let method = u16(p + 10), csize = u32(p + 20), usize = u32(p + 24), nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32), local = u32(p + 42)
            guard nameLen >= 0, p + 46 + nameLen <= b.count, csize >= 0, usize >= 0, local >= 0 else { throw ImportError.unreadable }
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen
            guard !name.hasSuffix("/"), include(name), usize <= maxEntryBytes else { continue }
            guard u32(local) == 0x04034b50 else { throw ImportError.unreadable }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start >= 0, start + csize <= b.count else { throw ImportError.unreadable }
            let raw = Array(b[start..<(start + csize)])
            switch method {
            case 0: out.append((name, Data(raw)))
            case 8:
                var dst = [UInt8](repeating: 0, count: max(usize, 1))
                let n = compression_decode_buffer(&dst, dst.count, raw, raw.count, nil, COMPRESSION_ZLIB)
                guard n > 0 || usize == 0 else { throw ImportError.unreadable }
                out.append((name, Data(dst.prefix(n))))
            default: throw ImportError.unreadable
            }
        }
        return out
    }
}
