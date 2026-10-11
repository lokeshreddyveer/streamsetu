import Foundation

/// Keeps the on-disk cache under its size limit by deleting the least recently used files first.
struct CacheCleaner: Sendable {
    let root: URL
    let limit: Int64

    @discardableResult
    func trim() -> (before: Int64, after: Int64) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return (0, 0) }
        var files: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let size = Int64(v.fileSize ?? 0)
            files.append((u, size, v.contentModificationDate ?? .distantPast))
            total += size
        }
        let before = total
        guard total > limit else { return (before, before) }
        let target = Int64(Double(limit) * 0.8)
        for f in files.sorted(by: { $0.date < $1.date }) {
            if total <= target { break }
            if (try? fm.removeItem(at: f.url)) != nil { total -= f.size }
        }
        return (before, total)
    }

    func clearAll() {
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for i in items { try? FileManager.default.removeItem(at: i) }
    }
}
