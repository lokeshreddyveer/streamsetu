import Foundation

/// Every `music.*` UserDefaults key in one list, sorted by what the app's reset, backup, sync and `MusicHub.wipeAll` do with it. A key that is
/// not listed here is not carried anywhere, so a new key has to be added to exactly one group (a test checks that the groups do not overlap).
enum MusicDefaultsKeys {
    /// Plain display preferences that can travel with a backup or to another device. Scalars only, each checked on the way in.
    static let portable: Set<String> = [
        "music.adaptiveAccent", "music.ambientLight", "music.lyrics.blur", "music.lyrics.textStep",
        "music.lyrics.translationLanguage", "music.zoom", "music.theme.palette", "music.theme.pickedColor",
    ]

    /// Preferences that belong to this device (or to an account on it) and go back to their defaults on "reset all preferences".
    static let deviceSettings: Set<String> = [
        "music.volume", "music.library.source", "music.library.likesPlacement", "music.library.playlistsPlacement",
        "music.lyrics.editor.tapOffsetMs", "music.lyrics.editor.tempo", "music.karaoke.settings", "music.pluginUpdates.weekly",
        "music.devices.allowControl", "music.ytmusic.useCipherRegistry", "music.pluginIndexURL", "music.shuffle.mode",
        "music.motionArtwork", "music.motionArtwork.cellular", "music.coverMotion", "music.catalogue.enabled",
        "music.ownInstances.piped", "music.ownInstances.invidious", "music.ownInstances.ownNetwork",
        "music.output.deviceUID", "music.output.deviceName",
        "music.subsonic.servers", "music.subsonic.transcode",
        // The shell: last section, sidebar choice, context panel per section, remembered scroll positions. Device-local.
        "music.shell.destination", "music.shell.sidebarExpanded", "music.shell.contextPanels", "music.shell.scroll", "music.shell.barHidden",
        // The side panel's width, the seek bar's time style, the Now Playing layout mode and the lyrics alignment.
        "music.shell.panelWidth", "music.player.showTotalTime", "music.nowPlaying.mode", "music.lyrics.alignment",
        "music.textstep", "music.playlistDescriptions", "music.playlistSort", "music.trackColumns", "music.home.region",
        // Library: the tab, view mode, sort and filters of each tab, as one JSON value.
        "music.library.view",
        // Home: the language chosen on the chip row and the languages the person added by hand. Device-local; the cached Home is a rebuildable file.
        "music.home.languageFilter", "music.home.languageByRegion", "music.home.languages",
        // Radio: the stations started lately (at most 20). Device-local.
        "music.radio.recentStations",
        // The connected-universe pages: on or off (on by default).
        "music.graph.pages",
    ]

    /// Which sources are on and in what order, and the scrobble setup. These are choices, not data: reset and wipe leave them, as wipe leaves sign-ins.
    static let sourceChoices: Set<String> = [
        "music.enabled", "music.activeMetadata", "music.audioOrder", "music.lyricsOrder", "music.scrobble.config", "music.enabledLog",
        "music.knownBuiltIns", "music.metadata.sources",
    ]

    /// What the person did: searches, reported plays, import results and check times. `MusicHub.wipeAll` removes these.
    static let activity: Set<String> = [
        "music.firstSeen.v1", "music.taste.resetAt", "music.hiddenRecommendations", "music.home.becauseRecent", "music.favoriteArtists", "music.album.prefs.v1", "music.taste.prefs", "music.setup.done", "music.setup.cardDismissed",
        "music.recentSearches", "music.ytm.history", "music.import.autoUpdate.outcomes", "music.import.budget", "music.pluginUpdates.lastCheck",
        "music.shell.searchQuery", "music.shell.session", "music.shell.searchState",
    ]

    static var all: Set<String> { portable.union(deviceSettings).union(sourceChoices).union(activity) }

    /// A backup or sync value as a typed default, or nil when it does not look right.
    static func typedValue(_ key: String, _ s: String) -> Any? {
        guard portable.contains(key) else { return nil }
        switch key {
        case "music.adaptiveAccent", "music.ambientLight", "music.lyrics.blur":
            return s == "true" || s == "1" ? true : (s == "false" || s == "0" ? false : nil)
        case "music.lyrics.textStep":
            return Int(s).flatMap { (0...4).contains($0) ? $0 : nil }
        case "music.zoom":
            return Double(s).flatMap { $0 >= 0.5 && $0 <= 2.5 ? $0 : nil }
        case "music.lyrics.translationLanguage":
            return s.count <= 8 && s.allSatisfy { $0.isLetter || $0 == "-" } ? s : nil
        case "music.theme.palette":
            return MusicPaletteChoice(rawValue: s)?.rawValue
        case "music.theme.pickedColor":
            return MusicOKLCH.rgb(hex: s) != nil ? s : nil
        default:
            return nil
        }
    }

    /// The portable values as text, for a backup.
    static func snapshot(_ d: UserDefaults) -> [String: String] {
        var out: [String: String] = [:]
        for key in portable {
            guard let v = d.object(forKey: key) else { continue }
            if let s = v as? String { out[key] = s } else if let b = v as? Bool { out[key] = b ? "true" : "false" } else if let n = v as? NSNumber { out[key] = n.stringValue }
        }
        return out
    }

    /// Back to defaults: the portable and device preferences. Sources, sign-ins and activity are left alone.
    static func resetPreferences(_ d: UserDefaults) {
        for key in portable.union(deviceSettings) { d.removeObject(forKey: key) }
    }

    /// Part of `MusicHub.wipeAll`: what the person did, gone.
    static func wipeActivity(_ d: UserDefaults) {
        for key in activity { d.removeObject(forKey: key) }
    }
}
