import Foundation

/// The cache files of the country and language Home that Listen Now used to compose (kept for the saved-snapshot tests and cleaned by the privacy wipe): one small JSON file per key
/// under the app's Music cache folder (rebuildable, so the system may clear it). Listen Now's own feed is cached by `HomeFeedCache`.
enum MusicHomeDisk {
    static var folder: URL { MusicStorage.caches.appendingPathComponent("Home", isDirectory: true) }

    static func load(_ key: MusicHomeKey) -> MusicHomeSnapshot? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(key.fileName)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let snap = try? dec.decode(MusicHomeSnapshot.self, from: data), snap.key == key.name else { return nil }
        return snap
    }

    static func save(_ snap: MusicHomeSnapshot, key: MusicHomeKey) {
        let fm = FileManager.default
        MusicStorage.ensureUnbacked(folder)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(snap) else { return }
        try? data.write(to: folder.appendingPathComponent(key.fileName), options: .atomic)
        // Keep the newest few files only.
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(MusicHomeCachePolicy.diskFilesKept) { try? fm.removeItem(at: url) }
    }

    /// The most recently saved Home, whatever its key.
    static func newest() -> MusicHomeSnapshot? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let latest = files.max { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                                  < (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        guard let latest, let data = try? Data(contentsOf: latest) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(MusicHomeSnapshot.self, from: data)
    }

    static func removeAll() { try? FileManager.default.removeItem(at: folder) }
}
