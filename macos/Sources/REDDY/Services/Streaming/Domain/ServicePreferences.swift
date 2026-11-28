import Foundation

/// Which services are pinned to the top bar, in what order, and the last few opened. Pure value type: ids only, no history, no web data.
/// Pinning is presentation only; unpinning never signs out or clears anything. The temporary chip for an active-but-unpinned service is
/// derived by the planner and never stored here.
struct ServicePreferences: Equatable, Codable, Sendable {
    static let defaultsKey = "streaming.servicePreferences.v1"
    static let maxRecents = 3

    private(set) var pinned: [ProviderID]
    private(set) var recents: [ProviderID]

    /// The ids a mutation or decode may accept: listed services on the Mac, unless the caller says otherwise.
    static var standardAvailable: [ProviderID] { ProviderRegistry.standard.listed(on: .macOS).map(\.id) }

    init(pinned: [ProviderID], recents: [ProviderID] = []) { self.pinned = pinned; self.recents = recents }

    /// Fresh installs, and existing installs that never saved: identical to the bar before the hub (one pin).
    static func initial(available: [ProviderID] = standardAvailable) -> ServicePreferences {
        ServicePreferences(pinned: ProviderCatalog.defaultPinned.filter(available.contains), recents: [])
    }

    /// `podcastsInBar` is an old key (Podcasts can no longer be hidden): it may be present in saved data and is ignored; it is never written again.
    private enum CodingKeys: String, CodingKey { case pinned, recents }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pinned = try c.decodeIfPresent([ProviderID].self, forKey: .pinned) ?? ProviderCatalog.defaultPinned
        recents = try c.decodeIfPresent([ProviderID].self, forKey: .recents) ?? []
    }

    /// The stored form is pinned and recents only.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(recents, forKey: .recents)
    }

    // MARK: persistence

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    /// Never throws. Absent or corrupt data gives `initial`; unknown, unavailable and duplicate ids are dropped; an older plain list of ids is accepted.
    static func decode(_ data: Data?, available: [ProviderID] = standardAvailable) -> ServicePreferences {
        guard let data, !data.isEmpty else { return initial(available: available) }
        let decoder = JSONDecoder()
        var p: ServicePreferences
        if let s = try? decoder.decode(ServicePreferences.self, from: data) { p = s }
        else if let ids = try? decoder.decode([String].self, from: data) { p = ServicePreferences(pinned: ids.map(ProviderID.init(unchecked:))) }
        else { return initial(available: available) }
        p.sanitize(available: available)
        return p
    }

    static func load(from defaults: UserDefaults = .standard, available: [ProviderID] = standardAvailable) -> ServicePreferences {
        decode(defaults.data(forKey: defaultsKey), available: available)
    }
    func save(to defaults: UserDefaults = .standard) { defaults.set(encoded(), forKey: Self.defaultsKey) }

    /// Drops unknown, unavailable and duplicate ids; caps recents.
    mutating func sanitize(available: [ProviderID] = standardAvailable) {
        let ok = Set(available)
        var seen = Set<ProviderID>()
        pinned = pinned.filter { ok.contains($0) && seen.insert($0).inserted }
        seen = []
        recents = Array(recents.filter { ok.contains($0) && seen.insert($0).inserted }.prefix(Self.maxRecents))
    }

    // MARK: edits

    func isPinned(_ id: ProviderID) -> Bool { pinned.contains(id) }

    /// Appends at the end. Returns false (and changes nothing) for an unavailable id or one already pinned.
    @discardableResult mutating func pin(_ id: ProviderID, available: [ProviderID] = standardAvailable) -> Bool {
        guard available.contains(id), !pinned.contains(id) else { return false }
        pinned.append(id); return true
    }

    @discardableResult mutating func unpin(_ id: ProviderID) -> Bool {
        guard let i = pinned.firstIndex(of: id) else { return false }
        pinned.remove(at: i); return true
    }

    /// Moves a pinned id to `index` (clamped to the list). Returns false when the id is not pinned.
    @discardableResult mutating func move(_ id: ProviderID, to index: Int) -> Bool {
        guard let i = pinned.firstIndex(of: id) else { return false }
        let target = max(0, min(index, pinned.count - 1))
        pinned.remove(at: i); pinned.insert(id, at: target); return true
    }
    @discardableResult mutating func moveLeft(_ id: ProviderID) -> Bool { pinned.firstIndex(of: id).map { move(id, to: $0 - 1) && $0 > 0 } ?? false }
    @discardableResult mutating func moveRight(_ id: ProviderID) -> Bool { pinned.firstIndex(of: id).map { move(id, to: $0 + 1) && $0 < pinned.count - 1 } ?? false }

    /// Back to the default pins. Recents are kept; nothing else is touched.
    mutating func resetOrder(available: [ProviderID] = standardAvailable) { pinned = Self.initial(available: available).pinned }

    /// Records a selection (most recent first, no duplicates, at most three). Ids only; no viewing history.
    mutating func noteOpened(_ id: ProviderID, available: [ProviderID] = standardAvailable) {
        guard available.contains(id) else { return }
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
    }
}

// MARK: - keep services playing in the background

extension ServicePreferences {
    /// "Keep services playing in the background". Stored beside the preferences (its own key, so the stored form of the pins is unchanged). Default ON.
    /// On: a service keeps playing when another destination shows (as far as WebKit allows without a visible page; see the Settings caption).
    /// Off: the previous behaviour, a switch pauses.
    static let keepPlayingDefaultsKey = "streaming.servicePreferences.keepPlayingInBackground"
    static func keepsPlayingInBackground(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: keepPlayingDefaultsKey) as? Bool ?? true
    }
    static func setKeepsPlayingInBackground(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: keepPlayingDefaultsKey)
    }
}
