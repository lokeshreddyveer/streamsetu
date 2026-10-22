import Foundation

/// One line of the coverage matrix: a feature, route, modal, settings key, context menu, tool or action, and what the assistant can do with it. An entry may say plainly that something is
/// unsupported, with the reason. What may not happen is that something exists in the code and has no entry: the coverage tests read the code and fail on that.
struct AssistantCoverageRow: Equatable {
    var area: String
    var key: String
    /// Whether the app itself has a control for it.
    var ui: String
    /// How the assistant can read it ("" when it cannot).
    var read: String
    /// What the assistant can do with it ("" when nothing).
    var act: String
    /// How the authorization rules apply, and whether a test covers them.
    var restrictions: String
    var errorPath: String
    var platforms: String
    /// Set when it is not supported, with the reason.
    var unsupported: String?
    var isCovered: Bool { unsupported == nil }
}

@MainActor enum AssistantCoverage {
    // MARK: how each kind of thing is described

    private static let mac = "macOS · iOS compiled, not run"
    private static let macOnly = "macOS"

    private static func covered(_ area: String, _ key: String, ui: String = "yes", read: String, act: String, restrictions: String = "n/a (read only)", error: String = "n/a", platforms: String = mac) -> AssistantCoverageRow {
        .init(area: area, key: key, ui: ui, read: read, act: act, restrictions: restrictions, errorPath: error, platforms: platforms, unsupported: nil)
    }
    private static func unsupported(_ area: String, _ key: String, ui: String = "yes", _ reason: String, platforms: String = macOnly) -> AssistantCoverageRow {
        .init(area: area, key: key, ui: ui, read: "", act: "", restrictions: "n/a", errorPath: "n/a", platforms: platforms, unsupported: reason)
    }

    // MARK: settings keys (every stored property of AppSettings)

    /// A stored preference is explained or changed through the typed catalogue; this says which entry stands for it, or why none does.
    static let settingKeys: [String: String?] = [
        // these have an entry of the same name in AppSettingsCatalog
        "theme": nil, "accent": nil, "density": nil, "reduceMotion": nil, "highContrast": nil, "sidebarLaunch": nil, "clickBehavior": nil, "collapseDuplicates": nil, "hideEmptyFolders": nil,
        "defaultLibrarySort": nil, "defaultChannelSort": nil, "rememberFolders": nil, "remindersEnabled": nil, "refreshOnOpen": nil, "language": nil, "liveRewind": nil, "autoBackup": nil, "lanSync": nil,
        "appLock": nil, "resumeLastChannel": nil, "enginePreference": nil, "hardwareDecoding": nil, "deinterlace": nil, "videoQuality": nil, "bufferingMode": nil, "preferredAudioLanguage": nil,
        "audioProcessing": nil, "preferredSubtitleLanguage": nil, "subtitlesByDefault": nil, "autoSubtitles": nil, "subtitleSize": nil, "subtitleBackground": nil, "subtitleColor": nil,
        "autoPlayNextEpisode": nil, "rememberPosition": nil, "resumeAutomatically": nil, "bestVersionFirst": nil, "showDiagnosticsOverlay": nil, "renderingProfile": nil, "toneMapping": nil,
        "stereoDownmix": nil, "subtitleOutline": nil, "catalogRefresh": nil, "guideRefresh": nil, "subtitlePosition": nil, "guideRetentionDays": nil, "guideHoursVisible": nil,
        // explained under another entry (and not changeable by the assistant)
        "iCloudSync": "icloudSync", "syncLogins": "icloudSync", "vpnPause": "vpn", "proxyKind": "proxy", "proxyHost": "proxy", "proxyPort": "proxy",
    ]

    /// Stored properties that are not an entry of the catalogue, and why.
    static let settingKeysNotOffered: [String: String] = [
        "customTheme": "A colour set made in the theme editor. The assistant can pick a named theme but not edit custom colours.",
        "sidebarWasCollapsed": "State the sidebar records for itself, not a preference anyone sets.",
        "lastAutoBackup": "A timestamp the backup writes, not a preference.",
        "lastChannelID": "A record of the last channel played, not a preference.",
        "volume": "Player volume is a session control: the assistant offers volume up, down and mute through player.control, not a stored setting.",
        "picture": "Brightness, contrast, saturation, gamma and hue are adjusted from the player's picture button, per stream.",
        "audioOutputUID": "Needs the list of this Mac's output devices, which the assistant cannot read yet. macOS only.",
    ]

    // MARK: screens, routes and modals

    static let tabs: [String: (read: String, act: String)] = [
        "home": ("screen name in context", "open_screen"), "liveTV": ("screen name in context; channels via search_everything, tv_guide", "open_screen, play_title"),
        "movies": ("screen name; titles via search_library, title_details", "open_screen with filter words, play_title"), "series": ("screen name; titles via search_everything, title_details, similar_titles", "open_screen with filter words, play_title"),
        "guide": ("screen name; programmes via tv_guide, guide_status", "open_screen, sync_guide"),
    ]

    /// Sidebar shortcuts. Those without an own destination in `open_screen` say how they are reached.
    static let shortcuts: [String: (read: String, act: String)?] = [
        "tonight": ("screen name", "open_screen(tonight)"), "discover": ("screen name", "open_screen(discover)"), "continueWatching": ("screen name", "open_screen(continueWatching), resume_watching"),
        "recentlyWatched": ("screen name", "open_screen(recentlyWatched)"), "watchHistory": ("screen name; viewing totals via watch_stats", "open_screen(history)"),
        "favorites": ("screen name", "open_screen(favorites), favourite"), "watchLater": ("screen name", "open_screen(watchLater), watch_later"), "collections": ("screen name", "open_screen(collections)"),
        "statistics": ("screen name; totals via watch_stats", "open_screen(statistics)"),
        "featured": nil, "allMovies": ("screen name", "open_screen(movies)"), "recentlyAdded": nil, "library": ("screen name", "open_screen(series)"), "allChannels": ("screen name", "open_screen(liveTV)"),
        "unwatched": ("screen name", "open_screen(movies, filter: unwatched)"), "unwatchedFavorites": nil, "addedThisMonth": nil, "newEpisodes": nil,
    ]
    static let shortcutsNotOffered: [String: String] = [
        "featured": "No destination in open_screen yet.", "recentlyAdded": "Reachable by typing 'newest' as a Movies/Series filter, but not as its own destination.",
        "unwatchedFavorites": "No destination in open_screen yet.", "addedThisMonth": "No destination in open_screen yet.", "newEpisodes": "No destination in open_screen yet.",
    ]

    static let modals: [String: AssistantCoverageRow] = [
        "playlists": covered("modal", "playlists", read: "sanitized status via source_health", act: "refresh_playlists (offered), open_screen(settings)", restrictions: "yes: AssistantAuthorizer (profile, freshness)", error: "yes: source_health failures"),
        "addPlaylist": covered("modal", "addPlaylist", read: "how-to via source_setup_help; never reads or stores credentials", act: "explains the fields only", restrictions: "n/a (credentials go through the normal form into the Keychain)", error: "no"),
        "about": unsupported("modal", "about", "Nothing for the assistant to read or do."),
        "channelManager": unsupported("modal", "channelManager", "Channel and folder management is not mapped to the registry yet (planned: read-only inspection first, then previewed changes)."),
        "unlockRestricted": unsupported("modal", "unlockRestricted", "By design: PINs are entered only in the normal secure form; the assistant never unlocks anything."),
    ]

    static let settingsTabs: [String: String] = [
        "general": "General", "appearance": "Appearance", "playback": "Playback", "library": "Library", "privacy": "Privacy (explain only: lock, proxy, VPN, parental)", "advanced": "Advanced (explain only: diagnostics, reset)",
    ]

    /// The feature folders of the app, and what the assistant can do for each.
    static let features: [String: AssistantCoverageRow] = [
        "Collections": unsupported("feature", "Collections", ui: "yes", "Not mapped yet: no read or create/add tools (planned: read, then previewed changes)."),
        "CommandCenter": unsupported("feature", "CommandCenter", "Channel Manager, folders and sidebar management are not mapped yet (planned)."),
        "ContinueWatching": covered("feature", "ContinueWatching", read: "context screen name", act: "resume_watching", restrictions: "yes: AssistantAuthorizer", error: "yes: nothing to resume"),
        "Favorites": covered("feature", "Favorites", read: "context screen name", act: "favourite (add/remove)", restrictions: "yes: AssistantAuthorizer (profile, locked folders)", error: "yes: title not in library"),
        "Files": unsupported("feature", "Files", "Local files, podcasts and 'On Your Device' are not mapped yet."),
        "Home": covered("feature", "Home", read: "screen name, search text", act: "open_screen, search_everything", restrictions: "n/a", error: "yes"),
        "LiveTV": covered("feature", "LiveTV", read: "search_everything, tv_guide, now_playing", act: "play_title, open_screen", restrictions: "yes: AssistantAuthorizer", error: "yes"),
        "Movies": covered("feature", "Movies", read: "search_library, title_details, similar_titles", act: "play_title, favourite, watch_later, open_screen with filters", restrictions: "yes: AssistantAuthorizer", error: "yes"),
        "Onboarding": unsupported("feature", "Onboarding", ui: "yes", "First-run screens; the assistant is not shown there."),
        "Player": covered("feature", "Player", read: "diagnose_playback, now_playing, recommend_engine", act: "control_playback, retry_playback, switch_engine, select_track", restrictions: "yes: AssistantAuthorizer (session, profile)", error: "yes: diagnosis table"),
        "RecentlyWatched": unsupported("feature", "RecentlyWatched", "History is summarised by watch_stats but not searchable or editable by the assistant yet."),
        "Search": covered("feature", "Search", read: "search_everything (same engine as the search box)", act: "open_screen with filter words", restrictions: "n/a", error: "yes"),
        "Series": covered("feature", "Series", read: "search_everything, title_details, similar_titles", act: "play_title, favourite, watch_later", restrictions: "yes: AssistantAuthorizer", error: "yes"),
        "Settings": covered("feature", "Settings", read: "find_setting, find_help", act: "change_setting (catalogued settings only)", restrictions: "yes: AssistantAuthorizer", error: "yes: invalid and unchangeable settings"),
        "Shared": unsupported("feature", "Shared", ui: "n/a", "Shared building blocks, not a feature."),
        "Sources": covered("feature", "Sources", read: "source_health, guide_status, source_setup_help", act: "refresh_playlists (offered)", restrictions: "yes: AssistantAuthorizer; credentials never read", error: "yes"),
        "TVGuide": covered("feature", "TVGuide", read: "tv_guide, guide_status", act: "sync_guide (offered)", restrictions: "yes: AssistantAuthorizer", error: "yes"),
    ]

    /// Files that contain a context menu. None are mapped to the registry yet.
    static let contextMenus: [String: String] = [
        "DesignSystem/Components/Sidebar/ReddySidebar.swift": "Sidebar folder menu (lock, hide, rename): not mapped yet.",
        "Features/CommandCenter/Views/CommandCenterView.swift": "Channel and folder manager menus: not mapped yet.",
        "Features/Files/FilesView.swift": "Local file menu: not mapped yet.",
        "Features/Files/PodcastsView.swift": "Podcast menu: not mapped yet.",
        "Features/Home/Views/HomeScreen.swift": "Title card menu (favourite, watch later, hide): reachable as the favourite and watch_later tools, not as its own entry.",
        "Features/LiveTV/Views/LiveTVScreen.swift": "Channel menu (favourite, reminders, versions): partly reachable as favourite and play_title.",
        "Features/Movies/Views/LibraryScreen.swift": "Title menu: partly reachable as favourite, watch_later and play_title.",
        "Features/Player/Views/MultiViewWindow.swift": "Multi-view tile menu: not mapped yet.",
        "Features/Series/Views/SeriesDetailView.swift": "Episode menu (mark watched): not mapped yet.",
        "Features/TVGuide/Components/GuideRow.swift": "Programme menu (remind, record): not mapped yet.",
    ]

    // MARK: tools

    /// Every tool the assistant has, and how it is governed. Tools that only look say so; those that offer actions go through the authorizer when tapped.
    static let tools: [String: String] = [
        "search_everything": "read", "search_library": "read", "check_library": "read", "title_details": "read", "similar_titles": "read", "tv_guide": "read", "now_playing": "read",
        "diagnose_playback": "read", "source_health": "read (sends no login)", "guide_status": "read", "recommend_engine": "read", "source_setup_help": "read", "find_setting": "read", "find_help": "read",
        "web_lookup": "read (sends only the topic to Wikipedia)", "watch_stats": "read",
        "change_setting": "offers; authorizer rechecks", "control_playback": "offers; authorizer rechecks", "open_screen": "offers; authorizer rechecks", "play_title": "offers; authorizer rechecks",
        "favourite": "offers; authorizer rechecks", "watch_later": "offers; authorizer rechecks", "resume_watching": "offers; authorizer rechecks", "refresh_playlists": "offers; authorizer rechecks",
        "retry_playback": "offers; authorizer rechecks", "switch_engine": "offers; authorizer rechecks", "select_track": "offers; authorizer rechecks", "sync_guide": "offers; authorizer rechecks",
        "problem_report": "offers; authorizer rechecks",
    ]

    /// One example of every action kind, so each can be described by the registry.
    static func sampleKinds() -> [AssistantProposal.Kind] {
        [.command(.init(kind: .go(.discover, library: nil))), .command(.init(kind: .play("x"))), .command(.init(kind: .resume)), .command(.init(kind: .lastChannel)),
         .command(.init(kind: .favourite("x", on: true))), .command(.init(kind: .watchLater("x", on: true))), .setting(id: "theme", value: "x"), .playback("pause"), .refresh, .retry,
         .engine("mpv"), .track(audio: true, id: nil, label: ""), .syncGuide, .copyReport(""),
         .playItem(id: "x", isChannel: false, title: "x"), .toggleList(id: "x", kind: .movie, watchLater: false, on: true, title: "x")]
    }

    // MARK: the matrix

    static func rows() -> [AssistantCoverageRow] {
        var out: [AssistantCoverageRow] = []
        for (key, entry) in settingKeys.sorted(by: { $0.key < $1.key }) {
            let id = entry ?? key
            if let e = AppSettingsCatalog.find(id) {
                if e.changeable { out.append(covered("setting", key, read: "find_setting (value, options, where)", act: "change_setting", restrictions: "yes: AssistantAuthorizer + value check", error: "yes: invalid value, unchangeable", platforms: platformNote(key))) }
                else { out.append(covered("setting", key, read: "find_setting (explains it)", act: "none by design (security, accounts, sync or network)", restrictions: "yes: refused", error: "yes")) }
            }
        }
        for (key, why) in settingKeysNotOffered.sorted(by: { $0.key < $1.key }) { out.append(unsupported("setting", key, why, platforms: platformNote(key))) }
        for (key, v) in tabs.sorted(by: { $0.key < $1.key }) { out.append(covered("tab", key, read: v.read, act: v.act, restrictions: "yes: AssistantAuthorizer", error: "n/a")) }
        for (key, v) in shortcuts.sorted(by: { $0.key < $1.key }) {
            if let v { out.append(covered("sidebar shortcut", key, read: v.read, act: v.act, restrictions: "yes: AssistantAuthorizer", error: "n/a")) }
            else { out.append(unsupported("sidebar shortcut", key, shortcutsNotOffered[key] ?? "Not mapped.")) }
        }
        out += modals.sorted(by: { $0.key < $1.key }).map(\.value)
        for (key, label) in settingsTabs.sorted(by: { $0.key < $1.key }) { out.append(covered("settings tab", key, read: "find_setting covers: " + label, act: label.contains("explain only") ? "none by design" : "change_setting for catalogued settings", restrictions: "yes: AssistantAuthorizer", error: "yes")) }
        out += features.sorted(by: { $0.key < $1.key }).map(\.value)
        for (file, note) in contextMenus.sorted(by: { $0.key < $1.key }) { out.append(unsupported("context menu", file, ui: "yes", note)) }
        for (name, how) in tools.sorted(by: { $0.key < $1.key }) { out.append(covered("agent tool", name, ui: "n/a", read: how.hasPrefix("read") ? how : "", act: how.hasPrefix("offers") ? how : "", restrictions: how.hasPrefix("offers") ? "yes: tested" : "n/a (read only)", error: "yes")) }
        for k in sampleKinds() {
            let s = AssistantActions.spec(for: k)
            out.append(covered("agent action", s.id, ui: "same service: " + s.service, read: "", act: "\(s.permission.rawValue), scope \(s.scope.rawValue), inputs: " + (s.inputs.isEmpty ? "none" : s.inputs.joined(separator: ", ")) + (s.confirmation == nil ? ", no confirmation" : ", preview + confirm"),
                                restrictions: "yes: AssistantAuthorizer tests", error: "yes: stale, profile, locked folder", platforms: s.platforms.map(\.rawValue).sorted().joined(separator: ", ")))
        }
        return out
    }

    private static func platformNote(_ key: String) -> String {
        ["subtitleOutline": "macOS · needs MPV", "subtitlePosition": "macOS · needs MPV (not shown by the Apple engine)", "toneMapping": "macOS · needs MPV", "deinterlace": "macOS · needs MPV", "audioProcessing": "macOS · needs MPV", "stereoDownmix": "macOS · needs MPV",
         "renderingProfile": "macOS · needs MPV", "liveRewind": "macOS · needs MPV", "audioOutputUID": "macOS", "appLock": "macOS · Touch ID or password"][key] ?? mac
    }

    /// The matrix as a table, with what each column means and what has and has not been verified.
    static func markdown(generated: Date = Date()) -> String {
        let r = rows()
        var t = "# Assistant coverage matrix\n\nGenerated from the code by the coverage tests. **Reported, pending independent verification.** Verification means automated tests on macOS only: iPhone/iPad code compiles but is not run, and Android and Fire TV have none of this.\n\n"
        t += "Columns: *UI* = the app has its own control · *Read* = how the assistant looks at it · *Act* = what it can offer (always tap-to-confirm, rechecked by the authorizer) · *Restrictions tested* · *Error path tested* · *Platforms verified*.\n\n"
        let covered = r.filter(\.isCovered).count
        t += "**\(r.count) rows: \(covered) covered, \(r.count - covered) unsupported with a reason.**\n\n"
        var area = ""
        for row in r.sorted(by: { ($0.area, $0.key) < ($1.area, $1.key) }) {
            if row.area != area { area = row.area; t += "\n## \(area)\n\n| Feature | UI wired | Agent read | Agent action | Restrictions tested | Error path tested | Platforms verified |\n|---|---|---|---|---|---|---|\n" }
            if let u = row.unsupported { t += "| \(row.key) | \(row.ui) | — | — | — | — | **Unsupported:** \(u) |\n" }
            else { t += "| \(row.key) | \(row.ui) | \(row.read.isEmpty ? "—" : row.read) | \(row.act.isEmpty ? "—" : row.act) | \(row.restrictions) | \(row.errorPath) | \(row.platforms) |\n" }
        }
        return t
    }
}
