import Foundation
import CryptoKit
import Observation

struct Profile: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case adult, kids }
    let id: String
    var name: String
    var kind: Kind
    var hasPIN: Bool
    var color: Int
    var sortOrder: Int
}

/// Profiles: people who share one device and one playlist, each with their own favourites, collections, watch history and resume points.
///
/// The live tables always hold the active profile's rows, so nothing else in the app has to know about profiles. Switching saves the active profile's rows into
/// `profile_rows` and loads the other's, in one transaction, with both change logs paused so the move is not mistaken for the person deleting everything.
/// Sync (iCloud and on this network) carries the first profile only, so it is paused while another profile is active.
@MainActor @Observable
final class ProfileService {
    enum SwitchResult: Equatable { case switched, needsPIN, wrongPIN, failed }

    static let mainID = "main"
    /// Everyone who shares a device: the first profile and up to three more.
    static let maxProfiles = 4
    /// The tables that hold one person's own data. Collections come before their items.
    static let personalTables = ["favorites", "collections", "collection_items", "watch_progress", "watch_history", "recently_watched", "search_history", "new_episodes"]
    /// Preferences that belong to one person (the line of titles queued to play next). Each profile keeps its own copy.
    static let personalDefaultsKeys = ["watchQueue"]

    private let db: DatabaseManager
    private let defaults: UserDefaults
    private let onSwitched: @MainActor (Profile) -> Void
    /// Called just before the rows are swapped: whatever is playing is stopped, so its progress is saved to the profile that started it.
    var willSwitch: @MainActor () -> Void = {}
    private(set) var profiles: [Profile] = []
    private(set) var activeID = ProfileService.mainID

    var active: Profile { profiles.first { $0.id == activeID } ?? Profile(id: Self.mainID, name: "Me", kind: .adult, hasPIN: false, color: 0, sortOrder: 0) }
    /// More than one profile exists, so the app asks who is watching and shows the switcher.
    var isShared: Bool { profiles.count > 1 }
    var isMainActive: Bool { activeID == Self.mainID }
    var canAdd: Bool { profiles.count < Self.maxProfiles }

    init(db: DatabaseManager, defaults: UserDefaults = .standard, onSwitched: @escaping @MainActor (Profile) -> Void = { _ in }) {
        self.db = db; self.defaults = defaults; self.onSwitched = onSwitched
        reload()
    }

    func reload() {
        let rows = (try? db.read { c in
            try c.query("SELECT id, name, kind, pin_hash IS NOT NULL, color, sort_order FROM profiles ORDER BY sort_order, created_at", []) { r in
                Profile(id: r.string(0), name: r.string(1), kind: Profile.Kind(rawValue: r.string(2)) ?? .adult, hasPIN: r.int(3) != 0, color: r.int(4), sortOrder: r.int(5))
            }
        }) ?? []
        profiles = rows
        activeID = ((try? db.read { try $0.queryOne("SELECT active FROM profile_state", []) { $0.string(0) } }) ?? nil) ?? Self.mainID
        if !profiles.contains(where: { $0.id == activeID }) { activeID = Self.mainID }
    }

    static func hash(_ pin: String, salt: String) -> String { SHA256.hash(data: Data((salt + pin).utf8)).map { String(format: "%02x", $0) }.joined() }
    static func isValidPIN(_ pin: String) -> Bool { (4...8).contains(pin.count) && pin.allSatisfy { $0.isASCII && $0.isNumber } }

    // MARK: managing

    /// Adds a profile. A kids profile must have a PIN, which is asked when leaving it.
    @discardableResult
    func add(name: String, kind: Profile.Kind, pin: String?) -> Profile? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, profiles.count < Self.maxProfiles, !profiles.contains(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) else { return nil }
        if kind == .kids, !(pin.map(Self.isValidPIN) ?? false) { return nil }
        if let pin, !Self.isValidPIN(pin) { return nil }
        let id = UUID().uuidString.lowercased()
        let salt = UUID().uuidString
        let color = profiles.count % 6
        do {
            try db.write { c in
                try c.execute("INSERT INTO profiles(id, name, kind, pin_salt, pin_hash, color, sort_order, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)",
                              [id, clean, kind.rawValue, pin == nil ? nil : salt, pin.map { Self.hash($0, salt: salt) }, color, profiles.count, Date().timeIntervalSince1970])
            }
        } catch { return nil }
        reload()
        return profiles.first { $0.id == id }
    }

    func rename(_ id: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !profiles.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(clean) == .orderedSame }) else { return }
        try? db.write { try $0.execute("UPDATE profiles SET name = ? WHERE id = ?", [clean, id]) }
        reload()
    }

    /// Removes a profile and everything it kept. The main profile and the one in use cannot be removed.
    @discardableResult
    func remove(_ id: String) -> Bool {
        guard id != Self.mainID, id != activeID else { return false }
        do { try db.write { c in try c.execute("DELETE FROM profile_rows WHERE profile_id = ?", [id]); try c.execute("DELETE FROM profiles WHERE id = ?", [id]) } } catch { return false }
        reload()
        return true
    }

    /// Seconds until a PIN try is allowed again for this profile, or nil.
    func pinLockedFor(_ id: String) -> TimeInterval? { PINThrottle(name: "profile." + id, defaults: defaults).lockedFor() }

    func checkPIN(_ id: String, _ pin: String) -> Bool {
        PINThrottle(name: "profile." + id, defaults: defaults).attempt { rawCheckPIN(id, pin) } == .right
    }

    private func rawCheckPIN(_ id: String, _ pin: String) -> Bool {
        guard let row = try? db.read({ c in try c.queryOne("SELECT pin_salt, pin_hash FROM profiles WHERE id = ?", [id]) { ($0.string(0), $0.string(1)) } }) else { return false }
        return Self.hash(pin, salt: row.0) == row.1
    }

    // MARK: switching

    /// Makes `id` the active profile. Entering an adult profile that has a PIN needs that PIN, and leaving a kids profile needs the kids profile's PIN.
    func switchTo(_ id: String, pin: String? = nil) -> SwitchResult {
        guard id != activeID, let target = profiles.first(where: { $0.id == id }) else { return .switched }
        if active.kind == .kids || (target.kind == .adult && target.hasPIN) {
            let needed = active.kind == .kids ? active.id : target.id
            guard let pin else { return .needsPIN }
            guard checkPIN(needed, pin) else { return .wrongPIN }
        }
        willSwitch()
        do { try swapData(from: activeID, to: id) } catch { return .failed }
        swapDefaults(from: activeID, to: id)
        reload()
        onSwitched(active)
        return .switched
    }

    /// Whether leaving the active profile needs a PIN (the person is in a kids profile).
    var leavingNeedsPIN: Bool { active.kind == .kids }

    private func swapDefaults(from: String, to: String) {
        for key in Self.personalDefaultsKeys {
            defaults.set(defaults.object(forKey: key), forKey: "\(key).profile.\(from)")
            if let theirs = defaults.object(forKey: "\(key).profile.\(to)") { defaults.set(theirs, forKey: key) } else { defaults.removeObject(forKey: key) }
            defaults.removeObject(forKey: "\(key).profile.\(to)")
        }
    }

    private func columns(_ c: Connection, _ table: String) throws -> [String] {
        try c.query("SELECT name FROM pragma_table_info('\(table)')", []) { $0.string(0) }.filter { !(table == "watch_history" && $0 == "id") }
    }

    private func swapData(from: String, to: String) throws {
        try db.write { c in
            try c.execute("UPDATE sync_flags SET applying = 1")
            try c.execute("UPDATE lan_flag SET applying = 1")
            try c.execute("DELETE FROM profile_rows WHERE profile_id = ?", [from])
            for t in Self.personalTables {
                let cols = try columns(c, t)
                let obj = cols.map { "'\($0)', \($0)" }.joined(separator: ", ")
                try c.execute("INSERT INTO profile_rows(profile_id, tbl, data) SELECT ?, '\(t)', json_object(\(obj)) FROM \(t)", [from])
            }
            for t in Self.personalTables.reversed() { try c.execute("DELETE FROM \(t)") }
            for t in Self.personalTables {
                let cols = try columns(c, t)
                let pull = cols.map { "json_extract(data, '$.\($0)')" }.joined(separator: ", ")
                try c.execute("INSERT OR IGNORE INTO \(t)(\(cols.joined(separator: ", "))) SELECT \(pull) FROM profile_rows WHERE profile_id = ? AND tbl = '\(t)'", [to])
            }
            try c.execute("DELETE FROM profile_rows WHERE profile_id = ?", [to])
            try c.execute("UPDATE profile_state SET active = ?", [to])
            try c.execute("UPDATE sync_flags SET applying = 0")
            try c.execute("UPDATE lan_flag SET applying = 0")
        }
    }
}
