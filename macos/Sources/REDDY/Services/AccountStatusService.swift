import Foundation
import Observation

/// Asks each playlist's provider when the subscription ends, at most twice a day, and keeps the answers. Playlists whose provider gives no account details are skipped.
@MainActor @Observable
final class AccountStatusService {
    struct Warning: Equatable { let sourceName: String; let text: String; let ended: Bool }

    private(set) var statuses: [UUID: AccountStatus] = [:]
    private(set) var checking = false
    private let catalog: CatalogRepository
    private let provider: @Sendable (PlaylistSource) throws -> SourceProvider
    private let defaults: UserDefaults
    private let key = "accounts.status"
    private let stampKey = "accounts.checked"

    init(catalog: CatalogRepository, defaults: UserDefaults, provider: @escaping @Sendable (PlaylistSource) throws -> SourceProvider) {
        self.catalog = catalog; self.defaults = defaults; self.provider = provider
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([String: AccountStatus].self, from: data) {
            statuses = Dictionary(uniqueKeysWithValues: saved.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        }
    }

    /// Asks again unless it was asked in the last twelve hours (or `force`).
    func refresh(force: Bool = false, now: Date = Date()) async {
        if !force, let last = defaults.object(forKey: stampKey) as? Date, now.timeIntervalSince(last) < 12 * 3600 { return }
        checking = true; defer { checking = false }
        let sources = ((try? catalog.sources()) ?? []).filter { $0.enabled && $0.type == .xtream }
        let make = provider
        for s in sources {
            if let status = try? await make(s).accountStatus() { statuses[s.id] = status }
        }
        statuses = statuses.filter { id, _ in sources.contains { $0.id == id } }
        defaults.set(try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: statuses.map { ($0.key.uuidString, $0.value) })), forKey: key)
        defaults.set(now, forKey: stampKey)
    }

    /// Playlists that end within a week or have ended, most urgent first.
    func warnings(now: Date = Date()) -> [Warning] {
        let names = Dictionary(uniqueKeysWithValues: ((try? catalog.sources()) ?? []).map { ($0.id, $0.name) })
        return statuses.compactMap { id, st -> (Int, Warning)? in
            let level = st.level(now: now)
            guard level != .fine, let name = names[id] else { return nil }
            return (st.daysLeft(now: now) ?? -9999, Warning(sourceName: name, text: st.summary(now: now), ended: level == .ended))
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
