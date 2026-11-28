import Foundation

// Playlist files: writing a playlist as M3U / M3U8 or JSON and reading one back. Reading never throws away what it cannot understand: a line it cannot
// use is skipped, a file it cannot read at all gives an empty result, and every entry keeps what the file said (title, artists, length, where the song was)
// so a later step can match it to a real song.

/// One song as a playlist file names it.
struct MusicPlaylistFileEntry: Equatable, Sendable {
    var title: String
    var artists: [String] = []
    var album: String? = nil
    var durationSeconds: Int? = nil
    /// An address or file path from an M3U line, or the song's own page from a JSON file.
    var location: String? = nil
    var isrc: String? = nil
    /// Set by a StreamSetu JSON file: the song as the app already knew it, so no search is needed.
    var known: MusicTrack? = nil

    var artistLine: String { artists.joined(separator: ", ") }
    var searchText: String { ([artistLine, title].filter { !$0.isEmpty }).joined(separator: " ") }
}

struct MusicPlaylistFile: Equatable, Sendable {
    var name: String?
    var description: String?
    var entries: [MusicPlaylistFileEntry]
}

enum MusicPlaylistFileFormat: String, Sendable, CaseIterable, Identifiable {
    case m3u8, m3u, json
    var id: String { rawValue }
    var fileExtension: String { rawValue }
    var title: String {
        switch self {
        case .m3u8: "M3U8"
        case .m3u: "M3U"
        case .json: "JSON"
        }
    }

    /// The format a file name or its first bytes say it is. JSON starts with `{` or `[`; anything else readable as lines is M3U.
    static func detect(fileName: String, text: String) -> MusicPlaylistFileFormat {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ext == "json" { return .json }
        let head = text.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" }).first
        if head == "{" || head == "[" { return .json }
        return ext == "m3u" ? .m3u : .m3u8
    }
}

// MARK: - M3U

enum MusicPlaylistM3U {
    /// The playlist as extended M3U. M3U8 is the same text, always UTF-8; plain M3U written by this app is UTF-8 too, which every current player reads.
    static func export(name: String, tracks: [MusicTrack]) -> String {
        var out = ["#EXTM3U", "#PLAYLIST:" + oneLine(name)]
        for t in tracks {
            let seconds = t.durationMs > 0 ? Int(t.durationMs / 1000) : -1
            let who = t.artistLine
            out.append("#EXTINF:\(seconds),\(who.isEmpty ? "" : who + " - ")\(oneLine(t.title))")
            if let al = t.album?.title, !al.isEmpty { out.append("#EXTALB:" + oneLine(al)) }
            out.append(location(of: t))
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Where a song is: its own file or page when it has one, otherwise an address of this app's own kind that carries the song's id.
    static func location(of t: MusicTrack) -> String {
        if let s = t.directStreams?.first?.url, !s.isEmpty, URL(string: s)?.isFileURL == true { return s }
        if let u = t.externalURL, !u.isEmpty { return u }
        let id = t.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? t.id
        return "streamsetu://track/\(t.providerID)/\(id)"
    }

    private static func oneLine(_ s: String) -> String { s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") }

    /// Reads M3U / M3U8 text: a byte-order mark and Windows line ends are fine; `#EXTINF` gives the length and "Artist - Title"; `#PLAYLIST` the name; a
    /// song with no `#EXTINF` is named from its file name (`01 - Artist - Title.mp3` reads as Artist and Title).
    static func parse(_ text: String) -> MusicPlaylistFile {
        let clean = text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var name: String?
        var pending: (seconds: Int?, label: String)?
        var album: String?
        var entries: [MusicPlaylistFileEntry] = []
        for raw in clean.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let upper = line.uppercased()
                if upper.hasPrefix("#PLAYLIST:") { name = String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces) }
                else if upper.hasPrefix("#EXTALB:") { album = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
                else if upper.hasPrefix("#EXTINF:") {
                    let body = String(line.dropFirst(8))
                    let comma = body.firstIndex(of: ",")
                    let head = comma.map { String(body[..<$0]) } ?? body
                    let label = comma.map { String(body[body.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""
                    // "123 tvg-id=..." keeps the number; "-1" means unknown.
                    let seconds = Int(head.split(separator: " ").first.map(String.init) ?? "").flatMap { $0 > 0 ? $0 : nil }
                    pending = (seconds, label)
                }
                continue
            }
            var e = split(label: pending?.label ?? "", location: line)
            e.durationSeconds = pending?.seconds
            e.album = album
            e.location = line
            if !e.title.isEmpty { entries.append(e) }
            pending = nil; album = nil
        }
        return MusicPlaylistFile(name: name?.isEmpty == true ? nil : name, description: nil, entries: entries)
    }

    /// "Artist - Title" from a label; the label alone is the title when there is no dash. Without a label the file name is used.
    static func split(label: String, location: String) -> MusicPlaylistFileEntry {
        var text = label.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            let last = location.split(separator: "/").last.map(String.init) ?? location
            let decoded = last.removingPercentEncoding ?? last
            text = (decoded as NSString).deletingPathExtension
            // A leading track number: "01 - ", "01. ", "01_".
            text = text.replacingOccurrences(of: #"^\s*\d{1,3}\s*[-._)]\s*"#, with: "", options: .regularExpression)
        }
        for sep in [" - ", " – ", " — "] {
            if let r = text.range(of: sep) {
                let a = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces), t = String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !a.isEmpty, !t.isEmpty { return MusicPlaylistFileEntry(title: t, artists: [a]) }
            }
        }
        return MusicPlaylistFileEntry(title: text)
    }
}

// MARK: - JSON

enum MusicPlaylistJSON {
    static let formatName = "streamsetu.playlist"

    struct Item: Codable, Equatable, Sendable {
        var title: String
        var artists: [String] = []
        var album: String? = nil
        var durationMs: Int64? = nil
        var isrc: String? = nil
        var providerID: String? = nil
        var id: String? = nil
        var url: String? = nil
    }

    private struct Document: Codable {
        var format: String = MusicPlaylistJSON.formatName
        var version: Int = 1
        var name: String
        var description: String? = nil
        var tracks: [Item]
    }

    static func export(name: String, description: String? = nil, tracks: [MusicTrack]) throws -> Data {
        let items = tracks.map { t in
            Item(title: t.title, artists: t.artists.map(\.name), album: t.album?.title, durationMs: t.durationMs > 0 ? t.durationMs : nil, isrc: t.isrc,
                 providerID: t.providerID, id: t.id, url: t.externalURL)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(Document(name: name, description: description, tracks: items))
    }

    /// Reads a StreamSetu file, or a bare list of songs, or an object with `tracks`/`items` and `name`/`title`: the shapes other tools write. Anything else is empty.
    static func parse(_ data: Data) -> MusicPlaylistFile {
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return MusicPlaylistFile(name: nil, description: nil, entries: []) }
        var name: String?, description: String?
        var rows: [Any] = []
        if let arr = any as? [Any] { rows = arr }
        else if let obj = any as? [String: Any] {
            name = (obj["name"] ?? obj["title"]) as? String
            description = obj["description"] as? String
            rows = (obj["tracks"] ?? obj["items"] ?? obj["songs"]) as? [Any] ?? []
        }
        var entries: [MusicPlaylistFileEntry] = []
        for case let row as [String: Any] in rows {
            let t = (row["title"] ?? row["name"]) as? String ?? ""
            guard !t.isEmpty else { continue }
            var artists: [String] = []
            if let a = row["artists"] as? [String] { artists = a }
            else if let a = row["artists"] as? [[String: Any]] { artists = a.compactMap { $0["name"] as? String } }
            else if let a = (row["artist"] as? String) { artists = [a] }
            let ms = (row["durationMs"] as? NSNumber)?.int64Value ?? (row["duration_ms"] as? NSNumber)?.int64Value
            let secs = ms.map { Int($0 / 1000) } ?? (row["duration"] as? NSNumber).map { Int(truncating: $0) }
            var e = MusicPlaylistFileEntry(title: t, artists: artists, album: (row["album"] as? String) ?? ((row["album"] as? [String: Any])?["name"] as? String),
                                           durationSeconds: secs.flatMap { $0 > 0 ? $0 : nil }, location: row["url"] as? String, isrc: row["isrc"] as? String)
            if let pid = row["providerID"] as? String, let id = row["id"] as? String, !pid.isEmpty, !id.isEmpty {
                e.known = MusicTrack(id: id, providerID: pid, title: t, durationMs: Int64((secs ?? 0) * 1000),
                                     artists: artists.map { MusicArtistRef(id: "", name: $0) }, album: e.album.map { MusicAlbumRef(id: "", title: $0) },
                                     isrc: e.isrc, externalURL: e.location)
            }
            entries.append(e)
        }
        return MusicPlaylistFile(name: name, description: description, entries: entries)
    }
}

// MARK: - Reading a file into songs

/// Turns what a file named into real songs: a StreamSetu JSON entry already is one; anything else is looked up by "artist title" and accepted only when the
/// answer really is that song (title the same, an artist the same, a length close when both are known).
enum MusicPlaylistImporter {
    struct Result: Sendable {
        var found: [MusicTrack] = []
        var missing: [MusicPlaylistFileEntry] = []
    }

    /// How alike a search result is to the entry, 0...1. Title carries most of it, then the artist, then the length.
    static func score(_ entry: MusicPlaylistFileEntry, _ t: MusicTrack) -> Double {
        let wt = MusicText.normalize(entry.title), ct = MusicText.normalize(t.title)
        guard !wt.isEmpty, !ct.isEmpty else { return 0 }
        var s = 0.0
        if wt == ct { s += 0.6 } else if ct.contains(wt) || wt.contains(ct) { s += 0.35 } else { return 0 }
        let wanted = entry.artists.map { MusicText.normalize($0) }.filter { !$0.isEmpty }
        let have = t.artists.map { MusicText.normalize($0.name) }
        if wanted.isEmpty { s += 0.15 }
        else if wanted.contains(where: { w in have.contains { $0 == w || $0.contains(w) || w.contains($0) } }) { s += 0.3 }
        if let sec = entry.durationSeconds, sec > 0, t.durationMs > 0 {
            let d = abs(Double(sec) - Double(t.durationMs) / 1000)
            s += d <= 3 ? 0.1 : d <= 10 ? 0.05 : d > 30 ? -0.2 : 0
        } else { s += 0.05 }
        return max(0, min(1, s))
    }

    /// The best result for an entry at or above `threshold`, or nil.
    static func best(_ entry: MusicPlaylistFileEntry, in results: [MusicTrack], threshold: Double = 0.75) -> MusicTrack? {
        results.compactMap { t -> (MusicTrack, Double)? in
            let s = score(entry, t)
            return s >= threshold ? (t, s) : nil
        }.max { $0.1 < $1.1 }?.0
    }

    /// Looks every entry up (the search closure is the only outside call). Entries are asked a few at a time and the order of the file is kept.
    static func resolve(_ entries: [MusicPlaylistFileEntry], search: @escaping @Sendable (String) async -> [MusicTrack], concurrency: Int = 4) async -> Result {
        var slots: [MusicTrack?] = Array(repeating: nil, count: entries.count)
        await withTaskGroup(of: (Int, MusicTrack?).self) { group in
            var next = 0, running = 0
            func launch() {
                let i = next; next += 1; running += 1
                let e = entries[i]
                group.addTask {
                    if let k = e.known { return (i, k) }
                    let results = await search(e.searchText)
                    return (i, best(e, in: results))
                }
            }
            while next < entries.count && running < concurrency { launch() }
            while let (i, t) = await group.next() {
                running -= 1
                slots[i] = t
                if next < entries.count { launch() }
            }
        }
        var r = Result()
        for (i, t) in slots.enumerated() { if let t { r.found.append(t) } else { r.missing.append(entries[i]) } }
        return r
    }
}
