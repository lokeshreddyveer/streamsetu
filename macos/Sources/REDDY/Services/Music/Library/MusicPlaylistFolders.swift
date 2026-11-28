import Foundation
import Observation

// Folders for the person's own playlists. A folder only lists which playlists are in it; the playlists themselves are never touched, so deleting a
// folder keeps every playlist, and a library saved before folders existed simply has no folder file. One playlist is in at most one folder.

struct MusicPlaylistFolder: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var playlistIDs: [UUID]
    var created: Date

    init(id: UUID = UUID(), name: String, playlistIDs: [UUID] = [], created: Date = Date()) {
        self.id = id; self.name = name; self.playlistIDs = playlistIDs; self.created = created
    }

    private enum CodingKeys: String, CodingKey { case id, name, playlistIDs, created }

    /// Lenient: a missing field gets a default, so a file from another version never loses the folders.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        playlistIDs = try c.decodeIfPresent([UUID].self, forKey: .playlistIDs) ?? []
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }
}

/// The rules, as pure functions over a list of folders.
enum MusicPlaylistFolderRules {
    /// Trimmed name, or nil when nothing is left.
    static func cleanName(_ raw: String) -> String? {
        let t = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return t.isEmpty ? nil : t
    }

    private static func sameName(_ a: String, _ b: String) -> Bool { MusicLibraryFacets.foldKey(a) == MusicLibraryFacets.foldKey(b) }

    /// Adds an empty folder. A blank name, or a name another folder already has (ignoring case and accents), changes nothing.
    static func creating(_ name: String, in folders: [MusicPlaylistFolder], now: Date = Date()) -> [MusicPlaylistFolder] {
        guard let n = cleanName(name), !folders.contains(where: { sameName($0.name, n) }) else { return folders }
        return folders + [MusicPlaylistFolder(name: n, created: now)]
    }

    static func renaming(_ id: UUID, to name: String, in folders: [MusicPlaylistFolder]) -> [MusicPlaylistFolder] {
        guard let n = cleanName(name), let i = folders.firstIndex(where: { $0.id == id }),
              !folders.contains(where: { $0.id != id && sameName($0.name, n) }) else { return folders }
        var out = folders
        out[i].name = n
        return out
    }

    /// Removes the folder only. The playlists it held are still in the library, now outside any folder.
    static func deleting(_ id: UUID, from folders: [MusicPlaylistFolder]) -> [MusicPlaylistFolder] { folders.filter { $0.id != id } }

    /// Puts a playlist in a folder (taking it out of any other), or out of every folder when `folder` is nil.
    static func moving(_ playlist: UUID, to folder: UUID?, in folders: [MusicPlaylistFolder]) -> [MusicPlaylistFolder] {
        var out = folders.map { f -> MusicPlaylistFolder in
            var f = f
            f.playlistIDs.removeAll { $0 == playlist }
            return f
        }
        if let folder, let i = out.firstIndex(where: { $0.id == folder }) { out[i].playlistIDs.append(playlist) }
        return out
    }

    /// Forgets playlists that no longer exist and playlists listed twice (the first folder keeps it).
    static func pruned(_ folders: [MusicPlaylistFolder], existing: Set<UUID>) -> [MusicPlaylistFolder] {
        var seen = Set<UUID>()
        return folders.map { f in
            var f = f
            f.playlistIDs = f.playlistIDs.filter { existing.contains($0) && seen.insert($0).inserted }
            return f
        }
    }

    static func folder(of playlist: UUID, in folders: [MusicPlaylistFolder]) -> MusicPlaylistFolder? { folders.first { $0.playlistIDs.contains(playlist) } }

    /// The playlists to show for the chosen folder: nil is every playlist, a folder id is its members in library order.
    static func playlists(_ all: [LocalPlaylist], in folder: UUID?, folders: [MusicPlaylistFolder]) -> [LocalPlaylist] {
        guard let folder else { return all }
        let members = Set(folders.first { $0.id == folder }?.playlistIDs ?? [])
        return all.filter { members.contains($0.id) }
    }
}

/// The folders on disk (`playlistFolders.json` next to the other library files) and their changes. Observable so the Library page redraws.
@MainActor @Observable
final class MusicPlaylistFolderBook {
    private(set) var folders: [MusicPlaylistFolder] { didSet { store.save(folders); revision &+= 1 } }
    private(set) var revision = 0
    @ObservationIgnored private let store: MusicJSONStore<[MusicPlaylistFolder]>

    init(directory: URL, debounce: Duration = .seconds(1)) {
        let s = MusicJSONStore<[MusicPlaylistFolder]>(url: directory.appendingPathComponent("playlistFolders.json"), debounce: debounce)
        let loaded = s.load() ?? []
        store = s
        folders = loaded
        MusicDebugLog.log("library", "playlist folders loaded: \(loaded.count)")
    }

    func create(_ name: String) {
        let next = MusicPlaylistFolderRules.creating(name, in: folders)
        if next != folders { folders = next }
    }
    func rename(_ id: UUID, to name: String) {
        let next = MusicPlaylistFolderRules.renaming(id, to: name, in: folders)
        if next != folders { folders = next }
    }
    func delete(_ id: UUID) { folders = MusicPlaylistFolderRules.deleting(id, from: folders) }
    func move(_ playlist: UUID, to folder: UUID?) {
        let next = MusicPlaylistFolderRules.moving(playlist, to: folder, in: folders)
        if next != folders { folders = next }
    }
    /// Called with the playlists that exist now, so a deleted playlist leaves its folder.
    func prune(existing: Set<UUID>) {
        let next = MusicPlaylistFolderRules.pruned(folders, existing: existing)
        if next != folders { folders = next }
    }
    func flush() { store.flush() }
}
