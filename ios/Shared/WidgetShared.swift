import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// What the app and its widgets share: a small list kept in the App Group, and the shape of the download Live Activity. Compiled into both.
enum WidgetShared {
    static let group = "group.app.streamsetu.shared"
    private static let key = "widget.continue"

    struct Item: Codable, Hashable, Identifiable {
        var title: String
        var subtitle: String
        /// 0 to 1, how far through it the person is.
        var progress: Double
        /// A streamsetu:// link that opens it.
        var link: String
        var id: String { link + title }
    }

    static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    static func save(_ items: [Item]) {
        guard let d = defaults, let data = try? JSONEncoder().encode(Array(items.prefix(6))) else { return }
        d.set(data, forKey: key)
    }

    static func load() -> [Item] {
        guard let data = defaults?.data(forKey: key), let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items
    }
}

#if canImport(ActivityKit)
/// The Live Activity for downloads: what is being saved, and how far along.
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var fraction: Double
        /// Downloads still waiting after this one.
        var waiting: Int
    }
    var started: Date
}
#endif
