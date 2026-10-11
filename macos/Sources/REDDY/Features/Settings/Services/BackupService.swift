import Foundation

struct BackupOptions: OptionSet, Sendable {
    let rawValue: Int
    static let sources = BackupOptions(rawValue: 1)
    static let collections = BackupOptions(rawValue: 2)
    static let favorites = BackupOptions(rawValue: 4)
    static let preferences = BackupOptions(rawValue: 8)
    static let history = BackupOptions(rawValue: 16)
    /// Folder order, hidden items and folders, renames, PIN-locked folders and per-channel settings: the work of organising a library.
    static let organisation = BackupOptions(rawValue: 32)
    static let standard: BackupOptions = [.sources, .collections, .favorites, .preferences, .organisation]

    var labels: [String] {
        var out: [String] = []
        if contains(.sources) { out.append("Playlist names, types and addresses (no passwords)") }
        if contains(.collections) { out.append("Collections and what is in them") }
        if contains(.favorites) { out.append("Favorites") }
        if contains(.preferences) { out.append("Preferences") }
        if contains(.organisation) { out.append("Folder order, hidden items, renames and per-channel settings") }
        if contains(.history) { out.append("Viewing history and resume points") }
        return out
    }
}

struct ReddyBackup: Codable, Sendable {
    struct Source: Codable, Sendable { var id: String; var name: String; var type: String; var address: String; var guide: String?; var enabled: Bool }
    struct Item: Codable, Sendable { var itemID: String; var kind: String }
    struct Collection: Codable, Sendable { var name: String; var items: [Item] }
    struct HistoryEntry: Codable, Sendable { var itemID: String; var kind: String; var title: String; var playedAt: Date }
    struct Progress: Codable, Sendable { var itemID: String; var kind: String; var seriesID: String?; var position: Double; var duration: Double; var updatedAt: Date; var completed: Bool }

    struct Override: Codable, Sendable { var itemID: String; var displayName: String?; var categoryName: String?; var epgID: String? }
    struct Hidden: Codable, Sendable { var itemID: String; var kind: String }
    struct Organisation: Codable, Sendable {
        var folderOrder: [String] = []
        var hidden: [Hidden] = []
        var overrides: [Override] = []
        var lockedFolders: [String] = []
        var channelSettings: [String: ChannelPlaybackPref] = [:]
    }

    var format = "reddy-backup"
    var version = 1
    var createdAt = Date()
    var appVersion = AppConfiguration.version
    var includes: [String] = []
    var sources: [Source]?
    var collections: [Collection]?
    var favorites: [Item]?
    var preferences: [String: String]?
    var history: [HistoryEntry]?
    var progress: [Progress]?
    var organisation: Organisation?
}

struct RestorePlan: Sendable {
    var backup: ReddyBackup
    var newSources: [ReddyBackup.Source]
    /// Backup sources that match a playlist already here, by id or by type and address. They are not added twice.
    var duplicateSources: [(backup: ReddyBackup.Source, existing: UUID)]
    var unsupportedSources: [ReddyBackup.Source]
    var collectionCount: Int
    var favoriteCount: Int
    var preferenceCount: Int
    var historyCount: Int
    var organisationCount = 0

    var summary: [String] {
        var l: [String] = []
        if !newSources.isEmpty { l.append("\(newSources.count) playlist\(newSources.count == 1 ? "" : "s") to add (they will need their login or address)") }
        if !duplicateSources.isEmpty { l.append("\(duplicateSources.count) playlist\(duplicateSources.count == 1 ? "" : "s") already here, skipped") }
        if !unsupportedSources.isEmpty { l.append("\(unsupportedSources.count) local file playlist\(unsupportedSources.count == 1 ? "" : "s") can't be restored: add the file again") }
        if collectionCount > 0 { l.append("\(collectionCount) collection\(collectionCount == 1 ? "" : "s")") }
        if favoriteCount > 0 { l.append("\(favoriteCount) favorite\(favoriteCount == 1 ? "" : "s")") }
        if preferenceCount > 0 { l.append("\(preferenceCount) preference\(preferenceCount == 1 ? "" : "s")") }
        if historyCount > 0 { l.append("\(historyCount) history entr\(historyCount == 1 ? "y" : "ies")") }
        if organisationCount > 0 { l.append("\(organisationCount) folder, hidden-item and rename setting\(organisationCount == 1 ? "" : "s")") }
        return l
    }
}

struct RestoreResult: Sendable, Equatable {
    var sourcesAdded = 0, sourcesSkipped = 0, collections = 0, favorites = 0, preferences = 0, history = 0, organised = 0
    var summary: String {
        var p: [String] = []
        if sourcesAdded > 0 { p.append("\(sourcesAdded) playlist\(sourcesAdded == 1 ? "" : "s") added") }
        if collections > 0 { p.append("\(collections) collection\(collections == 1 ? "" : "s")") }
        if favorites > 0 { p.append("\(favorites) favorite\(favorites == 1 ? "" : "s")") }
        if preferences > 0 { p.append("\(preferences) preference\(preferences == 1 ? "" : "s")") }
        if history > 0 { p.append("\(history) history entr\(history == 1 ? "y" : "ies")") }
        if organised > 0 { p.append("\(organised) folder and channel setting\(organised == 1 ? "" : "s")") }
        return p.isEmpty ? "Nothing new to restore." : "Restored " + p.joined(separator: ", ") + "."
    }
}

enum BackupError: LocalizedError {
    case notABackup, unsupportedVersion(Int), tooLarge
    var errorDescription: String? {
        switch self {
        case .notABackup: "This file isn't a StreamSetu backup."
        case .unsupportedVersion(let v): "This backup was made by a newer version of StreamSetu (format \(v)). Update StreamSetu to restore it."
        case .tooLarge: "This file is too large to be a StreamSetu backup."
        }
    }
}

/// Exports and restores configuration and user data. Passwords, tokens and full playlist addresses are never written:
/// a restored playlist comes back without its login and asks for it. Playlists keep their ids, so favorites,
/// collections and history line up again as soon as the playlist has synced.
final class BackupService: @unchecked Sendable {
    private let db: DatabaseManager
    private let catalog: CatalogRepository
    private let sources: SourceManager
    static let maxBytes = 50 * 1024 * 1024

    init(db: DatabaseManager, catalog: CatalogRepository, sources: SourceManager) { self.db = db; self.catalog = catalog; self.sources = sources }

    // MARK: export

    @MainActor
    func export(_ options: BackupOptions, settings: AppSettings, channelPrefs: ChannelPlaybackPrefs? = nil) throws -> Data {
        var b = ReddyBackup()
        b.includes = options.labels
        if options.contains(.sources) {
            b.sources = try catalog.sources().map { .init(id: $0.id.uuidString.lowercased(), name: $0.name, type: $0.type.rawValue, address: $0.baseURL, guide: $0.epgURL, enabled: $0.enabled) }
        }
        if options.contains(.preferences) { b.preferences = settings.snapshot().filter { AppSettings.knownKeys.contains($0.key) } }
        try db.read { c in
            if options.contains(.favorites) {
                b.favorites = try c.query("SELECT item_id, kind FROM favorites ORDER BY kind, sort_order") { .init(itemID: $0.string(0), kind: $0.string(1)) }
            }
            if options.contains(.collections) {
                b.collections = try c.query("SELECT id, name FROM collections ORDER BY created_at") { r in (r.string(0), r.string(1)) }.map { id, name in
                    ReddyBackup.Collection(name: name, items: (try? c.query("SELECT item_id, kind FROM collection_items WHERE collection_id=? ORDER BY sort_order", [id]) { .init(itemID: $0.string(0), kind: $0.string(1)) }) ?? [])
                }
            }
            if options.contains(.organisation) {
                var o = ReddyBackup.Organisation()
                o.folderOrder = try c.query("SELECT category_id FROM folder_order ORDER BY position") { $0.string(0) }
                o.hidden = try c.query("SELECT item_id, kind FROM hidden_items") { .init(itemID: $0.string(0), kind: $0.string(1)) }
                o.overrides = try c.query("SELECT item_id, display_name, category_name, epg_id FROM metadata_overrides") { .init(itemID: $0.string(0), displayName: $0.optString(1), categoryName: $0.optString(2), epgID: $0.optString(3)) }
                o.lockedFolders = try c.query("SELECT category_id FROM locked_categories") { $0.string(0) }
                if let channelPrefs { o.channelSettings = channelPrefs.all() }
                b.organisation = o
            }
            if options.contains(.history) {
                b.history = try c.query("SELECT item_id, kind, title, played_at FROM watch_history ORDER BY played_at DESC LIMIT 500") { .init(itemID: $0.string(0), kind: $0.string(1), title: $0.string(2), playedAt: $0.date(3)) }
                b.progress = try c.query("SELECT item_id, kind, series_id, position_seconds, duration_seconds, updated_at, completed FROM watch_progress") {
                    .init(itemID: $0.string(0), kind: $0.string(1), seriesID: $0.optString(2), position: $0.double(3), duration: $0.double(4), updatedAt: $0.date(5), completed: $0.bool(6))
                }
            }
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        return try enc.encode(b)
    }

    // MARK: restore

    func plan(from data: Data) throws -> RestorePlan {
        guard data.count <= Self.maxBytes else { throw BackupError.tooLarge }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let b = try? dec.decode(ReddyBackup.self, from: data), b.format == "reddy-backup" else { throw BackupError.notABackup }
        guard b.version <= 1 else { throw BackupError.unsupportedVersion(b.version) }
        let existing = try catalog.sources()
        var fresh: [ReddyBackup.Source] = [], dupes: [(ReddyBackup.Source, UUID)] = [], unsupported: [ReddyBackup.Source] = []
        for s in b.sources ?? [] {
            guard UUID(uuidString: s.id) != nil, SourceType(rawValue: s.type) != nil else { continue }
            if s.type == SourceType.m3uLocal.rawValue { unsupported.append(s); continue }
            if let e = existing.first(where: { $0.id.uuidString.lowercased() == s.id.lowercased() || ($0.type.rawValue == s.type && $0.baseURL == s.address) }) { dupes.append((s, e.id)) }
            else { fresh.append(s) }
        }
        return RestorePlan(backup: b, newSources: fresh, duplicateSources: dupes, unsupportedSources: unsupported,
                           collectionCount: b.collections?.count ?? 0, favoriteCount: b.favorites?.count ?? 0,
                           preferenceCount: b.preferences?.count ?? 0, historyCount: (b.history?.count ?? 0) + (b.progress?.count ?? 0),
                           organisationCount: (b.organisation?.folderOrder.count ?? 0) + (b.organisation?.hidden.count ?? 0) + (b.organisation?.overrides.count ?? 0))
    }

    /// Rewrites an item id from a backup playlist to the playlist that is actually here (same playlist, different id).
    static func remap(_ itemID: String, _ map: [String: String]) -> String {
        guard let bar = itemID.firstIndex(of: "|") else { return itemID }
        let head = String(itemID[..<bar]).lowercased()
        guard let to = map[head] else { return itemID }
        return to + itemID[bar...]
    }

    @MainActor
    func apply(_ plan: RestorePlan, settings: AppSettings, channelPrefs: ChannelPlaybackPrefs? = nil) throws -> RestoreResult {
        var result = RestoreResult()
        let b = plan.backup
        var idMap: [String: String] = [:]
        for (s, existing) in plan.duplicateSources { idMap[s.id.lowercased()] = existing.uuidString.lowercased(); result.sourcesSkipped += 1 }

        for s in plan.newSources {
            guard let id = UUID(uuidString: s.id), let type = SourceType(rawValue: s.type) else { continue }
            // Without a login the playlist can't connect, so it is added switched off until the user supplies one.
            let source = PlaylistSource(id: id, name: s.name, type: type, baseURL: s.address, credentialRef: nil, epgURL: s.guide, enabled: false, syncStatus: "needs-login")
            try catalog.save(source: source)
            result.sourcesAdded += 1
        }

        try db.write { c in
            for fav in b.favorites ?? [] {
                guard ContentKind(rawValue: fav.kind) != nil else { continue }
                try c.execute("INSERT OR IGNORE INTO favorites(item_id, kind, created_at, sort_order) VALUES(?,?,?,0)", [Self.remap(fav.itemID, idMap), fav.kind, Date()])
                result.favorites += 1
            }
            for col in b.collections ?? [] {
                let name = col.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 120 else { continue }
                var id = try c.queryOne("SELECT id FROM collections WHERE name=? COLLATE NOCASE", [name]) { $0.string(0) }
                if id == nil { id = UUID().uuidString; try c.execute("INSERT INTO collections(id, name, created_at) VALUES(?,?,?)", [id, name, Date()]); result.collections += 1 }
                for (i, it) in col.items.enumerated() where ContentKind(rawValue: it.kind) != nil {
                    try c.execute("INSERT OR IGNORE INTO collection_items(collection_id, item_id, kind, sort_order, added_at) VALUES(?,?,?,?,?)", [id, Self.remap(it.itemID, idMap), it.kind, i, Date()])
                }
            }
            for h in b.history ?? [] where ContentKind(rawValue: h.kind) != nil {
                try c.execute("INSERT INTO watch_history(item_id, kind, title, played_at) VALUES(?,?,?,?)", [Self.remap(h.itemID, idMap), h.kind, h.title, h.playedAt])
                result.history += 1
            }
            for p in b.progress ?? [] where ContentKind(rawValue: p.kind) != nil && p.duration > 0 && p.position >= 0 {
                try c.execute("""
                    INSERT INTO watch_progress(item_id, kind, series_id, position_seconds, duration_seconds, updated_at, completed) VALUES(?,?,?,?,?,?,?)
                    ON CONFLICT(item_id) DO UPDATE SET position_seconds=excluded.position_seconds, duration_seconds=excluded.duration_seconds,
                        updated_at=excluded.updated_at, completed=excluded.completed WHERE excluded.updated_at > watch_progress.updated_at
                    """, [Self.remap(p.itemID, idMap), p.kind, p.seriesID.map { Self.remap($0, idMap) }, p.position, p.duration, p.updatedAt, p.completed])
            }
        }
        if let prefs = b.preferences { result.preferences = settings.apply(snapshot: prefs) }
        if let o = b.organisation {
            channelPrefs?.merge(Dictionary(uniqueKeysWithValues: o.channelSettings.map { (Self.remap($0.key, idMap), $0.value) }))
            try db.write { c in
                for (i, id) in o.folderOrder.enumerated() {
                    let mapped = Self.remap(id, idMap)
                    try c.execute("INSERT INTO folder_order(category_id, position) VALUES(?, ?) ON CONFLICT(category_id) DO NOTHING", [mapped, i])
                    result.organised += 1
                }
                for h in o.hidden where ["channel", "movie", "series", "category"].contains(h.kind) {
                    try c.execute("INSERT OR IGNORE INTO hidden_items(item_id, kind, hidden_at) VALUES(?,?,?)", [Self.remap(h.itemID, idMap), h.kind, Date()])
                    result.organised += 1
                }
                for ov in o.overrides {
                    try c.execute("INSERT OR IGNORE INTO metadata_overrides(item_id, display_name, category_name, epg_id) VALUES(?,?,?,?)", [Self.remap(ov.itemID, idMap), ov.displayName, ov.categoryName, ov.epgID])
                    result.organised += 1
                }
                for id in o.lockedFolders { try c.execute("INSERT OR IGNORE INTO locked_categories(category_id) VALUES(?)", [Self.remap(id, idMap)]) }
            }
        }
        return result
    }
}
