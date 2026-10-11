import Foundation

/// The preferences that follow the person from device to device: the app's settings and each playlist's own settings. Device
/// choices (such as which speaker to use) are not among them, and neither is the parental PIN.
final class DefaultsSettingsSync: SyncSettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let db: DatabaseManager
    private let lock = NSLock()

    init(defaults: UserDefaults, db: DatabaseManager) { self.defaults = defaults; self.db = db }

    private static let playlistParts: Set<String> = ["engine", "buffering", "catchupoffset", "guideshift", "useragent", "headers"]

    static func isSyncable(_ key: String) -> Bool {
        if AppSettings.knownKeys.contains(key) { return true }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "playlist" && UUID(uuidString: String(parts[1])) != nil && playlistParts.contains(String(parts[2]))
    }

    private var trackedKeys: [String] {
        defaults.dictionaryRepresentation().keys.filter(Self.isSyncable).sorted()
    }

    // MARK: value <-> JSON

    func json(forKey key: String) -> String? {
        guard Self.isSyncable(key), let o = defaults.object(forKey: key) else { return nil }
        let wrapped: [String: Any]
        if let s = o as? String { wrapped = ["t": "s", "v": s] }
        else if let n = o as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { wrapped = ["t": "b", "v": n.boolValue] }
            else if String(cString: n.objCType) == "d" || String(cString: n.objCType) == "f" { wrapped = ["t": "d", "v": n.doubleValue] }
            else { wrapped = ["t": "i", "v": n.intValue] }
        } else { return nil }
        guard let d = try? JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys]) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    func apply(json: String?, forKey key: String) {
        guard Self.isSyncable(key) else { return }                     // nothing outside the list is ever written
        lock.lock(); defer { lock.unlock() }
        guard let json else { defaults.removeObject(forKey: key); return }
        guard let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], let t = o["t"] as? String, let v = o["v"] else { return }
        switch t {
        case "s": if let s = v as? String, s.count <= 4000 { defaults.set(s, forKey: key) }
        case "b": if let b = v as? Bool { defaults.set(b, forKey: key) }
        case "i": if let i = v as? Int { defaults.set(i, forKey: key) }
        case "d": if let d = v as? Double, d.isFinite { defaults.set(d, forKey: key) }
        default: break
        }
    }

    // MARK: what changed here

    func changedKeys() -> [String] {
        let seen: [String: String] = (try? db.read { c in
            Dictionary(try c.query("SELECT key, json FROM sync_settings_seen") { ($0.string(0), $0.string(1)) }, uniquingKeysWith: { a, _ in a })
        }) ?? [:]
        var changed: [String] = []
        let current = Set(trackedKeys)
        for k in current where json(forKey: k) != seen[k] { changed.append(k) }
        for k in seen.keys where !current.contains(k) { changed.append(k) }     // a setting that was removed
        return changed
    }

    func markSeen(key: String) {
        let j = json(forKey: key)
        try? db.write { c in
            if let j { try c.execute("INSERT OR REPLACE INTO sync_settings_seen(key, json) VALUES(?, ?)", [key, j]) }
            else { try c.execute("DELETE FROM sync_settings_seen WHERE key = ?", [key]) }
        }
    }
}
