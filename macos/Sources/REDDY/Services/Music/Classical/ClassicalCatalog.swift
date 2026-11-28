import Foundation

/// The classical index on this device: loaded lazily, built by importing a copy of the dataset the person downloaded, and kept small. Importing reads only metadata
/// JSON files (never audio), runs in the background at low priority, yields between files, and stops when cancelled.
actor ClassicalCatalog {
    static let shared = ClassicalCatalog()

    struct ImportReport: Equatable, Sendable {
        var scanned = 0
        var imported = 0
        var skipped = 0
        var cancelled = false
    }

    private var index: ClassicalIndex?
    private let url: URL?

    init(url: URL? = MusicStorage.subfolder("Classical").appendingPathComponent("index.json")) { self.url = url }

    func current() -> ClassicalIndex {
        if let index { return index }
        let loaded = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? MusicJSONCoding.makeDecoder().decode(ClassicalIndex.self, from: $0) } ?? ClassicalIndex()
        index = loaded
        return loaded
    }

    func isEmpty() -> Bool { current().recordings.isEmpty }

    func clear() { index = ClassicalIndex(); if let url { try? FileManager.default.removeItem(at: url) } }

    /// Which tradition a file belongs to, from where it sits in the dataset ("Carnatic" or "Hindustani" in its path).
    static func tradition(ofPath path: String) -> ClassicalTradition? {
        let p = path.lowercased()
        if p.contains("carnatic") { return .carnatic }
        if p.contains("hindustani") { return .hindustani }
        return nil
    }

    /// The part of a path below the chosen folder, so the folder's own name (say "carnatic-and-hindustani") cannot decide the tradition.
    static func relativePath(_ file: URL, in folder: URL) -> String {
        let f = file.standardizedFileURL.path, root = folder.standardizedFileURL.path
        return f.hasPrefix(root) ? String(f.dropFirst(root.count)) : f
    }

    static func dataset(version: String = "1.5") -> ClassicalDataset { ClassicalDataset(name: "Saraga", version: version, rights: "CC BY-NC 4.0") }

    /// Reads every metadata JSON under `folder`. Files that are not recording annotations (audio, pitch, tempo, anything unreadable) are skipped without being parsed
    /// further. Writes the index once at the end; nothing is changed if the import is cancelled before it ends.
    func importDataset(from folder: URL, progress: (@Sendable (Int) -> Void)? = nil) async -> ImportReport {
        var report = ImportReport()
        var found: [ClassicalRecording] = []
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return report }
        let dataset = Self.dataset()
        while let item = walker.nextObject() as? URL {
            if Task.isCancelled { report.cancelled = true; return report }
            guard item.pathExtension.lowercased() == "json" else { continue }
            report.scanned += 1
            if report.scanned % 25 == 0 { progress?(report.scanned); await Task.yield() }
            let size = (try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size > 0, size < 512 * 1024, let tradition = Self.tradition(ofPath: Self.relativePath(item, in: folder)), let data = try? Data(contentsOf: item),
                  let r = SaragaMetadataParser.parse(data, tradition: tradition, dataset: dataset) else { report.skipped += 1; continue }
            found.append(r); report.imported += 1
        }
        guard !found.isEmpty else { return report }
        var seen = Set<String>()
        let unique = found.filter { seen.insert($0.id).inserted }
        let built = ClassicalIndex(recordings: unique, builtAt: Date())
        index = built
        if let url, let d = try? MusicJSONCoding.makeEncoder().encode(built) { try? d.write(to: url, options: .atomic) }
        report.imported = unique.count
        return report
    }
}
