import Foundation

/// The six native items of the top bar's first group. Podcasts is one of them; none of them can be hidden.
enum NavTab: String, CaseIterable, Identifiable, Sendable {
    case home, liveTV, movies, series, guide, podcasts
    var id: String { rawValue }
    var appTab: AppTab? {
        switch self { case .home: .home; case .liveTV: .liveTV; case .movies: .movies; case .series: .series; case .guide: .guide; case .podcasts: nil }
    }
    init(_ tab: AppTab) {
        switch tab { case .home: self = .home; case .liveTV: self = .liveTV; case .movies: self = .movies; case .series: self = .series; case .guide: self = .guide }
    }
    var title: String { appTab?.title ?? "Podcasts" }
    /// The symbol before the name: Podcasts keeps its microphone, Home is the house the StreamSetu chip already uses, TV Guide the calendar of the guide button on Live TV.
    var symbol: String {
        switch self { case .home: "house.fill"; case .liveTV: "tv"; case .movies: "film"; case .series: "rectangle.stack.fill"; case .guide: "calendar"; case .podcasts: "mic.fill" }
    }
}

/// How one native item is drawn. The default is the icon with the name.
enum TabBarMode: String, CaseIterable, Identifiable, Sendable {
    case iconAndName, iconOnly, nameOnly
    var id: String { rawValue }
    var title: String { switch self { case .iconAndName: "Icon and Name"; case .iconOnly: "Icon Only"; case .nameOnly: "Name Only" } }
}

/// The person's choice per native item, kept on this Mac. Only a choice that differs from the default is written, and the key disappears when none is left,
/// so an install that never changed anything stores nothing. Anything unreadable is read as the default.
struct TopBarTabModes: Equatable, Sendable {
    static let defaultsKey = "topbar.tabModes.v1"
    /// Posted after a change so the bar and Settings agree.
    nonisolated static let didChange = Notification.Name("topbar.tabModesDidChange")
    private(set) var chosen: [NavTab: TabBarMode] = [:]

    init(_ chosen: [NavTab: TabBarMode] = [:]) { self.chosen = chosen.filter { $0.value != .iconAndName } }

    func mode(_ t: NavTab) -> TabBarMode { chosen[t] ?? .iconAndName }
    var isDefault: Bool { chosen.isEmpty }
    mutating func set(_ m: TabBarMode, for t: NavTab) { chosen[t] = m == .iconAndName ? nil : m }
    mutating func reset() { chosen = [:] }

    static func load(from defaults: UserDefaults = .standard) -> TopBarTabModes {
        guard let data = defaults.data(forKey: defaultsKey), let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return TopBarTabModes() }
        var out: [NavTab: TabBarMode] = [:]
        for (k, v) in raw { if let t = NavTab(rawValue: k), let m = TabBarMode(rawValue: v) { out[t] = m } }
        return TopBarTabModes(out)
    }

    func save(to defaults: UserDefaults = .standard) {
        if chosen.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) }
        else if let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: chosen.map { ($0.key.rawValue, $0.value.rawValue) })) { defaults.set(data, forKey: Self.defaultsKey) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
