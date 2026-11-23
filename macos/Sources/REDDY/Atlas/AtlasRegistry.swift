import Foundation

/// Builds the atlas from what the app already declares. Stage 0 only reads the existing catalog, the guide articles and the tab and shortcut lists; nothing there is edited.
@MainActor enum AtlasRegistry {
    /// Settings Setu explains but never changes, whatever the catalog says.
    static let guideOnlyIDs: Set<String> = ["setting.appLock", "setting.proxy", "setting.parental"]

    /// Help articles (AppGuide) whose text was checked against the app. The ones that did not match are replaced in Declarations/Guide.swift.
    static let reviewedGuides: Set<String> = ["guide.addingStalkerOrHdhomerun", "guide.guideProblems", "guide.playerEngines", "guide.signInAndLoginProblems", "guide.whereStreamsetuKeepsThings", "guide.search",
                                              "guide.favoritesAndWatchLater", "guide.continueWatchingAndHistory", "guide.collections", "guide.liveTvAndTheGuide", "guide.playlists", "guide.recordingAndDownloads",
                                              "guide.subtitles", "guide.audio", "guide.playbackProblems", "guide.backupAndSync"]

    static func importEntries() -> [AtlasEntry] {
        var out: [AtlasEntry] = []
        for e in AppSettingsCatalog.all {
            let (summary, detail) = split(e.detail)
            let id = "setting.\(e.id)", path = e.path.components(separatedBy: " → ")
            let guide = guideOnlyIDs.contains(id)
            var value: AtlasValueReader?
            if e.changeable || e.read != nil {
                let kind: AtlasValueReader.Kind = e.kind == .toggle ? .toggle : e.kind == .number ? .number : .choice
                value = AtlasValueReader(kind: kind, settingKey: e.id, options: e.options)
            }
            let note = AtlasSettings.notes[e.id]
            out.append(AtlasEntry(id: id, kind: .setting, title: e.title, aliases: (aliases[e.id] ?? []) + (note?.aliases ?? []), summary: note?.summary ?? summary, detail: note?.detail ?? detail,
                                  path: path, reach: reach(path), value: value, platforms: note?.platforms ?? .all, related: note?.related ?? [],
                                  safety: guide ? .never : (e.changeable ? .change : .read), guideOnly: guide, reviewed: note?.reviewed ?? false))
        }
        for a in AppGuide.articles {
            let (summary, detail) = split(a.body)
            let gid = "guide." + slug(a.title)
            out.append(AtlasEntry(id: gid, kind: .recipe, title: a.title, aliases: a.keys, summary: summary, detail: detail, path: ["Help", a.title], reach: .none, safety: .read, reviewed: reviewedGuides.contains(gid)))
        }
        for t in AppTab.allCases {
            out.append(AtlasEntry(id: "screen.tab." + String(describing: t), kind: .screen, title: t.title, summary: "The \(t.title) page of the app.", path: [t.title], reach: .tab(t.rawValue), safety: .read))
        }
        let shortcuts: [Shortcut] = [.tonight, .discover, .continueWatching, .recentlyWatched, .watchHistory, .favorites, .watchLater, .collections, .featured, .allMovies, .recentlyAdded, .library, .allChannels, .statistics,
                                     .unwatched, .unwatchedFavorites, .addedThisMonth, .newEpisodes]
        for s in shortcuts {
            out.append(AtlasEntry(id: "screen.shortcut." + String(describing: s), kind: .screen, title: s.title, summary: "\(s.title) in the sidebar.", path: ["Sidebar", s.title], reach: .shortcut(s.rawValue), safety: .read))
        }
        return out
    }

    /// A few spoken names for imported settings. Stage 1 replaces these with reviewed aliases per entry.
    private static let aliases: [String: [String]] = [
        "hardwareDecoding": ["hw decode", "gpu decoding", "hardware acceleration", "videotoolbox"],
        "subtitlesByDefault": ["subs always on", "captions on"],
        "autoPlayNextEpisode": ["binge mode", "autoplay next"],
        "enginePreference": ["mpv", "avplayer", "player"],
        "bufferingMode": ["stutter", "lag"],
        "icloudSync": ["sync devices", "cloud sync"],
        "vpn": ["kill switch", "vpn drops"],
        "appLock": ["touch id", "passcode", "password"],
    ]

    private static func reach(_ path: [String]) -> AtlasReach {
        path.first == "Settings" && path.count > 1 ? .settingsPage(path[1]) : .none
    }

    private static func split(_ s: String) -> (String, String?) {
        guard let r = s.range(of: ". ") else { return (s, nil) }
        let first = String(s[s.startIndex..<r.lowerBound]) + ".", rest = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (first, rest.isEmpty ? nil : rest)
    }

    static func slug(_ s: String) -> String {
        let words = s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return words.enumerated().map { $0.offset == 0 ? $0.element : $0.element.prefix(1).uppercased() + $0.element.dropFirst() }.joined()
    }
}
