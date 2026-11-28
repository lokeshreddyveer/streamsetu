import Foundation
import AVFoundation
import CryptoKit

// A health report for the person's own local music: files that are gone or cannot be read, the same recording stored twice (same checksum), albums with tracks or
// discs missing, tags that disagree inside one album, and artwork nothing uses. Read-only: it looks and reports, it never changes a file.

struct MusicHealthFinding: Hashable, Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case missingFile, unreadable, identicalCopies, incompleteAlbum, missingDisc, tagConflict, missingTags, orphanedArtwork, changedFile }
    var id = UUID()
    var kind: Kind
    var title: String
    var detail: String
    var paths: [String] = []
}

enum MusicLibraryHealth {
    // MARK: pure album checks

    private static func albumKey(_ e: LocalEntry) -> String {
        MusicText.normalize(e.albumArtist ?? LocalLibraryIndex.primaryArtist(of: e)) + "|" + MusicText.normalize(e.album)
    }

    /// Albums whose track numbers have gaps (1, 2, 4 has no 3) or whose highest number is more than the files present. Albums the folder stands in for (no album tag) are skipped.
    static func incompleteAlbums(_ entries: [LocalEntry]) -> [MusicHealthFinding] {
        var out: [MusicHealthFinding] = []
        for (_, list) in Dictionary(grouping: entries.filter { $0.albumTagged != false && !$0.album.isEmpty }, by: albumKey) {
            // Each disc is checked on its own.
            for (disc, tracks) in Dictionary(grouping: list, by: { $0.discNumber ?? 1 }) {
                let numbers = Set(tracks.compactMap(\.trackNumber))
                guard let top = numbers.max(), top >= 2, numbers.count >= 1 else { continue }
                let missing = (1...top).filter { !numbers.contains($0) }
                if !missing.isEmpty, missing.count <= max(8, top / 2) {
                    let t = tracks[0]
                    out.append(MusicHealthFinding(kind: .incompleteAlbum, title: t.album,
                                                  detail: Localized.string("Disc %@ is missing track %@.", String(disc), missing.map(String.init).joined(separator: ", ")), paths: tracks.map(\.path)))
                }
            }
        }
        return out.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Albums that name discs 1 and 3 but not 2.
    static func missingDiscs(_ entries: [LocalEntry]) -> [MusicHealthFinding] {
        var out: [MusicHealthFinding] = []
        for (_, list) in Dictionary(grouping: entries.filter { !$0.album.isEmpty }, by: albumKey) {
            let discs = Set(list.compactMap(\.discNumber))
            guard let top = discs.max(), top >= 2 else { continue }
            let gone = (1...top).filter { !discs.contains($0) }
            if !gone.isEmpty {
                out.append(MusicHealthFinding(kind: .missingDisc, title: list[0].album, detail: Localized.string("Disc %@ is missing.", gone.map(String.init).joined(separator: ", ")), paths: list.map(\.path)))
            }
        }
        return out.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Tracks of one album that disagree on the year or genre, and songs with no title or artist at all.
    static func tagConflicts(_ entries: [LocalEntry]) -> [MusicHealthFinding] {
        var out: [MusicHealthFinding] = []
        for (_, list) in Dictionary(grouping: entries.filter { $0.albumTagged != false && !$0.album.isEmpty }, by: albumKey) where list.count > 1 {
            let years = Set(list.compactMap(\.year)), genres = Set(list.compactMap(\.genre).map(MusicText.normalize)), artists = Set(list.compactMap(\.albumArtist).map(MusicText.normalize))
            var notes: [String] = []
            if years.count > 1 { notes.append(Localized.string("different years (%@)", years.sorted().map(String.init).joined(separator: ", "))) }
            if genres.count > 1 { notes.append(Localized.string("different genres")) }
            if artists.count > 1 { notes.append(Localized.string("different album artists")) }
            if !notes.isEmpty { out.append(MusicHealthFinding(kind: .tagConflict, title: list[0].album, detail: notes.joined(separator: ", "), paths: list.map(\.path))) }
        }
        let bare = entries.filter { $0.title.trimmingCharacters(in: .whitespaces).isEmpty || $0.artist.trimmingCharacters(in: .whitespaces).isEmpty }
        if !bare.isEmpty {
            out.append(MusicHealthFinding(kind: .missingTags, title: Localized.plural(bare.count, one: "%@ song has no title or artist", other: "%@ songs have no title or artist"), detail: "", paths: bare.map(\.path)))
        }
        return out.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Picture files in the artwork cache that no song points at.
    static func orphanedArtwork(_ entries: [LocalEntry], artworkDirectory: URL) -> [MusicHealthFinding] {
        let used = Set(entries.compactMap(\.artworkFile))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: artworkDirectory.path)) ?? []
        let orphans = files.filter { !used.contains($0) && !$0.hasPrefix(".") }
        guard !orphans.isEmpty else { return [] }
        return [MusicHealthFinding(kind: .orphanedArtwork, title: Localized.plural(orphans.count, one: "%@ cover picture is not used by any song", other: "%@ cover pictures are not used by any song"), detail: "",
                                   paths: orphans.map { artworkDirectory.appendingPathComponent($0).path })]
    }

    static func missingFiles(_ entries: [LocalEntry]) -> [MusicHealthFinding] {
        entries.filter { !FileManager.default.fileExists(atPath: $0.path) }.map {
            MusicHealthFinding(kind: .missingFile, title: $0.title, detail: $0.path, paths: [$0.path])
        }
    }

    // MARK: file checks (read the files)

    static func sha256(of url: URL, isCancelled: () -> Bool) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            if isCancelled() { return nil }
            guard let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// True when the system can open the file as audio with a length.
    static func isReadable(_ url: URL) async -> Bool {
        let a = AVURLAsset(url: url)
        guard let ok = try? await a.load(.isPlayable), ok, let d = try? await a.load(.duration), d.seconds.isFinite, d.seconds > 0 else { return false }
        return true
    }

    struct Progress: Sendable { var done: Int; var total: Int; var step: String }

    /// The whole report. `deep` also opens every file (readable? checksum?), which takes a while; without it only the tags and the folder are looked at.
    static func run(entries: [LocalEntry], artworkDirectory: URL, deep: Bool, manifest: MusicChecksumManifest, progress: @Sendable (Progress) -> Void, isCancelled: @Sendable () -> Bool) async -> [MusicHealthFinding] {
        var out: [MusicHealthFinding] = []
        progress(Progress(done: 0, total: entries.count, step: Localized.string("Looking for missing files")))
        let present = entries.filter { FileManager.default.fileExists(atPath: $0.path) }
        out += missingFiles(entries)
        out += incompleteAlbums(present) + missingDiscs(present) + tagConflicts(present) + orphanedArtwork(present, artworkDirectory: artworkDirectory)
        guard deep else { return out }
        var byHash: [String: [LocalEntry]] = [:]
        var changed: [MusicHealthFinding] = []
        for (i, e) in present.enumerated() {
            if isCancelled() { return out }
            progress(Progress(done: i, total: present.count, step: Localized.string("Checking files")))
            let url = URL(fileURLWithPath: e.path)
            if !(await isReadable(url)) {
                out.append(MusicHealthFinding(kind: .unreadable, title: e.title, detail: Localized.string("This file cannot be opened as audio. It may be damaged."), paths: [e.path]))
                continue
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: e.path)
            let size = (attrs?[.size] as? Int64) ?? 0, mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            guard let h = sha256(of: url, isCancelled: isCancelled) else { continue }
            byHash[h, default: []].append(e)
            if let prev = manifest.record(e.path), prev.size == size, abs(prev.mtime - mtime) < 1, prev.sha256 != h {
                changed.append(MusicHealthFinding(kind: .changedFile, title: e.title, detail: Localized.string("The contents changed although the file's date did not. This can mean silent corruption."), paths: [e.path]))
            }
            manifest.set(e.path, .init(size: size, mtime: mtime, sha256: h))
            await Task.yield()
        }
        manifest.save()
        out += changed
        for (_, list) in byHash where list.count > 1 {
            out.append(MusicHealthFinding(kind: .identicalCopies, title: list[0].title, detail: Localized.plural(list.count, one: "%@ identical file", other: "%@ identical files"), paths: list.map(\.path)))
        }
        return out
    }
}

/// The checksum of each file the last deep check saw, so the next one can tell when a file changed without its date changing.
final class MusicChecksumManifest: @unchecked Sendable {
    struct Record: Codable, Sendable { var size: Int64; var mtime: Double; var sha256: String }
    static let shared = MusicChecksumManifest(url: MusicStorage.subfolder("maintenance").appendingPathComponent("checksums.json"))
    private let url: URL
    private let lock = NSLock()
    private var records: [String: Record]
    init(url: URL) {
        self.url = url
        records = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
    }
    func record(_ path: String) -> Record? { lock.lock(); defer { lock.unlock() }; return records[path] }
    func set(_ path: String, _ r: Record) { lock.lock(); records[path] = r; lock.unlock() }
    func save() { lock.lock(); defer { lock.unlock() }; if let d = try? JSONEncoder().encode(records) { try? d.write(to: url, options: .atomic) } }
}

// MARK: inventory export

enum MusicInventoryExport {
    private static func cell(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\"", with: "\"\"")
        // A cell that starts like a formula is quoted with a leading apostrophe so a spreadsheet does not run it.
        let safe = (t.first.map { "=+-@".contains($0) } ?? false) ? "'" + t : t
        return "\"" + safe + "\""
    }

    static func csv(_ entries: [LocalEntry]) -> String {
        var rows = ["Title,Artist,Album,Album artist,Track,Disc,Year,Genre,Length (s),Format,Path"]
        for e in entries.sorted(by: { ($0.albumArtist ?? $0.artist, $0.album, $0.discNumber ?? 1, $0.trackNumber ?? 0) < ($1.albumArtist ?? $1.artist, $1.album, $1.discNumber ?? 1, $1.trackNumber ?? 0) }) {
            rows.append([e.title, e.artist, e.album, e.albumArtist ?? "", e.trackNumber.map(String.init) ?? "", e.discNumber.map(String.init) ?? "", e.year.map(String.init) ?? "",
                         e.genre ?? "", String(e.durationMs / 1000), e.ext, e.path].map(cell).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }
}

// MARK: rename and folder templates

enum MusicRenameTemplate {
    static let defaultTemplate = "{albumartist}/{album}/{disc}{track} - {title}"
    static let tokens = ["{artist}", "{albumartist}", "{album}", "{title}", "{track}", "{disc}", "{year}", "{genre}"]

    /// Characters a file name cannot carry are replaced; a dot or space cannot lead or trail a name; an empty part becomes "Unknown".
    static func clean(_ s: String) -> String {
        let bad: Set<Character> = ["/", ":", "\\", "*", "?", "\"", "<", ">", "|"]
        var t = String(s.map { bad.contains($0) || $0.isNewline ? "_" : $0 })
        t = t.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix(".") { t.removeFirst() }
        while t.hasSuffix(".") { t.removeLast() }
        return t.isEmpty ? "Unknown" : String(t.prefix(120))
    }

    /// The new path inside the music folder, without the extension. Disc shows as "1-" only when the album has more than one disc, track as two digits.
    static func path(for e: LocalEntry, template: String, multiDisc: Bool) -> String {
        let values: [String: String] = [
            "{artist}": e.artist, "{albumartist}": e.albumArtist ?? LocalLibraryIndex.primaryArtist(of: e), "{album}": e.album, "{title}": e.title,
            "{track}": e.trackNumber.map { String(format: "%02d", $0) } ?? "", "{disc}": multiDisc ? (e.discNumber.map { "\($0)-" } ?? "1-") : "",
            "{year}": e.year.map(String.init) ?? "", "{genre}": e.genre ?? "",
        ]
        var out = template
        for (k, v) in values { out = out.replacingOccurrences(of: k, with: k == "{track}" || k == "{disc}" ? v : clean(v)) }
        return out.split(separator: "/", omittingEmptySubsequences: true).map { clean(String($0)) }.joined(separator: "/")
    }

    struct Move: Hashable, Identifiable, Sendable {
        var from: String
        var to: String
        var id: String { from }
    }

    /// What would move. Songs already in place, locked songs, and moves that would land on an existing file or on each other are left out of the plan.
    static func plan(_ entries: [LocalEntry], root: String, template: String, locked: Set<String>) -> (moves: [Move], skipped: Int) {
        let multi = Dictionary(grouping: entries, by: { MusicText.normalize($0.album) }).mapValues { Set($0.compactMap(\.discNumber)).count > 1 }
        var taken = Set(entries.map(\.path)), moves: [Move] = [], skipped = 0
        for e in entries {
            if locked.contains(e.path) { skipped += 1; continue }
            let rel = path(for: e, template: template, multiDisc: multi[MusicText.normalize(e.album)] ?? false)
            let target = (root as NSString).appendingPathComponent(rel + "." + e.ext)
            if target == e.path { continue }
            if taken.contains(target) { skipped += 1; continue }
            taken.remove(e.path); taken.insert(target)
            moves.append(Move(from: e.path, to: target))
        }
        return (moves, skipped)
    }
}
