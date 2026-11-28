import Foundation

// One list of things Music can be told to do, and one door every outside caller goes through: global hotkeys, the command palette, schedules, triggers, links, Apple Shortcuts,
// the command line and the local control API. Each caller has its own permissions (what it may do), set by the person; nothing outside is allowed anything by default
// except what is listed below.

enum MusicAutomationScope: String, Codable, CaseIterable, Sendable, Hashable {
    /// Read what is playing.
    case read
    /// Play, pause, skip, volume, like, shuffle and repeat.
    case control
    /// Start the person's own collections (liked songs, a playlist).
    case library
    /// Go to a place in Music.
    case navigate
    var title: String {
        switch self {
        case .read: Localized.string("See what is playing")
        case .control: Localized.string("Play, pause, skip and change volume")
        case .library: Localized.string("Start my playlists and liked songs")
        case .navigate: Localized.string("Open pages in Music")
        }
    }
}

enum MusicAutomationSource: String, Codable, CaseIterable, Sendable, Hashable {
    case palette, hotkey, schedule, trigger, link, shortcuts, localAPI
    var title: String {
        switch self {
        case .palette: Localized.string("Command palette")
        case .hotkey: Localized.string("Keyboard shortcuts")
        case .schedule: Localized.string("Schedules and rules")
        case .trigger: Localized.string("Event triggers")
        case .link: Localized.string("Links (streamsetu://)")
        case .shortcuts: Localized.string("Apple Shortcuts")
        case .localAPI: Localized.string("Local control (command line and apps)")
        }
    }
    /// What each source may do until the person changes it. Things the person does themselves are fully allowed; things an outside program can do are limited.
    var defaultScopes: Set<MusicAutomationScope> {
        switch self {
        case .palette, .hotkey, .schedule, .trigger: Set(MusicAutomationScope.allCases)
        case .link: [.navigate]
        case .shortcuts: Set(MusicAutomationScope.allCases)
        case .localAPI: []          // off until the person turns it on
        }
    }
}

enum MusicCommandName: String, CaseIterable, Sendable, Hashable {
    case playPause, play, pause, next, previous, seekForward, seekBack, volumeUp, volumeDown, setVolume, like, shuffleOn, shuffleOff, repeatCycle, stopAfterSong
    case playLiked, playLikedShuffled, playPlaylist, sleepTimer, listeningMode
    case openListenNow, openExplore, openSearch, openLibrary, openRadio, openDownloads, openRecentlyAdded
    case nowPlaying

    var scope: MusicAutomationScope {
        switch self {
        case .nowPlaying: .read
        case .playLiked, .playLikedShuffled, .playPlaylist: .library
        case .openListenNow, .openExplore, .openSearch, .openLibrary, .openRadio, .openDownloads, .openRecentlyAdded: .navigate
        default: .control
        }
    }
    var title: String {
        switch self {
        case .playPause: Localized.string("Play or pause")
        case .play: Localized.string("Play")
        case .pause: Localized.string("Pause")
        case .next: Localized.string("Next song")
        case .previous: Localized.string("Previous song")
        case .seekForward: Localized.string("Skip forward")
        case .seekBack: Localized.string("Skip back")
        case .volumeUp: Localized.string("Volume up")
        case .volumeDown: Localized.string("Volume down")
        case .setVolume: Localized.string("Set volume")
        case .like: Localized.string("Like this song")
        case .shuffleOn: Localized.string("Shuffle on")
        case .shuffleOff: Localized.string("Shuffle off")
        case .repeatCycle: Localized.string("Change repeat")
        case .stopAfterSong: Localized.string("Stop after this song")
        case .playLiked: Localized.string("Play liked songs")
        case .playLikedShuffled: Localized.string("Shuffle liked songs")
        case .playPlaylist: Localized.string("Play a playlist")
        case .sleepTimer: Localized.string("Sleep timer")
        case .listeningMode: Localized.string("Listening mode")
        case .openListenNow: Localized.string("Open Listen Now")
        case .openExplore: Localized.string("Open Explore")
        case .openSearch: Localized.string("Open Search")
        case .openLibrary: Localized.string("Open Your Library")
        case .openRadio: Localized.string("Open Radio")
        case .openDownloads: Localized.string("Open Downloads")
        case .openRecentlyAdded: Localized.string("Open Recently Added")
        case .nowPlaying: Localized.string("What is playing")
        }
    }
    /// The commands that take a value (a percentage, a minute count, a playlist name).
    var takesArgument: Bool { [.setVolume, .playPlaylist, .sleepTimer, .listeningMode].contains(self) }
}

struct MusicCommandCall: Codable, Equatable, Hashable, Sendable {
    var name: String
    var argument: String? = nil
    var command: MusicCommandName? { MusicCommandName(rawValue: name) }
}

struct MusicAutomationResult: Sendable, Equatable {
    var ok: Bool
    var message: String
    var data: [String: String] = [:]
}

enum MusicAutomationPermissions {
    static let key = "music.automation.permissions"

    static func scopes(_ s: MusicAutomationSource, _ d: UserDefaults = .standard) -> Set<MusicAutomationScope> {
        guard let all = d.dictionary(forKey: key) as? [String: [String]], let list = all[s.rawValue] else { return s.defaultScopes }
        return Set(list.compactMap(MusicAutomationScope.init(rawValue:)))
    }
    static func set(_ scopes: Set<MusicAutomationScope>, for s: MusicAutomationSource, _ d: UserDefaults = .standard) {
        var all = (d.dictionary(forKey: key) as? [String: [String]]) ?? [:]
        all[s.rawValue] = scopes.map(\.rawValue).sorted()
        d.set(all, forKey: key)
    }
    static func allows(_ s: MusicAutomationSource, _ scope: MusicAutomationScope, _ d: UserDefaults = .standard) -> Bool { scopes(s, d).contains(scope) }
}

@MainActor
enum MusicAutomation {
    /// Every outside request ends here. Permission first, then the action.
    @discardableResult
    static func perform(_ call: MusicCommandCall, from source: MusicAutomationSource, hub: MusicHub = .shared) -> MusicAutomationResult {
        guard let cmd = call.command else { return .init(ok: false, message: Localized.string("Unknown command.")) }
        guard MusicAutomationPermissions.allows(source, cmd.scope) else {
            MusicDebugLog.log("automation", "refused \(cmd.rawValue) from \(source.rawValue)")
            return .init(ok: false, message: Localized.string("%@ is not allowed to do this. You can allow it in Settings, Automation.", source.title))
        }
        MusicDebugLog.log("automation", "\(cmd.rawValue) from \(source.rawValue)")
        let p = hub.player
        func ok(_ m: String = "") -> MusicAutomationResult { .init(ok: true, message: m) }
        switch cmd {
        case .playPause: p.toggle(); return ok()
        case .play: if !p.isPlaying { p.resume() }; return ok()
        case .pause: p.pause(); return ok()
        case .next: p.next(); return ok()
        case .previous: p.previous(); return ok()
        case .seekForward: p.skip(listeningSeconds: MusicSeekPrefs.forwardSeconds()); return ok()
        case .seekBack: p.skip(listeningSeconds: -MusicSeekPrefs.backSeconds()); return ok()
        case .volumeUp: p.volume = min(1, p.volume + 0.1); return ok()
        case .volumeDown: p.volume = max(0, p.volume - 0.1); return ok()
        case .setVolume:
            guard let v = call.argument.flatMap(Double.init), (0...100).contains(v) else { return .init(ok: false, message: Localized.string("Give a volume from 0 to 100.")) }
            p.volume = Float(v / 100); return ok()
        case .like: if let t = p.current, !hub.library.isLiked(t) { hub.library.toggleLike(t) }; return ok()
        case .shuffleOn: p.shuffle = true; return ok()
        case .shuffleOff: p.shuffle = false; return ok()
        case .repeatCycle: p.repeatMode = p.repeatMode == .off ? .all : (p.repeatMode == .all ? .one : .off); return ok()
        case .stopAfterSong: p.toggleStopAfterCurrent(); return ok()
        case .listeningMode:
            guard let m = call.argument.flatMap({ MusicListeningMode(rawValue: $0) }) else { return .init(ok: false, message: Localized.string("Unknown listening mode.")) }
            MusicListeningModes.shared.set(m, hub: hub); return ok(m.title)
        case .sleepTimer:
            guard let m = call.argument.flatMap(Int.init), (1...600).contains(m) else { return .init(ok: false, message: Localized.string("Give a number of minutes.")) }
            hub.sleepTimer.start(.minutes(m)); return ok()
        case .playLiked, .playLikedShuffled:
            let liked = hub.library.liked
            guard !liked.isEmpty else { return .init(ok: false, message: Localized.string("There are no liked songs yet.")) }
            if cmd == .playLikedShuffled { hub.playShuffled(liked, sourceName: Localized.string("Liked songs")) } else { hub.play(liked, at: 0, sourceName: Localized.string("Liked songs")) }   // through the hub: a paused profile and a Listen Together guest are refused there
            return ok()
        case .playPlaylist:
            let q = MusicText.normalize(call.argument ?? "")
            guard !q.isEmpty, let list = hub.library.playlists.first(where: { $0.id.uuidString == call.argument || MusicText.normalize($0.name) == q }) ?? hub.library.playlists.first(where: { MusicText.normalize($0.name).contains(q) }), !list.tracks.isEmpty else {
                return .init(ok: false, message: Localized.string("That playlist was not found or is empty."))
            }
            hub.play(list.tracks, at: 0, sourceName: list.name); return ok(list.name)
        case .openListenNow: hub.nav.select(.home); return ok()
        case .openExplore: hub.nav.select(.explore); return ok()
        case .openSearch: hub.nav.select(.search); return ok()
        case .openLibrary: hub.openLibrary(); return ok()
        case .openRadio: hub.nav.select(.radio); return ok()
        case .openDownloads: hub.nav.select(.downloads); return ok()
        case .openRecentlyAdded: hub.nav.select(.recentlyAdded); return ok()
        case .nowPlaying:
            var d: [String: String] = ["playing": p.isPlaying ? "true" : "false", "volume": String(Int((p.volume * 100).rounded()))]
            if let t = p.current { d["title"] = t.title; d["artist"] = t.artistLine; d["album"] = t.album?.title ?? ""; d["position"] = String(Int(p.position)); d["duration"] = String(Int(p.duration)) }
            return .init(ok: true, message: p.current.map { "\($0.title) · \($0.artistLine)" } ?? Localized.string("Nothing is playing."), data: d)
        }
    }

    /// `streamsetu://music/do/<command>?arg=…`: a link that does something. It is checked against the Links permission, which allows only opening pages until the person says more.
    static func handle(_ url: URL, hub: MusicHub = .shared) -> Bool {
        guard url.scheme?.lowercased() == "streamsetu", url.host?.lowercased() == "music" else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == "do" else { return false }
        let arg = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "arg" }?.value
        perform(MusicCommandCall(name: parts[1], argument: arg.map { String($0.prefix(200)) }), from: .link, hub: hub)
        return true
    }
}
