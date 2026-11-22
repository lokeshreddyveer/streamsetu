import Foundation

/// One copy of a title, as the identity layer sees it.
struct IdentityMember: Equatable, Sendable {
    let itemID: String
    let sourceID: UUID
    let language: String?
    let qualityRank: Int
    let isCam: Bool
    let year: Int?
    /// When the playlist added it (seconds since 1970; 0 when unknown).
    let addedAt: Double
}

/// A playlist's standing for choosing between copies, from what the app already knows (no network).
struct SourceHealth: Equatable, Sendable {
    let id: UUID
    let enabled: Bool
    let syncStatus: String
    let lastSync: Date?
    let sortOrder: Int
}

enum PreferredSource {
    static let staleAfter: TimeInterval = 14 * 86400

    /// Playlists best first, as a rank (0 is best): enabled ones; then ones not in a failed state (a failed or 14-days-stale sync ranks below a healthy twin, unless it is the only
    /// one); then the person's own choice, when set; then the playlist order from Settings; then the id, bytewise, so the order never depends on how the rows came back.
    static func ranking(_ sources: [SourceHealth], userPreferred: UUID? = nil, now: Date = Date()) -> [UUID: Int] {
        let enabledCount = sources.filter(\.enabled).count
        func healthy(_ s: SourceHealth) -> Bool {
            if s.syncStatus == "failed" { return false }
            if enabledCount <= 1 { return true }
            guard let last = s.lastSync else { return true }          // never synced is not a failure
            return now.timeIntervalSince(last) <= staleAfter
        }
        let ordered = sources.sorted { a, b in
            if a.enabled != b.enabled { return a.enabled }
            let ha = healthy(a), hb = healthy(b)
            if ha != hb { return ha }
            let pa = a.id == userPreferred, pb = b.id == userPreferred
            if pa != pb { return pa }
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            return a.id.uuidString.lowercased().utf8.lexicographicallyPrecedes(b.id.uuidString.lowercased().utf8)
        }
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.id, $0) })
    }
}

/// Which copy of a title a card shows. Deterministic: the same copies always give the same order.
enum CanonicalPick {
    struct Context: Sendable {
        /// The audio language from Settings, by the English name used on the chips ("Telugu"); nil when none is set.
        var preferredLanguage: String?
        var sourceRank: [UUID: Int]
        init(preferredLanguage: String? = nil, sourceRank: [UUID: Int] = [:]) { self.preferredLanguage = preferredLanguage; self.sourceRank = sourceRank }
    }

    /// Best first: (1) the preferred audio language, (2) the better picture (a cinema recording last), (3) the preferred playlist, (4) the newer addition, (5) the item id, bytewise.
    static func ordered(_ members: [IdentityMember], context: Context) -> [IdentityMember] {
        let want = context.preferredLanguage?.lowercased()
        func lang(_ m: IdentityMember) -> Int { want != nil && m.language?.lowercased() == want ? 0 : 1 }
        return members.sorted { a, b in
            if lang(a) != lang(b) { return lang(a) < lang(b) }
            if a.qualityRank != b.qualityRank { return a.qualityRank > b.qualityRank }
            let sa = context.sourceRank[a.sourceID] ?? Int.max, sb = context.sourceRank[b.sourceID] ?? Int.max
            if sa != sb { return sa < sb }
            if a.addedAt != b.addedAt { return a.addedAt > b.addedAt }
            return a.itemID.utf8.lexicographicallyPrecedes(b.itemID.utf8)
        }
    }

    static func pick(_ members: [IdentityMember], context: Context) -> IdentityMember? { ordered(members, context: context).first }

    /// The setting ("te", "Telugu") as the English language name used by identity, or nil.
    static func languageName(fromSetting setting: String) -> String? {
        let s = setting.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let n = IdentityKey.languageNames[s.lowercased()] { return n }
        return Locale(identifier: "en").localizedString(forLanguageCode: s).flatMap { IdentityKey.languageNames[$0.lowercased()] }
    }
}
