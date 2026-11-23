import Foundation

/// One thing Setu knows about the app: a screen, a setting, a shortcut, a how-to. Plain data (Foundation only) so it compiles on Mac, iPhone and in the test target.
enum AtlasKind: String, Codable, CaseIterable, Sendable {
    case screen, settingsPage, setting, control, menuItem, shortcut, contextAction, gesture, intent, recipe, diagnosis, meta
}

enum AtlasSafety: String, Codable, Sendable {
    case read      // Setu may open it and read its value
    case change    // Setu may propose a change; the person confirms
    case confirm   // a proposal needs an extra explicit step
    case never     // Setu explains and points, never acts
}

struct AtlasPlatforms: OptionSet, Codable, Sendable, Hashable {
    let rawValue: Int
    static let mac = AtlasPlatforms(rawValue: 1)
    static let iPhone = AtlasPlatforms(rawValue: 2)
    static let iPad = AtlasPlatforms(rawValue: 4)
    /// Hidden in the App Store build.
    static let dmgOnly = AtlasPlatforms(rawValue: 8)
    static let all: AtlasPlatforms = [.mac, .iPhone, .iPad]
}

enum AtlasReach: Codable, Sendable, Equatable, Hashable {
    case tab(String), shortcut(String), destination(String), modal(String), settingsPage(String), window(String), deepLink(String), searchCommand(String)
    case none
}

struct AtlasValueReader: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable { case toggle, choice, number, text, status }
    var kind: Kind
    var settingKey: String?
    var options: [String] = []
    var defaultValue: String?
}

struct AtlasStep: Codable, Sendable, Hashable { var say: String; var anchor: String?; var reach: AtlasReach? }

struct AtlasEntry: Codable, Identifiable, Sendable, Hashable {
    let id: String
    var kind: AtlasKind
    var title: String
    var aliases: [String] = []
    var summary: String
    var detail: String?
    var path: [String]
    var reach: AtlasReach
    var value: AtlasValueReader?
    var platforms: AtlasPlatforms = .all
    var shortcut: String?
    var anchor: String?
    var related: [String] = []
    var recipe: [AtlasStep]?
    var safety: AtlasSafety
    /// Guide-only: Setu explains this and points to it but never changes it, whatever else is true of it (app lock, proxy, parental controls). Setu must not offer a change button when this is set.
    var guideOnly: Bool = false
    var since: String?
    var reviewed: Bool = false

    /// True only when Setu may put a "Change it" proposal in front of the person.
    var mayPropose: Bool { !guideOnly && (safety == .change || safety == .confirm) }
}
