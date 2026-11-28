import Foundation

// Safety rails for the person's own music files. The collection is READ-ONLY by default: Music never changes a file until the person turns writing on. Every change that
// is allowed first keeps a copy of the original (the tag backup), is written into a journal (what changed, when, from where: the provenance), and can be undone. A file the
// person locked is never touched, whatever the switch says.

enum MusicCollectionSafety {
    static let readOnlyKey = "music.collection.readOnly"
    static let backupKey = "music.collection.keepBackups"
    static let locksKey = "music.collection.locks"

    /// Read-only unless the person said otherwise.
    static func isReadOnly(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: readOnlyKey) == nil ? true : d.bool(forKey: readOnlyKey) }
    static func keepsBackups(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: backupKey) == nil ? true : d.bool(forKey: backupKey) }

    static func locks(_ d: UserDefaults = .standard) -> Set<String> { Set(d.stringArray(forKey: locksKey) ?? []) }
    static func isLocked(_ path: String, _ d: UserDefaults = .standard) -> Bool { locks(d).contains(path) }
    static func setLocked(_ paths: [String], _ on: Bool, _ d: UserDefaults = .standard) {
        var l = locks(d)
        for p in paths { if on { l.insert(p) } else { l.remove(p) } }
        d.set(Array(l).sorted(), forKey: locksKey)
    }

    enum Verdict: Equatable, Sendable { case allowed, readOnly, locked }
    /// Whether a file may be written right now.
    static func verdict(for path: String, _ d: UserDefaults = .standard) -> Verdict {
        if isReadOnly(d) { return .readOnly }
        if isLocked(path, d) { return .locked }
        return .allowed
    }
}

/// One journalled change to a file: the provenance of its current tags, and the copy that undoes it.
struct MusicChangeRecord: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case tags, rename }
    var id = UUID()
    var kind: Kind
    var path: String
    /// Rename: the path before. Tags: the same as `path`.
    var oldPath: String
    /// File name of the backup copy inside the backups folder (tag changes only).
    var backupFile: String?
    var summary: String
    var at = Date()
    var undone = false
}

/// The journal and the backup copies, on this device (Application Support). Bounded in size and age, so it never grows without end.
final class MusicChangeJournal: @unchecked Sendable {
    static let shared = MusicChangeJournal(directory: MusicStorage.subfolder("maintenance"))
    static let maxRecords = 2000
    static let maxBackupBytes: Int64 = 3_000_000_000
    static let maxAge: TimeInterval = 90 * 86_400

    private let dir: URL
    private let lock = NSLock()
    private var records: [MusicChangeRecord]

    init(directory: URL) {
        dir = directory
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("backups"), withIntermediateDirectories: true)
        records = (try? Data(contentsOf: directory.appendingPathComponent("journal.json"))).flatMap { try? JSONDecoder().decode([MusicChangeRecord].self, from: $0) } ?? []
    }

    var all: [MusicChangeRecord] { lock.lock(); defer { lock.unlock() }; return records.sorted { $0.at > $1.at } }

    private func save() {
        if let d = try? JSONEncoder().encode(records) { try? d.write(to: dir.appendingPathComponent("journal.json"), options: .atomic) }
    }

    private func backupURL(_ name: String) -> URL { dir.appendingPathComponent("backups").appendingPathComponent(name) }

    /// Copies the file aside before it is changed. Nil when backups are off or the copy failed (the caller then does not write).
    func backup(of file: URL, summary: String, keep: Bool = true) -> MusicChangeRecord? {
        var name: String?
        if keep {
            let n = UUID().uuidString + "." + file.pathExtension
            do { try FileManager.default.copyItem(at: file, to: backupURL(n)); name = n } catch { return nil }
        }
        let r = MusicChangeRecord(kind: .tags, path: file.path, oldPath: file.path, backupFile: name, summary: summary)
        lock.lock(); records.append(r); prune(); save(); lock.unlock()
        return r
    }

    func noteRename(from old: String, to new: String) -> MusicChangeRecord {
        let r = MusicChangeRecord(kind: .rename, path: new, oldPath: old, backupFile: nil, summary: (new as NSString).lastPathComponent)
        lock.lock(); records.append(r); prune(); save(); lock.unlock()
        return r
    }

    /// Forgets a record whose write did not happen (and its backup copy).
    func discard(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if let i = records.firstIndex(where: { $0.id == id }) {
            if let b = records[i].backupFile { try? FileManager.default.removeItem(at: backupURL(b)) }
            records.remove(at: i); save()
        }
    }

    /// Undoes one record: puts the original file back (tags) or moves the file to where it was (rename). False when it cannot be done any more.
    @discardableResult
    func undo(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let i = records.firstIndex(where: { $0.id == id }), !records[i].undone else { return false }
        let r = records[i]
        let fm = FileManager.default
        do {
            switch r.kind {
            case .tags:
                guard let b = r.backupFile, fm.fileExists(atPath: backupURL(b).path) else { return false }
                _ = try fm.replaceItemAt(URL(fileURLWithPath: r.path), withItemAt: fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + (r.path as NSString).pathExtension).appendingCopy(of: backupURL(b)))
            case .rename:
                guard fm.fileExists(atPath: r.path), !fm.fileExists(atPath: r.oldPath) else { return false }
                try fm.createDirectory(atPath: (r.oldPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: r.path, toPath: r.oldPath)
            }
        } catch { return false }
        records[i].undone = true
        save()
        return true
    }

    /// Oldest first out: past the age limit, past the record limit, or past the backup size.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        func drop(_ r: MusicChangeRecord) { if let b = r.backupFile { try? FileManager.default.removeItem(at: backupURL(b)) } }
        for r in records where r.at < cutoff { drop(r) }
        records.removeAll { $0.at < cutoff }
        while records.count > Self.maxRecords { drop(records.removeFirst()) }
        var total: Int64 = 0
        for r in records.reversed() {
            guard let b = r.backupFile, let n = (try? FileManager.default.attributesOfItem(atPath: backupURL(b).path))?[.size] as? Int64 else { continue }
            total += n
            if total > Self.maxBackupBytes { drop(r); if let k = records.firstIndex(where: { $0.id == r.id }) { records[k].backupFile = nil } }
        }
    }
}

private extension URL {
    /// A copy of `source` at this URL; returns self so it can be chained.
    func appendingCopy(of source: URL) -> URL { try? FileManager.default.copyItem(at: source, to: self); return self }
}
