import Foundation

/// Where Music keeps its files: inside the app's own support folder, so the test redirect and the app's backup rules apply to it too.
enum MusicStorage {
    /// `<app support>/Music`. Under test the app's storage points at a throwaway folder, and so does this.
    static var root: URL {
        _ = migrated
        return StorageService.applicationSupport.appendingPathComponent("Music", isDirectory: true)
    }

    /// Rebuildable files (translations and the like) that the system may clear.
    static var caches: URL { StorageService.caches.appendingPathComponent("Music", isDirectory: true) }

    /// Keeps a folder out of Time Machine and iCloud backups, the way the app's own downloads folder is: it can be big and can always be fetched again.
    @discardableResult
    static func excludeFromBackup(_ folder: URL) -> Bool {
        var url = folder
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        return (try? url.setResourceValues(values)) != nil
    }

    /// Creates the folder if needed and marks it excluded from backups.
    @discardableResult
    static func ensureUnbacked(_ folder: URL) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        excludeFromBackup(folder)
        return folder
    }

    static func subfolder(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    /// Where earlier builds kept everything.
    static var legacyRoot: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("StreamSetu", isDirectory: true).appendingPathComponent("Music", isDirectory: true)
    }

    /// Moves an old `StreamSetu/Music` folder to the new place once. It never runs under test, and never over a folder that already exists.
    private static let migrated: Void = {
        guard ProcessInfo.processInfo.environment["STREAMSETU_TESTING"] == nil else { return }
        let fm = FileManager.default
        let target = StorageService.applicationSupport.appendingPathComponent("Music", isDirectory: true)
        guard let old = legacyRoot, fm.fileExists(atPath: old.path), !fm.fileExists(atPath: target.path) else { return }
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: old, to: target)
    }()
}
