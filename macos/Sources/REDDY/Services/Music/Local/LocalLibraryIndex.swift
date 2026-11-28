import Foundation
import CryptoKit

// The pure half of the local files source: what an indexed file looks like, how entries group into albums and artists, how a search ranks them,
// and which files an incremental rescan must read again. Nothing here touches the disk or AVFoundation, so it is all unit tested.

struct LocalEntry: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var folderID: String
    var path: String
    var title: String
    var artist: String
    var album: String
    var trackNumber: Int?
    var durationMs: Int64
    var modified: Date
    /// File name inside the artwork cache folder, when the file carries a picture.
    var artworkFile: String?
    var ext: String
    /// Optional so an index written before these fields existed still decodes.
    var albumArtist: String? = nil
    var discNumber: Int? = nil
    /// False when the file has no album tag and the folder stands in as the album.
    var albumTagged: Bool? = nil
    /// Credits the file's tags carry (ID3 / MP4). Optional so an index written before these fields existed still decodes; they fill on the next read of a file.
    var composer: String? = nil
    var lyricist: String? = nil
    var conductor: String? = nil
    /// The classical work or grouping tag.
    var work: String? = nil
    /// Set from the person's own edit in the library; the file's tags are not changed.
    var genre: String? = nil
    var year: Int? = nil

    var folderPath: String { (path as NSString).deletingLastPathComponent }
}

struct LocalAlbumGroup: Hashable, Sendable, Identifiable {
    var id: String; var title: String; var artist: String; var entries: [LocalEntry]
    var artworkFile: String? { entries.compactMap(\.artworkFile).first }
}

struct LocalArtistGroup: Hashable, Sendable, Identifiable {
    var id: String; var name: String; var entries: [LocalEntry]
    var artworkFile: String? { entries.compactMap(\.artworkFile).first }
}

struct LocalSearchHits: Sendable {
    var tracks: [LocalEntry]; var albums: [LocalAlbumGroup]; var artists: [LocalArtistGroup]
}

struct LocalLibraryIndex: Codable, Sendable {
    var version = 1
    var entries: [LocalEntry] = []
    /// The rules that produced the entries. A different number means everything is read again on the next scan.
    var scanVersion: Int? = nil
    /// Per chosen folder: the modified time each directory had when it was last listed (directory path -> date). A directory whose time has not moved is not listed again.
    var folderStamps: [String: [String: Date]]? = nil
    /// Per chosen folder: files read once and left out because they are under 30 seconds (file path -> modified time then), so a rescan does not open them again.
    var skippedShort: [String: [String: Date]]? = nil

    /// Bump whenever the title, artist or album-key rules change.
    static let currentScanVersion = 2

    static let unknownArtist = "Unknown Artist"
    static let unknownAlbum = "Unknown Album"
    static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "flac", "wav", "aiff", "aif", "opus"]

    // MARK: ids

    private static func digest(_ s: String) -> String {
        MusicHash.sha256(s, prefix: 12)
    }
    static func trackID(path: String) -> String { digest("t|" + path) }
    static func artistID(_ name: String) -> String { digest("r|" + normalize(name)) }
    static func albumID(album: String, artist: String) -> String { digest("a|" + normalize(album) + "|" + normalize(artist)) }

    /// Lowercase, accent-free, punctuation-free text for comparing and searching (`MusicText`).
    static func normalize(_ s: String) -> String { MusicText.normalize(s) }

    // MARK: album keys

    /// 48 low bits of FNV-1a (64 bit) as 12 hex digits. A fixed hash, because album keys are stored in shortcuts and must not change between releases.
    static func fnv12(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(format: "%012llx", h & 0xFFFF_FFFF_FFFF)
    }

    /// Lowercase; letters and digits of any script and "-" kept, everything else "-". Capped at 80 characters; a longer raw string gets a digest appended.
    static func sanitizeKey(_ raw: String) -> String {
        let mapped = String(raw.lowercased().unicodeScalars.map { (CharacterSet.alphanumerics.contains($0) || $0 == "-") ? Character($0) : "-" })
        guard raw.count > 80 else { return mapped }
        return String(mapped.prefix(80)) + fnv12(raw)
    }

    /// The album a file belongs to. With an album artist tag the key is artist + album; with no album artist it is based on the folder, so a compilation stays one
    /// album and two same-named albums in different folders stay apart. With no album tag the folder is the album.
    static func albumKey(of e: LocalEntry) -> String {
        let folder = e.folderPath
        if e.albumTagged == false { return "dir-" + fnv12(folder) + "-" + sanitizeKey((folder as NSString).lastPathComponent) }
        if let aa = e.albumArtist?.trimmingCharacters(in: .whitespaces), !aa.isEmpty { return sanitizeKey(aa + "--" + e.album) }
        return "dir-" + fnv12(folder) + "-" + sanitizeKey(e.album)
    }

    // MARK: grouping

    /// Album credit: the album artist when every tagged track agrees, else the one artist when all tracks share it, else "Various artists".
    static func albumCredit(_ list: [LocalEntry]) -> String {
        let tagged = Set(list.compactMap { $0.albumArtist?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        if tagged.count == 1, let a = tagged.first { return a }
        if tagged.isEmpty {
            let artists = Set(list.map { normalize($0.artist) })
            if artists.count == 1, let first = list.first { return first.artist }
        }
        return "Various artists"
    }

    func albums() -> [LocalAlbumGroup] {
        Dictionary(grouping: entries) { Self.albumKey(of: $0) }
            .map { id, list in
                let sorted = list.sorted(by: Self.trackOrder)
                return LocalAlbumGroup(id: id, title: sorted[0].album, artist: Self.albumCredit(sorted), entries: sorted)
            }
            .sorted { $0.title.lowercased() != $1.title.lowercased() ? $0.title.lowercased() < $1.title.lowercased() : $0.id < $1.id }
    }

    /// The artist a file is filed under: the primary name (cut at ";" and featuring markers; commas and "&" sit inside real names and are kept).
    static func primaryArtist(of e: LocalEntry) -> String { LocalArtistName.primary(e.artist) ?? e.artist }

    func artists() -> [LocalArtistGroup] {
        Dictionary(grouping: entries) { Self.artistID(Self.primaryArtist(of: $0)) }
            .map { id, list in LocalArtistGroup(id: id, name: Self.primaryArtist(of: list[0]), entries: list.sorted(by: Self.trackOrder)) }
            .sorted { Self.normalize($0.name) < Self.normalize($1.name) }
    }

    func entry(id: String) -> LocalEntry? { entries.first { $0.id == id } }
    /// Also accepts the id an older release gave the album, so a saved reference keeps working.
    func album(id: String) -> LocalAlbumGroup? {
        let all = albums()
        return all.first { $0.id == id } ?? all.first { g in g.entries.contains { Self.albumID(album: $0.album, artist: $0.artist) == id } }
    }
    func artist(id: String) -> LocalArtistGroup? {
        let all = artists()
        return all.first { $0.id == id } ?? all.first { g in g.entries.contains { Self.artistID($0.artist) == id } }
    }
    /// The albums that hold at least one file by this artist.
    func albums(of artist: LocalArtistGroup) -> [LocalAlbumGroup] {
        let keys = Set(artist.entries.map { Self.albumKey(of: $0) })
        return albums().filter { keys.contains($0.id) }
    }

    /// Album title, then album artist (or the folder when untagged, so CD1 sorts before CD2), disc, folder, track number, title.
    static func trackOrder(_ a: LocalEntry, _ b: LocalEntry) -> Bool {
        func key(_ e: LocalEntry) -> (String, String, Int, String, Int, String) {
            let aa = e.albumArtist.map(normalize) ?? ""
            return (normalize(e.album), aa.isEmpty ? e.folderPath : aa, e.discNumber ?? 0, e.folderPath, e.trackNumber ?? Int.max, normalize(e.title))
        }
        let x = key(a), y = key(b)
        if x.0 != y.0 { return x.0 < y.0 }
        if x.1 != y.1 { return x.1 < y.1 }
        if x.2 != y.2 { return x.2 < y.2 }
        if x.3 != y.3 { return x.3 < y.3 }
        if x.4 != y.4 { return x.4 < y.4 }
        if x.5 != y.5 { return x.5 < y.5 }
        return a.path < b.path
    }

    // MARK: search

    /// Every word of the query must appear in the title, artist or album. Title hits rank first.
    func search(_ query: String, limit: Int = 50) -> LocalSearchHits {
        let words = Self.normalize(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return LocalSearchHits(tracks: [], albums: [], artists: []) }
        func score(_ e: LocalEntry) -> Int? {
            let t = Self.normalize(e.title), a = Self.normalize(e.artist), b = Self.normalize(e.album)
            var s = 0
            for w in words {
                if t.contains(w) { s += 3 } else if a.contains(w) { s += 2 } else if b.contains(w) { s += 1 } else { return nil }
            }
            // A single word that is the whole title, or starts it, outranks a word found somewhere inside.
            if words.count == 1, let w = words.first { if t == w { s += 20 } else if t.hasPrefix(w) { s += 10 } }
            return s
        }
        let scored = entries.compactMap { e in score(e).map { (e, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : Self.trackOrder($0.0, $1.0) }
        let tracks = scored.prefix(limit).map(\.0)
        func matches(_ text: String) -> Bool { let n = Self.normalize(text); return words.allSatisfy { n.contains($0) } }
        let albums = self.albums().filter { matches($0.title + " " + $0.artist) }.prefix(limit)
        // An artist matches when the name or any of their files matches the whole query ("etoiles night" = artist + album words).
        let artists = self.artists().filter { g in matches(g.name) || g.entries.contains { score($0) != nil } }.prefix(limit)
        return LocalSearchHits(tracks: Array(tracks), albums: Array(albums), artists: Array(artists))
    }

    /// The best file for a track that came from another source (title and artist must agree; duration breaks ties).
    func match(title: String, artist: String, durationMs: Int64?) -> LocalEntry? {
        let t = Self.normalize(title), a = Self.normalize(artist)
        guard !t.isEmpty else { return nil }
        let candidates = entries.filter { Self.normalize($0.title) == t && (a.isEmpty || Self.normalize($0.artist).contains(a) || a.contains(Self.normalize($0.artist))) }
        guard let d = durationMs, d > 0 else { return candidates.first }
        return candidates.min { abs($0.durationMs - d) < abs($1.durationMs - d) }
    }

    // MARK: rescans

    struct RescanPlan: Equatable, Sendable { var toRead: [String]; var removed: [String] }

    /// Files that are new or changed since the last scan must be read again; indexed files that no longer exist are dropped.
    static func plan(known: [String: Date], found: [String: Date], skipped: [String: Date] = [:]) -> RescanPlan {
        var toRead: [String] = []
        for (path, modified) in found {
            if let old = known[path], abs(old.timeIntervalSince(modified)) < 1 { continue }
            if let old = skipped[path], abs(old.timeIntervalSince(modified)) < 1 { continue }
            toRead.append(path)
        }
        let removed = known.keys.filter { found[$0] == nil }
        return RescanPlan(toRead: toRead.sorted(), removed: removed.sorted())
    }

    mutating func apply(folderID: String, read: [LocalEntry], removed: Set<String>) {
        let replaced = Set(read.map(\.path))
        entries.removeAll { $0.folderID == folderID && (replaced.contains($0.path) || removed.contains($0.path)) }
        entries.append(contentsOf: read)
    }

    mutating func removeFolder(_ id: String) {
        entries.removeAll { $0.folderID == id }
        folderStamps?[id] = nil
        skippedShort?[id] = nil
    }

    func stamps(in folderID: String) -> [String: Date] { folderStamps?[folderID] ?? [:] }
    func skipped(in folderID: String) -> [String: Date] { skippedShort?[folderID] ?? [:] }

    /// Forgets every directory stamp (all chosen folders, or one) and the short-file memory, so the next scan lists every directory again.
    mutating func forgetStamps(folderID: String? = nil) {
        if let folderID { folderStamps?[folderID] = nil; skippedShort?[folderID] = nil } else { folderStamps = nil; skippedShort = nil }
    }
    func known(in folderID: String) -> [String: Date] {
        Dictionary(entries.filter { $0.folderID == folderID }.map { ($0.path, $0.modified) }, uniquingKeysWith: { a, _ in a })
    }
    func count(in folderID: String) -> Int { entries.reduce(0) { $0 + ($1.folderID == folderID ? 1 : 0) } }
}

// MARK: tag text helpers

enum LocalTagText {
    /// "3", "3/12" or " 03 " -> 3. Anything else is nil.
    static func trackNumber(_ s: String) -> Int? {
        let head = s.split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard let n = Int(head), n > 0, n < 1000 else { return nil }
        return n
    }

    /// A title from a file name when the file has no tags: "07 - Song Name.mp3" -> "Song Name".
    static func title(fromFileName name: String) -> String {
        var base = (name as NSString).deletingPathExtension
        if let r = base.range(of: #"^\s*\d{1,3}(?!\d)\s*[-._)]*\s*"#, options: .regularExpression), r.upperBound < base.endIndex { base.removeSubrange(r) }
        let t = base.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? name : t
    }

    /// "Artist - Title" from a file name, split at the FIRST " - " and only when both halves are not empty. Otherwise the whole name is the title.
    static func artistAndTitle(fromFileName name: String) -> (artist: String?, title: String) {
        var base = (name as NSString).deletingPathExtension
        if let r = base.range(of: #"^\s*\d{1,3}(?!\d)\s*[-._)]*\s*"#, options: .regularExpression), r.upperBound < base.endIndex { base.removeSubrange(r) }
        base = base.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        if let r = base.range(of: " - ") {
            let a = base[..<r.lowerBound].trimmingCharacters(in: .whitespaces), t = base[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if !a.isEmpty, !t.isEmpty { return (a, t) }
        }
        return (nil, base.isEmpty ? name : base)
    }

    static let coverFileNames = ["cover.jpg", "cover.png", "folder.jpg", "folder.png", "front.jpg", "album.jpg"]

    static func codec(forExtension ext: String) -> (codec: String, container: String) {
        switch ext.lowercased() {
        case "mp3": ("mp3", "mp3")
        case "m4a": ("aac", "m4a")
        case "aac": ("aac", "aac")
        case "flac": ("flac", "flac")
        case "wav": ("pcm", "wav")
        case "aiff", "aif": ("pcm", "aiff")
        case "m4b": ("aac", "m4a")
        case "opus": ("opus", "ogg")
        default: (ext.lowercased(), ext.lowercased())
        }
    }
}


enum LocalArtistName {
    /// The primary artist of a credit line: cut at ";" and at the featuring markers, never at "," or "&". Nil when nothing usable is left.
    static func primary(_ line: String) -> String? { MusicStatsRules.leadName(line) }
}

/// Which files are not music: alarms, ringtones, voice memos, notification sounds, podcasts and audiobooks, and anything shorter than half a minute.
enum LocalScanFilter {
    static let minimumMs: Int64 = 30_000
    static let pathSegments: [String] = [
        "/alarms/", "/alarm/", "/notifications/", "/notification/", "/ringtones/", "/ringtone/", "/podcasts/", "/podcast/", "/audiobooks/", "/audiobook/",
        "/recordings/", "/voice recorder/", "/voice memos/", "/voice memo/", "/voicememos/", "/sound_recorder/", "/call_rec/", "/call recordings/",
        "/whatsapp voice notes/"
    ]

    /// True for a path under one of the non-music folders.
    static func isNonMusicPath(_ path: String) -> Bool {
        let p = path.lowercased().replacingOccurrences(of: "\\", with: "/") + "/"
        return pathSegments.contains { p.contains($0) }
    }

    /// Whether to index a file found by the walk (before it is read). `m4b` files are audiobooks and stay out unless asked for.
    static func keepsPath(_ path: String, includeAudiobooks: Bool = false) -> Bool {
        if !includeAudiobooks, (path as NSString).pathExtension.lowercased() == "m4b" { return false }
        return !isNonMusicPath(path)
    }

    /// Whether to keep a file after it is read: a known length under 30 seconds is a sound effect or a memo.
    static func keepsDuration(_ durationMs: Int64) -> Bool { durationMs <= 0 || durationMs >= minimumMs }
}
