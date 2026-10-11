import Foundation

/// Locations on disk, following Apple's Application Support / Caches conventions.
///
///     ~/Library/Application Support/REDDY/{Database,Sources,Metadata,Backups,Settings}
///     ~/Library/Caches/REDDY/{ChannelLogos,Posters,Backdrops}
final class StorageService: Sendable {
    static let shared = StorageService()

    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("REDDY", isDirectory: true)
    }

    static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("REDDY", isDirectory: true)
    }

    static var databaseDirectory: URL { ensure(applicationSupport.appendingPathComponent("Database", isDirectory: true)) }
    static var importedPlaylists: URL { ensure(applicationSupport.appendingPathComponent("Sources", isDirectory: true)) }
    static var backups: URL { ensure(applicationSupport.appendingPathComponent("Backups", isDirectory: true)) }
    static var metadata: URL { ensure(applicationSupport.appendingPathComponent("Metadata", isDirectory: true)) }
    static func cacheDirectory(_ name: String) -> URL { ensure(caches.appendingPathComponent(name, isDirectory: true)) }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    func databaseSize() -> Int64 { directorySize(Self.databaseDirectory) }
    func cacheSize() -> Int64 { directorySize(Self.caches) }

    func formatBytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    /// Copies a user-chosen playlist file into the app's own folder so the source survives the original moving.
    func importPlaylistFile(_ url: URL) throws -> URL {
        let dest = Self.importedPlaylists.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }
}
