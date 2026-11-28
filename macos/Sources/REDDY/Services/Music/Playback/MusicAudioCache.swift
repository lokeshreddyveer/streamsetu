import Foundation
import CryptoKit

/// The pure bookkeeping of a least-recently-used file cache. It knows sizes and times only, never the disk, so it can be tested directly.
struct MusicLRUIndex: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var name: String
        var size: Int64
        var lastUsed: Date
    }

    private(set) var entries: [String: Entry] = [:]

    var totalBytes: Int64 { entries.values.reduce(0) { $0 + $1.size } }
    var count: Int { entries.count }

    mutating func insert(name: String, size: Int64, at date: Date) {
        entries[name] = Entry(name: name, size: max(0, size), lastUsed: date)
    }

    mutating func touch(_ name: String, at date: Date) {
        entries[name]?.lastUsed = date
    }

    mutating func remove(_ name: String) { entries[name] = nil }
    mutating func removeAll() { entries = [:] }

    /// The names to delete, oldest first, so that the total fits under `limit`. An entry whose name starts with a protected stem is never
    /// listed, even when that leaves the cache over its limit (the track being played must keep playing).
    func evictionList(limit: Int64, protectedStem: String?, alsoProtected: Set<String> = []) -> [String] {
        var total = totalBytes
        guard total > limit else { return [] }
        var out: [String] = []
        for e in entries.values.sorted(by: { ($0.lastUsed, $0.name) < ($1.lastUsed, $1.name) }) {
            if total <= limit { break }
            if let p = protectedStem, MusicAudioCache.stem(of: e.name) == p { continue }
            if alsoProtected.contains(MusicAudioCache.stem(of: e.name)) { continue }
            out.append(e.name)
            total -= e.size
        }
        return out
    }
}

/// On-disk cache of played audio, keyed by track uid and quality. Off until `configure` enables it. Files are written to a `.part` file
/// and renamed into place only when complete, so a half-written file is never played. The size accounting is rebuilt from the folder
/// the first time it is needed after launch, which costs nothing while music is not in use.
final class MusicAudioCache: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var index = MusicLRUIndex()
    private var loaded = false
    private var enabled = false
    private var limitBytes: Int64 = 500 * 1_048_576
    private var protectedStem: String?
    /// Songs waiting for Automix analysis: their files are kept (up to a size budget) because analysis can only read a finished file.
    private var pinnedStems: Set<String> = []
    private var activeWriters: Set<String> = []

    init(directory: URL) { self.directory = directory }

    static func defaultDirectory(under base: URL) -> URL {
        base.appendingPathComponent("cache", isDirectory: true)
    }

    // MARK: naming (pure)

    /// The cache key of a track at a quality.
    static func key(uid: String, quality: MusicQuality) -> String { uid + "|" + quality.rawValue }

    static func stem(forKey key: String) -> String {
        MusicHash.sha256(key, prefix: 16)
    }

    static func stem(of name: String) -> String { (name as NSString).deletingPathExtension }

    /// Only letters and digits survive, so a container name can never become a path.
    static func safeExtension(_ container: String) -> String {
        let s = String(container.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(5))
        return s.isEmpty ? "audio" : s
    }

    static func fileName(key: String, container: String) -> String { stem(forKey: key) + "." + safeExtension(container) }

    // MARK: settings

    func configure(enabled: Bool, limitMB: Int) {
        let evict: [String] = lock.withLock {
            self.enabled = enabled
            self.limitBytes = Int64(max(0, limitMB)) * 1_048_576
            loadIfNeeded()
            return index.evictionList(limit: limitBytes, protectedStem: protectedStem, alsoProtected: pinnedStems)
        }
        remove(evict)
    }

    var isEnabled: Bool { lock.withLock { enabled } }

    var usedBytes: Int64 { lock.withLock { loadIfNeeded(); return index.totalBytes } }

    /// The file being played is never evicted. Pass nil when nothing from the cache is playing.
    func protect(key: String?) {
        lock.withLock { protectedStem = key.map(Self.stem(forKey:)) }
    }

    /// Holds back from eviction the files of these keys, in order, while their total size stays within `budget`. Replaces the earlier pins.
    func pinForAnalysis(keys: [String], budget: Int64 = MusicAnalysisCache.pinnedBudgetBytes) {
        lock.withLock {
            loadIfNeeded()
            var used: Int64 = 0
            var chosen: Set<String> = []
            for k in keys {
                let stem = Self.stem(forKey: k)
                guard let e = index.entries.values.first(where: { Self.stem(of: $0.name) == stem }), used + e.size <= budget else { continue }
                used += e.size
                chosen.insert(stem)
            }
            pinnedStems = chosen
        }
    }

    // MARK: reading

    /// The finished file for a track, or nil. Counts as a use, which keeps it away from eviction.
    func cachedFile(key: String, container: String? = nil) -> URL? {
        lock.withLock {
            guard enabled else { return nil }
            loadIfNeeded()
            let stem = Self.stem(forKey: key)
            guard let entry = index.entries.values.first(where: { Self.stem(of: $0.name) == stem && (container == nil || $0.name.hasSuffix("." + Self.safeExtension(container ?? ""))) }) else { return nil }
            let url = directory.appendingPathComponent(entry.name)
            guard FileManager.default.fileExists(atPath: url.path) else { index.remove(entry.name); return nil }
            let now = Date()
            index.touch(entry.name, at: now)
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
            return url
        }
    }

    // MARK: writing

    /// A writer for a new entry, or nil when the cache is off, the entry already exists or another writer is already filling it.
    func beginWrite(key: String, container: String) -> MusicCacheWriter? {
        lock.withLock {
            guard enabled else { return nil }
            loadIfNeeded()
            let name = Self.fileName(key: key, container: container)
            let stem = Self.stem(forKey: key)
            guard index.entries[name] == nil, !activeWriters.contains(stem) else { return nil }
            guard FileManager.default.fileExists(atPath: MusicStorage.ensureUnbacked(directory).path) else { return nil }
            let part = directory.appendingPathComponent(name + ".part")
            FileManager.default.createFile(atPath: part.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: part) else { return nil }
            activeWriters.insert(stem)
            return MusicCacheWriter(cache: self, name: name, stem: stem, part: part, handle: handle)
        }
    }

    fileprivate func finished(_ w: MusicCacheWriter, size: Int64, complete: Bool) {
        let evict: [String] = lock.withLock {
            activeWriters.remove(w.stem)
            let final = directory.appendingPathComponent(w.name)
            guard complete, enabled else { try? FileManager.default.removeItem(at: w.part); return [] }
            try? FileManager.default.removeItem(at: final)
            do { try FileManager.default.moveItem(at: w.part, to: final) } catch { try? FileManager.default.removeItem(at: w.part); return [] }
            index.insert(name: w.name, size: size, at: Date())
            return index.evictionList(limit: limitBytes, protectedStem: protectedStem, alsoProtected: pinnedStems)
        }
        remove(evict)
    }

    // MARK: clearing

    /// Removes the finished file for a key (and a leftover partial one that no writer is filling): a copy that would not play is not offered again.
    func evict(key: String) {
        let stem = Self.stem(forKey: key)
        let names: [String] = lock.withLock {
            loadIfNeeded()
            return index.entries.values.map(\.name).filter { Self.stem(of: $0) == stem }
        }
        remove(names)
        lock.withLock {
            guard !activeWriters.contains(stem), let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
            for u in items where u.pathExtension == "part" && Self.stem(of: u.deletingPathExtension().lastPathComponent) == stem { try? FileManager.default.removeItem(at: u) }
        }
    }

    func clear() {
        lock.withLock {
            index.removeAll()
            loaded = true
            if let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for u in items where !activeWriters.contains(Self.stem(of: u.deletingPathExtension().lastPathComponent)) {
                    try? FileManager.default.removeItem(at: u)
                }
            }
        }
    }

    // MARK: private

    private func remove(_ names: [String]) {
        guard !names.isEmpty else { return }
        lock.withLock {
            for n in names {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(n))
                index.remove(n)
            }
        }
    }

    /// Rebuilds sizes and last-use times from the folder. Leftover `.part` files from a crash are deleted. Caller holds the lock.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        for u in items {
            if u.pathExtension == "part" { try? FileManager.default.removeItem(at: u); continue }
            guard let v = try? u.resourceValues(forKeys: Set(keys)), let size = v.fileSize else { continue }
            index.insert(name: u.lastPathComponent, size: Int64(size), at: v.contentModificationDate ?? .distantPast)
        }
    }
}

/// Appends bytes to a `.part` file. `finish` moves it into the cache only when the size matches what the server announced.
final class MusicCacheWriter: @unchecked Sendable {
    fileprivate let name: String
    fileprivate let stem: String
    fileprivate let part: URL
    private let cache: MusicAudioCache
    private let lock = NSLock()
    private var handle: FileHandle?
    private(set) var written: Int64 = 0

    fileprivate init(cache: MusicAudioCache, name: String, stem: String, part: URL, handle: FileHandle) {
        self.cache = cache; self.name = name; self.stem = stem; self.part = part; self.handle = handle
    }

    /// False when the disk write failed; the caller should abort.
    @discardableResult
    func append(_ data: Data) -> Bool {
        lock.withLock {
            guard let h = handle else { return false }
            do { try h.write(contentsOf: data); written += Int64(data.count); return true } catch { return false }
        }
    }

    func finish(expectedSize: Int64?) {
        let (size, ok): (Int64, Bool) = lock.withLock {
            guard let h = handle else { return (0, false) }
            try? h.close(); handle = nil
            return (written, written > 0 && (expectedSize.map { $0 == written } ?? false))
        }
        cache.finished(self, size: size, complete: ok)
    }

    func abort() {
        let had: Bool = lock.withLock {
            guard let h = handle else { return false }
            try? h.close(); handle = nil
            return true
        }
        if had { cache.finished(self, size: 0, complete: false) }
    }
}
