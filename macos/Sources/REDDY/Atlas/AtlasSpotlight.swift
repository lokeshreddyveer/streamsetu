import Foundation
import CoreSpotlight
import CryptoKit

/// Which Atlas entries the system search (Spotlight) may know about, and how the index is kept in step with the Atlas.
/// Only screens and settings go in (not recipes, shortcuts or fixes), and nothing that concerns locks, kids, profiles or hidden things: a search result must never reveal that those exist.
/// The selection is pure and tested; the indexing calls are thin.
enum AtlasSpotlight {
    static let domain = "app.streamsetu.atlas"
    static let hashKey = "atlas.spotlight.indexedHash"
    /// Bump when this policy changes, so a new rule re-indexes even when no entry changed.
    static let policyVersion = 1

    static let kinds: Set<AtlasKind> = [.screen, .settingsPage, .setting]
    /// A word in an entry's id, title or path that keeps it out of the index.
    static let withheld: Set<String> = ["parental", "kids", "kid", "lock", "locked", "unlock", "applock", "profiles", "hidden", "restricted", "passcode", "pin", "private", "adult", "pairing"]

    static func words(_ text: String) -> [String] {
        // "setting.appLock" -> setting, app, lock; "Parental Controls" -> parental, controls
        var out: [String] = [], cur = ""
        func flush() { if !cur.isEmpty { out.append(cur.lowercased()); cur = "" } }
        var previousLower = false
        for ch in text {
            if ch.isLetter || ch.isNumber {
                if ch.isUppercase && previousLower { flush() }
                cur.append(ch); previousLower = ch.isLowercase
            } else { flush(); previousLower = false }
        }
        flush()
        return out
    }

    static func isWithheld(_ e: AtlasEntry) -> Bool {
        let all = words(e.id) + e.path.flatMap(words) + words(e.title)
        return all.contains { withheld.contains($0) }
    }

    /// The entries to put in the system index on this platform, in a stable order.
    static func indexable(_ entries: [AtlasEntry], platform: AtlasPlatforms, appStore: Bool) -> [AtlasEntry] {
        entries.filter { e in
            kinds.contains(e.kind) && e.reach != .none && !e.platforms.isDisjoint(with: platform) && !(appStore && e.platforms.contains(.dmgOnly)) && !isWithheld(e)
        }.sorted { $0.id < $1.id }
    }

    /// A fingerprint of what would be indexed: it changes when an entry's words change, so the index is rebuilt after an update and not at every start.
    static func fingerprint(_ entries: [AtlasEntry]) -> String {
        var h = SHA256()
        h.update(data: Data("v\(policyVersion)".utf8))
        for e in entries { h.update(data: Data([e.id, e.title, e.summary, e.path.joined(separator: ">"), e.aliases.joined(separator: ",")].joined(separator: "\u{1f}").utf8)) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func attributes(_ e: AtlasEntry) -> CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .content)
        set.title = e.title
        set.displayName = e.title
        set.contentDescription = e.summary + (e.path.count > 1 ? "\n" + e.path.joined(separator: " > ") : "")
        set.keywords = Array(Set(e.aliases + e.path + [e.title]))
        return set
    }

    /// Drops everything this app put in the index (kids profile on, or the entries stopped qualifying).
    static func removeAll(defaults: UserDefaults = .standard) async {
        try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
        defaults.removeObject(forKey: hashKey)
    }

    /// Plain Spotlight items (the Mac, which has no App Intents in the downloaded build). iPhone and iPad index the same entries as App Entities instead (see AtlasEntryEntity).
    /// Returns how many were indexed; 0 when nothing changed since last time.
    @discardableResult
    static func reindexPlainItemsIfNeeded(_ entries: [AtlasEntry], suppressed: Bool, defaults: UserDefaults = .standard) async -> Int {
        guard !suppressed else { await removeAll(defaults: defaults); return 0 }
        let fp = fingerprint(entries)
        guard defaults.string(forKey: hashKey) != fp else { return 0 }
        let items = entries.map { e -> CSSearchableItem in
            let item = CSSearchableItem(uniqueIdentifier: e.id, domainIdentifier: domain, attributeSet: attributes(e))
            item.expirationDate = .distantFuture
            return item
        }
        do {
            try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
            try await CSSearchableIndex.default().indexSearchableItems(items)
            defaults.set(fp, forKey: hashKey)
            return items.count
        } catch { return 0 }
    }

    /// The Atlas id a tapped Spotlight result carries (the unique identifier of the plain item, or of the entity), if it is one of ours.
    static func atlasID(fromActivityIdentifier id: String?) -> String? {
        guard let id, DeepLink.validAtlasID(id) else { return nil }
        return id
    }
}
