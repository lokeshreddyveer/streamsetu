import Foundation

/// What to do when the library database cannot be opened. Nothing here ever deletes the damaged database: it is moved to a timestamped folder under
/// `Recovery`, a fresh database is made, and the personal tables (playlists, favourites, history, profiles…) are copied across from a working copy of the old one,
/// table by table and in small chunks, so one damaged page costs only the rows on it. The catalogue (channels, movies, guide) is not copied: it is read again from the playlists.
enum DatabaseRecovery {
    /// Tables that hold what the person made or chose, and cannot be rebuilt from a playlist. Parents come before the tables that refer to them.
    static let personalTables = [
        "sources", "profiles", "profile_rows", "profile_state", "favorites", "collections", "collection_items", "hidden_items", "metadata_overrides",
        "folder_order", "locked_categories", "watch_history", "watch_progress", "recently_watched", "search_history", "downloads", "epg_channel_mappings",
        "video_layouts", "playback_sessions",
    ]

    /// What a damaged database still holds, for the "this is what you would lose" summary.
    struct Inventory: Equatable, Sendable {
        var readable = false
        var playlists = 0, favourites = 0, collections = 0, profiles = 0, history = 0
        var integrityProblem: String?

        var lines: [String] {
            guard readable else { return ["The database could not be read, so nothing in it can be listed."] }
            return ["\(playlists) playlist\(playlists == 1 ? "" : "s")", "\(favourites) favourite\(favourites == 1 ? "" : "s")", "\(collections) list\(collections == 1 ? "" : "s")",
                    "\(profiles) profile\(profiles == 1 ? "" : "s")", "\(history) watch history entr\(history == 1 ? "y" : "ies")"]
        }
    }

    struct Outcome: Equatable, Sendable {
        var kept: URL                          // where the old database now lives
        var copied: [String: Int] = [:]        // rows copied, by table
        var lost: [String] = []                // tables or chunks that could not be read
        var message: String {
            let rows = copied.values.reduce(0, +)
            if lost.isEmpty { return "Your library was rebuilt and your playlists, favourites and history were kept (\(rows) items). The old copy is in the Recovery folder." }
            return "Your library was rebuilt. Some of it could not be read: \(lost.prefix(4).joined(separator: ", ")). The old copy is in the Recovery folder."
        }
    }

    static var recoveryRoot: URL { StorageService.ensure(StorageService.applicationSupport.appendingPathComponent("Recovery", isDirectory: true)) }

    /// Moves the database folder aside (never deletes it) and returns the new place. The live folder is empty afterwards.
    static func quarantine(_ dir: URL, into root: URL = recoveryRoot, now: Date = Date()) throws -> URL {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        var dest = root.appendingPathComponent("Database-" + f.string(from: now), isDirectory: true)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) { n += 1; dest = root.appendingPathComponent("Database-\(f.string(from: now))-\(n)", isDirectory: true) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: dir, to: dest)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dest
    }

    /// Counts what a database folder holds, working on a throwaway copy so the original is never opened for writing.
    static func inspect(_ dir: URL) -> Inventory {
        var inv = Inventory()
        guard let work = try? workingCopy(of: dir) else { return inv }
        defer { try? FileManager.default.removeItem(at: work.deletingLastPathComponent()) }
        guard let c = try? Connection(path: work.path, readOnly: true) else { return inv }
        func count(_ t: String) -> Int { (try? c.scalarInt("SELECT COUNT(*) FROM \(t)")) ?? 0 }
        inv.readable = (try? c.scalarInt("SELECT COUNT(*) FROM sqlite_master")) != nil
        guard inv.readable else { return inv }
        inv.playlists = count("sources"); inv.favourites = count("favorites"); inv.collections = count("collections"); inv.profiles = count("profiles"); inv.history = count("watch_history")
        if let r = try? c.query("PRAGMA quick_check(1)", [], { $0.string(0) }).first, r != "ok" { inv.integrityProblem = r }
        return inv
    }

    /// Copies the personal tables of the old database (in `oldDir`) into `fresh`, which is already migrated to the current schema.
    static func salvage(from oldDir: URL, into fresh: DatabaseManager) -> (copied: [String: Int], lost: [String]) {
        var copied: [String: Int] = [:], lost: [String] = []
        guard let work = try? workingCopy(of: oldDir) else { return ([:], ["the old database could not be opened"]) }
        defer { try? FileManager.default.removeItem(at: work.deletingLastPathComponent()) }
        do {
            try fresh.maintenance { c in
                try c.exec("PRAGMA foreign_keys=OFF")
                defer { try? c.exec("PRAGMA foreign_keys=ON") }
                try c.execute("ATTACH DATABASE ? AS old", [work.path])
                defer { try? c.exec("DETACH DATABASE old") }
                for t in personalTables {
                    let mine = (try? c.query("PRAGMA main.table_info(\(t))", [], { $0.string(1) })) ?? []
                    guard let theirs = try? c.query("PRAGMA old.table_info(\(t))", [], { $0.string(1) }), !theirs.isEmpty else { continue }   // the table is simply not there
                    let cols = mine.filter(theirs.contains).map { "\"\($0)\"" }.joined(separator: ",")
                    guard !cols.isEmpty else { continue }
                    let insert = "INSERT OR REPLACE INTO main.\(t) (\(cols)) SELECT \(cols) FROM old.\(t)"
                    if t == "profile_state" { try c.exec("DELETE FROM main.profile_state") }      // the fresh database starts with a row of its own
                    do {
                        try c.exec(insert)
                        copied[t] = (try? c.scalarInt("SELECT COUNT(*) FROM main.\(t)")) ?? 0
                    } catch {
                        // A damaged page makes the whole scan fail: read it again in small slices and keep every slice that can be read.
                        guard let top = try? c.scalarInt("SELECT IFNULL(MAX(rowid),0) FROM old.\(t)"), top > 0 else { lost.append(t); continue }
                        var bad = 0, start = 0
                        while start <= top {
                            do { try c.exec(insert + " WHERE rowid BETWEEN \(start) AND \(start + 199)") } catch { bad += 1 }
                            start += 200
                        }
                        copied[t] = (try? c.scalarInt("SELECT COUNT(*) FROM main.\(t)")) ?? 0
                        if bad > 0 { lost.append("part of \(t)") }
                    }
                }
            }
        } catch { lost.append("the old database could not be opened (\(error))") }
        return (copied, lost)
    }

    /// Moves the damaged database aside, makes a fresh one and, if `keepPersonalData`, copies the personal tables into it.
    static func recover(keepPersonalData: Bool, databaseDirectory: URL = StorageService.databaseDirectory, root: URL = recoveryRoot, freshPath: ((URL) -> String)? = nil) throws -> Outcome {
        let kept = try quarantine(databaseDirectory, into: root)
        var out = Outcome(kept: kept)
        guard keepPersonalData else { return out }
        let path = freshPath?(databaseDirectory) ?? databaseDirectory.appendingPathComponent("reddy.sqlite").path
        let fresh = try DatabaseManager(path: path)
        (out.copied, out.lost) = salvage(from: kept, into: fresh)
        return out
    }

    /// A copy of the database file and its journal in a private temporary folder; the caller removes the folder.
    private static func workingCopy(of dir: URL) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let main = dir.appendingPathComponent("reddy.sqlite")
        guard FileManager.default.fileExists(atPath: main.path) else { throw CocoaError(.fileNoSuchFile) }
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: main.path + suffix)
            if FileManager.default.fileExists(atPath: src.path) { try FileManager.default.copyItem(at: src, to: tmp.appendingPathComponent("reddy.sqlite" + suffix)) }
        }
        return tmp.appendingPathComponent("reddy.sqlite")
    }
}
