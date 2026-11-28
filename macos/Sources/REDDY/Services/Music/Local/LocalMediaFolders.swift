import Foundation
import AVFoundation
import Observation
#if os(macOS)
import AppKit
#endif

// Folders the person chose for the Local files source. Access to each folder is kept through a security-scoped bookmark, the index is a JSON file
// next to it, and the scanner only ever walks inside a chosen folder.

struct LocalFolderRecord: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var path: String
    var bookmark: Data
    var lastScan: Date?
}

struct LocalFolderInfo: Hashable, Sendable, Identifiable {
    var id: String; var name: String; var path: String; var lastScan: Date?; var trackCount: Int
}

struct LocalScanProgress: Sendable, Equatable { var folderName: String; var read: Int; var total: Int }

actor LocalLibraryStore {
    static let shared = LocalLibraryStore()

    static var defaultDirectory: URL { MusicStorage.subfolder("local") }

    let directory: URL
    nonisolated var artworkDirectory: URL { directory.appendingPathComponent("art", isDirectory: true) }
    private var folders: [LocalFolderRecord] = []
    private var index = LocalLibraryIndex()
    private var loaded = false
    private var open: [String: URL] = [:]
    private var scanning = false

    init(directory: URL = LocalLibraryStore.defaultDirectory) { self.directory = directory }

    private var foldersURL: URL { directory.appendingPathComponent("folders.json") }
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    // MARK: load / save

    /// Reads the saved folders and index once, and opens access to each folder so its files can be played.
    func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        if let d = try? Data(contentsOf: foldersURL), let f = try? JSONDecoder().decode([LocalFolderRecord].self, from: d) { folders = f }
        if let d = try? Data(contentsOf: indexURL), let i = try? JSONDecoder().decode(LocalLibraryIndex.self, from: d) { index = i }
        // The tag and album rules changed: forget every modification date so the next scan reads each file again (the rows stay until then).
        if index.scanVersion != LocalLibraryIndex.currentScanVersion {
            for n in index.entries.indices { index.entries[n].modified = .distantPast }
            index.forgetStamps()
            index.scanVersion = LocalLibraryIndex.currentScanVersion
        }
        for f in folders { _ = openAccess(f) }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(folders) { try? d.write(to: foldersURL, options: .atomic) }
        if let d = try? JSONEncoder().encode(index) { try? d.write(to: indexURL, options: .atomic) }
    }

    // MARK: access

    private func openAccess(_ f: LocalFolderRecord) -> URL? {
        if let u = open[f.id] { return u }
        var stale = false
        #if os(macOS)
        let opts: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let opts: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: f.bookmark, options: opts, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        guard url.startAccessingSecurityScopedResource() || FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        open[f.id] = url
        if stale, let fresh = Self.makeBookmark(url), let i = folders.firstIndex(where: { $0.id == f.id }) { folders[i].bookmark = fresh; save() }
        return url
    }

    private func closeAccess(_ id: String) {
        if let u = open.removeValue(forKey: id) { u.stopAccessingSecurityScopedResource() }
    }

    private static func makeBookmark(_ url: URL) -> Data? {
        #if os(macOS)
        return try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    // MARK: folders

    func snapshot() -> [LocalFolderInfo] {
        ensureLoaded()
        return folders.map { LocalFolderInfo(id: $0.id, name: $0.name, path: $0.path, lastScan: $0.lastScan, trackCount: index.count(in: $0.id)) }
    }

    func currentIndex() -> LocalLibraryIndex { ensureLoaded(); return index }

    /// Edits what the library shows for these local songs (see `LocalEntryPatch`) and saves the index. The files themselves are not changed.
    @discardableResult
    func edit(ids: Set<String>, patch: LocalEntryPatch) -> Int {
        ensureLoaded()
        let n = index.edit(ids: ids, patch: patch)
        if n > 0 { save() }
        return n
    }

    /// The names of the sub-folders on disk at `relative` below a chosen folder, so the folder view also shows folders that hold no music. Access goes
    /// through the same open security-scoped URL the scan uses; nothing outside the chosen folder is ever listed (links and ".." are refused).
    func subfolderNames(folderID: String, relative: [String]) -> [String] {
        ensureLoaded()
        guard let rec = folders.first(where: { $0.id == folderID }), let root = openAccess(rec) else { return [] }
        guard !relative.contains(where: { $0 == ".." || $0.contains("/") }) else { return [] }
        var dir = root.resolvingSymlinksInPath().standardizedFileURL
        for part in relative { dir.appendPathComponent(part, isDirectory: true) }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return items.compactMap { url -> String? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isDirectory == true, v.isSymbolicLink != true else { return nil }
            let rel = "/" + (relative + [url.lastPathComponent]).joined(separator: "/")
            return LocalScanFilter.isNonMusicPath(rel) ? nil : url.lastPathComponent
        }
    }

    /// Every indexed file of one chosen folder as (path, track id), for the folder view.
    func indexedFiles(folderID: String) -> [(path: String, id: String)] {
        ensureLoaded()
        return index.entries.filter { $0.folderID == folderID }.map { (path: $0.path, id: $0.id) }
    }

    /// `url` must come from the open panel (or another place that granted access). Adding the same folder twice does nothing.
    @discardableResult
    func addFolder(_ url: URL) -> LocalFolderInfo? {
        ensureLoaded()
        let std = url.standardizedFileURL
        if let existing = folders.first(where: { $0.path == std.path }) { return LocalFolderInfo(id: existing.id, name: existing.name, path: existing.path, lastScan: existing.lastScan, trackCount: index.count(in: existing.id)) }
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        guard let bookmark = Self.makeBookmark(url) else { return nil }
        let rec = LocalFolderRecord(id: UUID().uuidString, name: std.lastPathComponent, path: std.path, bookmark: bookmark, lastScan: nil)
        folders.append(rec)
        _ = openAccess(rec)
        save()
        return LocalFolderInfo(id: rec.id, name: rec.name, path: rec.path, lastScan: nil, trackCount: 0)
    }

    func removeFolder(id: String) {
        ensureLoaded()
        closeAccess(id)
        folders.removeAll { $0.id == id }
        index.removeFolder(id)
        save()
    }

    /// Takes these songs out of the library's list. The files on disk are not touched.
    @discardableResult
    func forget(ids: Set<String>) -> Int {
        ensureLoaded()
        let before = index.entries.count
        index.entries.removeAll { ids.contains($0.id) }
        let n = before - index.entries.count
        if n > 0 { save() }
        return n
    }

    /// Writes the patch into the files of these songs (and keeps the library's copy in step). Returns how many files were written, how many are in a format
    /// that cannot be tagged, and how many failed (a read-only folder, a file in use).
    func writeTags(ids: Set<String>, patch: LocalEntryPatch) async -> (written: Int, unsupported: Int, failed: Int, blocked: Int) {
        ensureLoaded()
        var written = 0, unsupported = 0, failed = 0, blocked = 0
        for e in index.entries where ids.contains(e.id) {
            let url = URL(fileURLWithPath: e.path)
            // Read-only collection and locked files are never written. Before a write the original is copied aside and the change is journalled, so it can be undone.
            guard MusicCollectionSafety.verdict(for: e.path) == .allowed else { blocked += 1; continue }
            var record: MusicChangeRecord?
            if MusicCollectionSafety.keepsBackups() {
                record = MusicChangeJournal.shared.backup(of: url, summary: "\(e.title): " + MusicPatchSummary.line(patch))
                if record == nil { failed += 1; continue }
            } else {
                record = MusicChangeJournal.shared.backup(of: url, summary: "\(e.title): " + MusicPatchSummary.line(patch), keep: false)
            }
            let result = await LocalTagFileWriter.write(patch, to: url)
            if case .tagged = result {} else if let r = record { MusicChangeJournal.shared.discard(r.id) }
            switch result {
            case .tagged: written += 1
            case .unsupportedFormat: unsupported += 1
            case .failed: failed += 1
            }
        }
        return (written, unsupported, failed, blocked)
    }

    /// The paths of the chosen folders, for the folder watcher.
    func folderPaths() -> [String] { ensureLoaded(); return folders.map(\.path) }

    /// Removes the saved index and artwork but keeps the folder list.
    func forgetIndex() {
        index = LocalLibraryIndex()
        try? FileManager.default.removeItem(at: artworkDirectory)
        for i in folders.indices { folders[i].lastScan = nil }
        save()
    }

    // MARK: scanning

    /// Rescans one folder, or all of them. Only files that are new or changed since the last scan are read. Cancelling keeps what was read so far.
    /// `removed` receives the track ids of files that are gone, so shortcuts, pins and recents can forget them at once.
    /// A directory whose modified time has not moved since the last finished scan is not listed again. `thorough` forgets those times first (and the
    /// short files left out), so every directory is listed again.
    func scan(folderID: String? = nil, thorough: Bool = false, progress: (@Sendable (LocalScanProgress) -> Void)? = nil, removed: (@Sendable ([String]) -> Void)? = nil) async {
        ensureLoaded()
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        if thorough { index.forgetStamps(folderID: folderID) }
        for rec in folders where folderID == nil || rec.id == folderID {
            if Task.isCancelled { return }
            guard let root = openAccess(rec) else { continue }
            // An unreachable folder (an offline drive) keeps its rows and is tried again next time.
            guard let walk = LocalScanner.walk(root: root, stamps: index.stamps(in: rec.id), known: index.known(in: rec.id), skipped: index.skipped(in: rec.id)) else { continue }
            if Task.isCancelled { return }
            let found = walk.found
            var skipped = walk.skipped
            let plan = LocalLibraryIndex.plan(known: index.known(in: rec.id), found: found, skipped: skipped)
            var read: [LocalEntry] = []
            var finished = true
            for (n, path) in plan.toRead.enumerated() {
                if Task.isCancelled { finished = false; break }
                progress?(LocalScanProgress(folderName: rec.name, read: n, total: plan.toRead.count))
                guard let modified = found[path] else { continue }
                let entry = await LocalScanner.readEntry(path: path, folderID: rec.id, modified: modified, artworkDirectory: artworkDirectory)
                if LocalScanFilter.keepsDuration(entry.durationMs) { read.append(entry) } else { skipped[path] = modified }
            }
            index.apply(folderID: rec.id, read: read, removed: finished ? Set(plan.removed) : [])
            if finished, !plan.removed.isEmpty { removed?(plan.removed.map { LocalLibraryIndex.trackID(path: $0) }) }
            if index.skippedShort == nil { index.skippedShort = [:] }
            index.skippedShort?[rec.id] = skipped
            if finished {
                if index.folderStamps == nil { index.folderStamps = [:] }
                index.folderStamps?[rec.id] = walk.stamps
            }
            if finished, let i = folders.firstIndex(where: { $0.id == rec.id }) { folders[i].lastScan = Date() }
            save()
            if !finished { return }
        }
        progress?(LocalScanProgress(folderName: "", read: 0, total: 0))
    }
}

// MARK: scanner

enum LocalScanner {
    struct Found: Sendable { var path: String; var modified: Date }

    /// Audio files under `root`. Hidden files are skipped, and so is anything whose real location is outside `root` (symbolic links), so the walk never leaves the chosen folder.
    static func listAudioFiles(in root: URL) -> [Found] {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [Found] = []
        for case let url as URL in en {
            if out.count % 200 == 0, Task.isCancelled { break }
            if en.level > 10 { en.skipDescendants(); continue }
            guard LocalLibraryIndex.audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true, v.isRegularFile == true else { continue }
            let real = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard real.hasPrefix(prefix), LocalScanFilter.keepsPath("/" + String(real.dropFirst(prefix.count))) else { continue }
            out.append(Found(path: real, modified: v.contentModificationDate ?? .distantPast))
        }
        return out
    }

    /// Reads title, artist, album, album artist, track and disc numbers, duration and artwork. A file without tags still gets an entry named after its file.
    static func readEntry(path: String, folderID: String, modified: Date, artworkDirectory: URL) async -> LocalEntry {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        var title = "", artist = "", album = "", albumArtist = ""
        var track: Int?, disc: Int?
        var composer: String?, lyricist: String?, conductor: String?, work: String?
        var artwork: Data?
        if let items = try? await asset.load(.metadata) {
            for item in items {
                guard let key = item.commonKey?.rawValue else { continue }
                switch key {
                case AVMetadataKey.commonKeyTitle.rawValue: if title.isEmpty { title = (try? await item.load(.stringValue)) ?? "" }
                case AVMetadataKey.commonKeyArtist.rawValue: if artist.isEmpty { artist = (try? await item.load(.stringValue)) ?? "" }
                case AVMetadataKey.commonKeyAlbumName.rawValue: if album.isEmpty { album = (try? await item.load(.stringValue)) ?? "" }
                case AVMetadataKey.commonKeyArtwork.rawValue: if artwork == nil { artwork = try? await item.load(.dataValue) }
                default: break
                }
            }
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataAlbumArtist)
                + AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .id3MetadataBand) where albumArtist.isEmpty {
                albumArtist = (try? await item.load(.stringValue)) ?? ""
            }
            // Credits the tags name: composer, lyricist, conductor and the work or grouping. Read only when present.
            func text(_ ids: [AVMetadataIdentifier]) async -> String? {
                for id in ids {
                    for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id) {
                        if let v = try? await item.load(.stringValue), !v.trimmingCharacters(in: .whitespaces).isEmpty { return v.trimmingCharacters(in: .whitespaces) }
                    }
                }
                return nil
            }
            composer = await text([.id3MetadataComposer, .iTunesMetadataComposer])
            lyricist = await text([.id3MetadataLyricist])
            conductor = await text([.id3MetadataConductor])
            work = await text([.id3MetadataContentGroupDescription, .iTunesMetadataGrouping])
            let numberItems = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .id3MetadataTrackNumber)
                + AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataTrackNumber)
            for item in numberItems where track == nil {
                if let s = try? await item.load(.stringValue) { track = LocalTagText.trackNumber(s) }
                else if let d = try? await item.load(.dataValue), d.count >= 4 { let n = Int(d[2]) << 8 | Int(d[3]); track = n > 0 ? n : nil }
            }
            let discItems = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .id3MetadataPartOfASet)
                + AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataDiscNumber)
            for item in discItems where disc == nil {
                if let s = try? await item.load(.stringValue) { disc = LocalTagText.trackNumber(s) }
                else if let d = try? await item.load(.dataValue), d.count >= 4 { let n = Int(d[2]) << 8 | Int(d[3]); disc = n > 0 ? n : nil }
            }
        }
        let seconds = ((try? await asset.load(.duration))?.seconds) ?? 0
        let name = url.lastPathComponent
        let folderURL = url.deletingLastPathComponent()
        title = title.trimmingCharacters(in: .whitespaces); artist = artist.trimmingCharacters(in: .whitespaces)
        album = album.trimmingCharacters(in: .whitespaces); albumArtist = albumArtist.trimmingCharacters(in: .whitespaces)
        // No title: take it from the file name; "Artist - Title" also gives an artist when the tag has none.
        if title.isEmpty {
            let parts = LocalTagText.artistAndTitle(fromFileName: name)
            title = parts.title
            if artist.isEmpty, let a = parts.artist { artist = a }
        }
        if track == nil { track = fileNameTrackNumber(name) }
        let tagged = !album.isEmpty
        let artistName = artist.isEmpty ? LocalLibraryIndex.unknownArtist : artist
        // With no album tag the folder is the album.
        let albumName = tagged ? album : (folderURL.lastPathComponent.isEmpty ? LocalLibraryIndex.unknownAlbum : folderURL.lastPathComponent)
        var entry = LocalEntry(id: LocalLibraryIndex.trackID(path: path), folderID: folderID, path: path, title: title, artist: artistName, album: albumName,
                               trackNumber: track, durationMs: seconds.isFinite && seconds > 0 ? Int64(seconds * 1000) : 0, modified: modified,
                               artworkFile: nil, ext: url.pathExtension.lowercased(),
                               albumArtist: albumArtist.isEmpty ? nil : albumArtist, discNumber: disc, albumTagged: tagged,
                               composer: composer, lyricist: lyricist, conductor: conductor, work: work)
        // Artwork is written once per album (or per file with no album tag). A file with no album tag never borrows the folder's picture.
        let stem = tagged ? LocalLibraryIndex.fnv12(LocalLibraryIndex.albumKey(of: entry)) : LocalLibraryIndex.fnv12("file|" + path)
        let dest = artworkDirectory.appendingPathComponent(stem + ".img")
        if FileManager.default.fileExists(atPath: dest.path) { entry.artworkFile = stem + ".img"; return entry }
        var bytes = (artwork?.count ?? 0) < 8_000_000 ? artwork : nil
        if bytes == nil, tagged {
            for f in LocalTagText.coverFileNames {
                let candidate = folderURL.appendingPathComponent(f)
                if let d = try? Data(contentsOf: candidate), d.count < 8_000_000 { bytes = d; break }
            }
        }
        if let bytes {
            try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
            try? bytes.write(to: dest, options: .atomic)
            entry.artworkFile = stem + ".img"
        }
        return entry
    }

    private static func fileNameTrackNumber(_ name: String) -> Int? {
        guard let r = name.range(of: #"^\s*\d{1,3}"#, options: .regularExpression) else { return nil }
        return LocalTagText.trackNumber(String(name[r]))
    }
}

// MARK: observable model for the settings section

@MainActor @Observable
final class LocalMediaFolders {
    static let shared = LocalMediaFolders()

    private(set) var folders: [LocalFolderInfo] = []
    private(set) var isScanning = false
    private(set) var progress: LocalScanProgress?
    private(set) var note: String?
    @ObservationIgnored let store: LocalLibraryStore
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    init(store: LocalLibraryStore = .shared) { self.store = store }

    func refresh() async { folders = await store.snapshot(); updateWatching() }

    // MARK: watching the folders

    private static let watchKey = "music.local.watchFolders"
    /// Rescan by itself when files in a chosen folder change. On unless the person turns it off.
    var watches: Bool {
        get { UserDefaults.standard.object(forKey: Self.watchKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.watchKey); updateWatching() }
    }

    func updateWatching() {
        #if os(macOS)
        guard watches, !folders.isEmpty else { watcher.stop(); return }
        let paths = folders.map(\.path)
        watcher.start(paths: paths) { Task { @MainActor in LocalMediaFolders.shared.rescan() } }
        #endif
    }

    /// Reads the saved folders and starts watching them. Called once when Music starts.
    func startup() { Task { await refresh() } }

    #if os(macOS)
    @ObservationIgnored private let watcher = LocalFolderWatcher()
    #endif

    #if os(macOS)
    /// Asks the person for a folder. Nothing is read until they choose one.
    func chooseAndAdd() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"; panel.message = "Choose a folder of music files."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(url)
    }
    #endif

    func add(_ url: URL) {
        Task {
            if await store.addFolder(url) == nil { note = "Could not keep access to that folder." } else { note = nil }
            await refresh()
            rescan()
        }
    }

    func remove(_ id: String) {
        Task { await store.removeFolder(id: id); await refresh() }
    }

    /// Forgets every directory stamp and lists everything again. Use it when files changed in place or a drive was edited elsewhere.
    func thoroughRescan() { rescan(thorough: true) }

    func rescan(folderID: String? = nil, thorough: Bool = false) {
        guard !isScanning else { return }
        isScanning = true
        let store = self.store
        scanTask = Task { [weak self] in
            await store.scan(folderID: folderID, thorough: thorough) { p in Task { @MainActor in self?.progress = p.total == 0 ? nil : p } }
            self?.isScanning = false; self?.progress = nil
            await self?.refresh()
        }
    }

    func cancelScan() { scanTask?.cancel() }
}
