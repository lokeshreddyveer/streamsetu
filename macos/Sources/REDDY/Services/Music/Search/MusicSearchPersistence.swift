import Foundation

/// What the Search screen remembers between visits and launches (the words, the type chip and where it looks), and the rules for bringing it back.
/// The rules are pure so they are checked without a screen: a saved search is restored only within 24 hours of its last use, never in a gated mode,
/// and never over words the person already has in the field. The scroll position is kept by the shell's page memory, not here.
enum MusicSearchPersistence {
    /// A saved search that has not been used for this long is forgotten, so the screen does not open on a stale query forever.
    static let lifetime: TimeInterval = 24 * 3_600
    /// A clock that moved back a little must not throw away a fresh save.
    static let clockSlack: TimeInterval = 300

    struct State: Codable, Equatable, Sendable {
        var query: String
        var kind: String
        var scope: String
        var savedAt: Date
    }

    enum Decision: Equatable {
        case restore(State)
        case nothingSaved
        case expired
        case gated
        case fieldNotEmpty
        case blank
    }

    static func shouldRestore(savedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(savedAt)
        return age >= -clockSlack && age <= lifetime
    }

    /// The state worth saving for the words and chips now on the page; nil for blank words (which means "forget").
    static func state(query: String, kind: String, scope: String, now: Date) -> State? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        return State(query: String(q.prefix(200)), kind: kind, scope: scope, savedAt: now)
    }

    static func decide(saved: State?, gated: Bool, currentQuery: String, now: Date) -> Decision {
        if gated { return .gated }
        guard let saved else { return .nothingSaved }
        if !currentQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .fieldNotEmpty }
        guard shouldRestore(savedAt: saved.savedAt, now: now) else { return .expired }
        guard !saved.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .blank }
        return .restore(saved)
    }
}

/// Reads and writes the saved search as one small value in UserDefaults. Device-local; it records activity, so the privacy wipe removes it
/// (the key is listed in `MusicDefaultsKeys.activity`).
struct MusicSearchPersistenceStore {
    static let key = "music.shell.searchState"
    var defaults: UserDefaults = .standard

    func load() -> MusicSearchPersistence.State? {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(MusicSearchPersistence.State.self, from: $0) }
    }

    /// Saves `state`; nil removes the saved search (an explicit Clear, blank words).
    func save(_ state: MusicSearchPersistence.State?) {
        if let state, let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) }
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}
