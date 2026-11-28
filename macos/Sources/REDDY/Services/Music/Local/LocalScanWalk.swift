import Foundation

// The directory walk of a rescan. A directory whose modified time has not moved since the last scan is not listed file by file: its files come
// from the index. Only the sub-directories are still visited, because a change deeper down does not move the parent's time. No AVFoundation here,
// so it is tested with temporary folders and fake files.

struct LocalWalkResult: Sendable, Equatable {
    /// Every audio file path -> modified time (reused from the index for an unchanged directory).
    var found: [String: Date] = [:]
    /// Directory path -> modified time seen now. Stored only after the scan finished.
    var stamps: [String: Date] = [:]
    /// Short files to keep leaving out (path -> modified time).
    var skipped: [String: Date] = [:]
    var directoriesReused = 0
    var directoriesListed = 0
}

extension LocalScanner {
    static let maxDepth = 10

    /// Walks `root`. `stamps` are the directory times of the last finished scan (empty = list everything), `known` and `skipped` the indexed and
    /// left-out files of this folder. Nil when the root cannot be read at all (an offline drive), so the caller keeps its rows.
    static func walk(root: URL, stamps: [String: Date], known: [String: Date], skipped: [String: Date]) -> LocalWalkResult? {
        let fm = FileManager.default
        let rootURL = root.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = rootURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard (try? fm.contentsOfDirectory(atPath: rootPath)) != nil else { return nil }
        let knownByDir = Dictionary(grouping: known.keys) { ($0 as NSString).deletingLastPathComponent }
        let skippedByDir = Dictionary(grouping: skipped.keys) { ($0 as NSString).deletingLastPathComponent }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var result = LocalWalkResult()

        func carry(_ dir: String) {
            for p in knownByDir[dir] ?? [] { result.found[p] = known[p] }
            for p in skippedByDir[dir] ?? [] { result.skipped[p] = skipped[p] }
        }

        // Paths are built from the resolved root, never read back from the listing (which can answer with /private/var where the root says /var),
        // so they match the paths the index already holds.
        func visit(_ path: String, depth: Int) {
            if Task.isCancelled { return }
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                // Unreadable now: keep what the index has, and leave no stamp so the next scan tries again.
                carry(path)
                return
            }
            let mtime = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let unchanged = mtime.map { m in stamps[path].map { LocalScanStamps.same($0, m) } ?? false } ?? false
            if let mtime { result.stamps[path] = mtime }
            var subdirs: [String] = []
            var listedHere: [String: Date] = [:]
            for url in items {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
                let itemPath = (path as NSString).appendingPathComponent(url.lastPathComponent)
                if v.isDirectory == true {
                    guard depth < maxDepth else { continue }
                    let rel = "/" + String(itemPath.dropFirst(prefix.count))
                    if LocalScanFilter.isNonMusicPath(rel) { continue }
                    subdirs.append(itemPath)
                    continue
                }
                if unchanged { continue }
                guard v.isRegularFile == true, LocalLibraryIndex.audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                guard LocalScanFilter.keepsPath("/" + String(itemPath.dropFirst(prefix.count))) else { continue }
                listedHere[itemPath] = v.contentModificationDate ?? .distantPast
            }
            if unchanged {
                result.directoriesReused += 1
                carry(path)
            } else {
                result.directoriesListed += 1
                for (p, m) in listedHere {
                    result.found[p] = m
                    if let old = skipped[p], LocalScanStamps.same(old, m) { result.skipped[p] = old }
                }
            }
            for sub in subdirs { visit(sub, depth: depth + 1) }
        }

        visit(rootPath, depth: 0)
        return result
    }
}

enum LocalScanStamps {
    /// Modified times count as equal within a few milliseconds (rounding only). A wider window would hide a change made right after a scan.
    static func same(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 0.005 }
}
