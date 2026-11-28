import Foundation

// The folder view of Local files: the folders and files under one chosen music folder, built from the paths the scan already indexed (plus the names
// of folders that hold no music, so an empty folder is shown as empty and not missing). Pure: no disk access here, so it is tested with fake paths.

struct LocalTreeFile: Hashable, Sendable, Identifiable {
    var name: String
    var trackID: String
    var id: String { trackID }
}

struct LocalTreeFolder: Hashable, Sendable, Identifiable {
    var name: String
    /// Songs in this folder and everything below it.
    var trackCount: Int
    var id: String { name }
}

/// What one folder of the tree holds.
struct LocalFolderListing: Hashable, Sendable {
    /// The folder's own path under the root, as names (empty for the root itself).
    var path: [String]
    var folders: [LocalTreeFolder]
    var files: [LocalTreeFile]
    /// Songs here and below.
    var trackCount: Int
    /// True when the folder holds no song at all, here or below (it may still hold other folders or files that are not music).
    var isEmpty: Bool { trackCount == 0 }
}

enum LocalFolderTree {
    /// The names of a path: split on "/" and "\\", empty names (a trailing or doubled slash) dropped, accents composed so a name typed one way and
    /// listed by the disk the other way are the same.
    static func components(_ path: String) -> [String] {
        path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).precomposedStringWithCanonicalMapping }.filter { $0 != "." }
    }

    /// The names of `path` below `root`, or nil when it is not under it. `roots` are spellings of the same folder (the one the person chose and
    /// the one with links resolved, which the scan stores); the first that fits wins.
    static func relative(_ path: String, roots: [String]) -> [String]? {
        let p = components(path)
        for r in roots {
            let rc = components(r)
            if !rc.isEmpty, p.count > rc.count, Array(p.prefix(rc.count)) == rc { return Array(p.dropFirst(rc.count)) }
        }
        return nil
    }

    /// Names in the order a person expects: numbers as numbers ("2" before "10"), case and accents ignored.
    static func natural(_ a: String, _ b: String) -> Bool {
        let c = a.compare(b, options: [.numeric, .caseInsensitive, .diacriticInsensitive], range: nil, locale: Locale.current)
        return c != .orderedSame ? c == .orderedAscending : a < b
    }

    /// One folder of the tree. `entries` are (full path, track id) of the indexed files of this root; `diskFolders` are the names of the
    /// sub-folders found on disk at `at` (may include ones with no music). A path outside the root is ignored.
    static func listing(roots: [String], entries: [(path: String, id: String)], at: [String], diskFolders: [String] = []) -> LocalFolderListing {
        let here = at.map { $0.precomposedStringWithCanonicalMapping }
        var files: [LocalTreeFile] = []
        var counts: [String: Int] = [:]
        var total = 0
        for e in entries {
            guard let rel = relative(e.path, roots: roots), rel.count > here.count, Array(rel.prefix(here.count)) == here else { continue }
            total += 1
            let rest = Array(rel.dropFirst(here.count))
            if rest.count == 1 { files.append(LocalTreeFile(name: rest[0], trackID: e.id)) }
            else { counts[rest[0], default: 0] += 1 }
        }
        for d in diskFolders {
            let n = d.precomposedStringWithCanonicalMapping
            if counts[n] == nil { counts[n] = 0 }
        }
        let folders = counts.map { LocalTreeFolder(name: $0.key, trackCount: $0.value) }.sorted { natural($0.name, $1.name) }
        return LocalFolderListing(path: here, folders: folders, files: files.sorted { natural($0.name, $1.name) }, trackCount: total)
    }

    /// The track ids in a folder and everything below it, in the order a person reads them: this folder's files first, then each sub-folder in turn.
    static func trackIDs(roots: [String], entries: [(path: String, id: String)], at: [String]) -> [String] {
        let here = at.map { $0.precomposedStringWithCanonicalMapping }
        var found: [(rel: [String], id: String)] = []
        for e in entries {
            guard let rel = relative(e.path, roots: roots), rel.count > here.count, Array(rel.prefix(here.count)) == here else { continue }
            found.append((Array(rel.dropFirst(here.count)), e.id))
        }
        let sorted = found.sorted { a, b in
            let n = min(a.rel.count, b.rel.count)
            for i in 0..<n {
                let aLast = i == a.rel.count - 1, bLast = i == b.rel.count - 1
                // a file sorts before a folder at the same level
                if aLast != bLast { return aLast }
                if a.rel[i] != b.rel[i] { return natural(a.rel[i], b.rel[i]) }
            }
            return a.id < b.id
        }
        return sorted.map(\.id)
    }

    /// The crumbs of a path: the root's name, then each folder, as the (name, path-below-root) pairs a breadcrumb draws.
    static func breadcrumbs(rootName: String, path: [String]) -> [(name: String, path: [String])] {
        var out: [(name: String, path: [String])] = [(rootName, [])]
        for i in path.indices { out.append((path[i], Array(path.prefix(i + 1)))) }
        return out
    }
}
