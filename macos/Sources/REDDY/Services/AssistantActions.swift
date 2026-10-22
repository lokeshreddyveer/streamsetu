import Foundation

// MARK: - what kind of action it is

/// How much care an action needs. The policy is applied in one place (`AssistantAuthorizer`), not per button.
enum AssistantPermission: String, Sendable {
    /// Looks at something. Never changes anything.
    case read
    /// Controls what is playing or where the person is; reversible and clearly asked for.
    case control
    /// Changes a stored preference; reversible, and only for a setting in the typed catalogue.
    case preference
    /// Changes the library (favourites, lists) for the active profile.
    case libraryChange
    /// Changes many things, removes something, resets or restores. Always previewed and confirmed.
    case bulkOrDestructive
    /// Changes where data goes (cloud, sharing). Needs the person's explicit authorization in the normal settings.
    case dataDestination
}

enum AssistantScope: String, Sendable { case session, profile, device }

enum AssistantPlatform: String, Sendable, CaseIterable { case macOS, iOS, android, fireTV }

/// The description of one action the assistant can offer: the same description whatever screen it is offered from.
struct AssistantActionSpec: Sendable {
    let id: String
    let title: String
    let scope: AssistantScope
    let permission: AssistantPermission
    /// Typed inputs, as "name: type".
    let inputs: [String]
    /// The service the screen's own button calls too, so the agent and the UI cannot drift apart.
    let service: String
    /// When non-nil the action is only run after the person has seen this preview and confirmed it.
    let confirmation: String?
    /// Where the action exists. Nothing is assumed: other platforms are listed only once they are built and checked.
    let platforms: Set<AssistantPlatform>
    /// Whether the action concerns what is playing right now (and so is cancelled if that changes).
    let needsPlayback: Bool
}

/// Every action kind has a spec: the compiler insists, because the switch is exhaustive.
@MainActor enum AssistantActions {
    static func spec(for kind: AssistantProposal.Kind) -> AssistantActionSpec {
        switch kind {
        case .command(let c):
            switch c.kind {
            case .go: return .init(id: "navigation.open", title: "Open a screen", scope: .session, permission: .control, inputs: ["target: screen", "filter: text?"], service: "AppRouter.navigate / SearchCommandRunner", confirmation: nil, platforms: [.macOS, .iOS], needsPlayback: false)
            case .play: return .init(id: "library.play", title: "Play a title or channel", scope: .session, permission: .control, inputs: ["title: library item"], service: "PlayActions / PlaybackCoordinator.play", confirmation: nil, platforms: [.macOS, .iOS], needsPlayback: false)
            case .resume: return .init(id: "library.resume", title: "Resume watching", scope: .profile, permission: .control, inputs: [], service: "HistoryRepository.continueWatching + PlaybackCoordinator.play", confirmation: nil, platforms: [.macOS, .iOS], needsPlayback: false)
            case .lastChannel: return .init(id: "live.lastChannel", title: "Play the last channel", scope: .profile, permission: .control, inputs: [], service: "AppSettings.lastChannelID + PlaybackCoordinator.play", confirmation: nil, platforms: [.macOS, .iOS], needsPlayback: false)
            case .favourite: return .init(id: "library.favourite", title: "Add or remove a favourite", scope: .profile, permission: .libraryChange, inputs: ["title: library item", "on: bool"], service: "AppState.toggleFavorite", confirmation: nil, platforms: [.macOS, .iOS], needsPlayback: false)
            case .watchLater: return .init(id: "library.watchLater", title: "Add or remove from Watch Later", scope: .profile, permission: .libraryChange, inputs: ["title: library item", "on: bool"], service: "AppState.toggleWatchLater", confirmation: nil, platforms: [.macOS, .iOS], needsPlayback: false)
            }
        case .setting: return .init(id: "settings.change", title: "Change a setting", scope: .profile, permission: .preference, inputs: ["id: catalogue setting", "value: allowed option"], service: "AppSettings (same properties the Settings screens bind to)", confirmation: nil, platforms: [.macOS, .iOS], needsPlayback: false)
        case .playback: return .init(id: "player.control", title: "Control playback", scope: .session, permission: .control, inputs: ["action: pause|play|mute|unmute|volume_up|volume_down|forward|back|next_episode|stop"], service: "PlaybackCoordinator", confirmation: nil, platforms: [.macOS, .iOS], needsPlayback: true)
        case .refresh: return .init(id: "playlists.refresh", title: "Refresh playlists", scope: .device, permission: .control, inputs: [], service: "AppState.syncAll", confirmation: nil, platforms: [.macOS, .iOS], needsPlayback: false)
        case .retry: return .init(id: "player.retry", title: "Try the stream again", scope: .session, permission: .control, inputs: [], service: "PlaybackCoordinator.retryNow", confirmation: nil, platforms: [.macOS, .iOS], needsPlayback: true)
        case .engine: return .init(id: "player.engine", title: "Switch the player engine", scope: .session, permission: .control, inputs: ["engine: mpv|avPlayer|auto"], service: "PlaybackCoordinator.switchEngine / AppSettings.enginePreference", confirmation: nil, platforms: [.macOS, .iOS], needsPlayback: true)
        case .track: return .init(id: "player.track", title: "Choose an audio or subtitle track", scope: .session, permission: .control, inputs: ["kind: audio|subtitle", "track: available track"], service: "PlaybackCoordinator.selectAudio / selectSubtitle", confirmation: nil, platforms: [.macOS, .iOS], needsPlayback: true)
        case .syncGuide: return .init(id: "guide.sync", title: "Refresh the TV guide", scope: .device, permission: .control, inputs: [], service: "AppState.syncAll", confirmation: nil, platforms: [.macOS, .iOS], needsPlayback: false)
        case .playItem: return .init(id: "library.play", title: "Play a title or channel", scope: .session, permission: .control, inputs: ["id: library item or channel"], service: "PlayActions / PlaybackCoordinator.play", confirmation: nil, platforms: [.macOS, .iOS], needsPlayback: false)
        case .toggleList(_, _, let later, _, _): return later
            ? .init(id: "library.watchLater", title: "Add or remove from Watch Later", scope: .profile, permission: .libraryChange, inputs: ["id: library item", "on: bool"], service: "AppState.toggleWatchLater", confirmation: nil, platforms: [.macOS, .iOS], needsPlayback: false)
            : .init(id: "library.favourite", title: "Add or remove a favourite", scope: .profile, permission: .libraryChange, inputs: ["id: library item", "on: bool"], service: "AppState.toggleFavorite", confirmation: nil, platforms: [.macOS, .iOS], needsPlayback: false)
        case .copyReport: return .init(id: "diagnostics.copyReport", title: "Copy a redacted problem report", scope: .device, permission: .read, inputs: [], service: "DiagnosticsService.report (secrets removed)", confirmation: nil, platforms: [.macOS, .iOS], needsPlayback: false)
        }
    }
}

// MARK: - what actually happened

/// The result of carrying out a suggestion. A tick is shown only for `.done`; anything else shows what really went wrong.
enum AssistantOutcome: Equatable {
    /// It worked, with a sentence to say when there is something worth saying.
    case done(String?)
    case failed(String)
    var isDone: Bool { if case .done = self { true } else { false } }
    var message: String? { switch self { case .done(let m): m; case .failed(let m): m } }
}

/// Waits to see whether a stream that was just asked for really starts. Success is "playing", not "asked": a stream that fails reports why, and one that has not started in time is said to be still starting.
@MainActor enum AssistantPlaybackWatch {
    /// How long to wait for a stream to start before saying plainly that it has not.
    static var timeout: TimeInterval = 20

    /// What the watcher looks at. The player supplies it; a test can supply a scripted one.
    struct Probe {
        var current: () -> String??           // nil: nothing requested; .some(key): the item now loaded
        var state: () -> PlaybackState
        var lastError: () -> (error: PlaybackError, at: Date)?
        var pause: UInt64 = 100_000_000
        init(current: @escaping () -> String??, state: @escaping () -> PlaybackState, lastError: @escaping () -> (error: PlaybackError, at: Date)? = { nil }, pause: UInt64 = 100_000_000) { self.current = current; self.state = state; self.lastError = lastError; self.pause = pause }
        @MainActor init(_ p: PlaybackCoordinator) {
            self.init(current: { p.current.map { Optional($0.itemID) } }, state: { p.state }, lastError: { p.lastError.flatMap { e in p.lastErrorAt.map { (e, $0) } } })
        }
    }

    static func started(_ p: PlaybackCoordinator, expecting itemKey: String?, timeout: TimeInterval? = nil) async -> AssistantOutcome {
        await started(probe: Probe(p), expecting: itemKey, timeout: timeout)
    }

    static func started(probe: Probe, expecting itemKey: String?, timeout: TimeInterval? = nil) async -> AssistantOutcome {
        let limit = timeout ?? Self.timeout
        let deadline = Date().addingTimeInterval(limit)
        var sawRequest = false
        while Date() < deadline {
            if let cur = probe.current(), itemKey == nil || cur == itemKey { sawRequest = true }
            if sawRequest {
                switch probe.state() {
                case .playing: return .done(nil)
                case .failed(let e): return .failed(e.message + " " + e.advice)
                default: break
                }
            }
            try? await Task.sleep(nanoseconds: probe.pause)
        }
        if let e = probe.lastError(), Date().timeIntervalSince(e.at) < limit + 2, probe.state() != .playing { return .failed(e.error.message + " " + e.error.advice) }
        if !sawRequest { return .failed("It did not start: that title or channel could not be opened.") }
        return .failed("It has not started playing after \(Int(limit)) seconds (the player is \(Self.describe(probe.state()))), so I can’t say it worked. You can wait a little longer or try another.")
    }

    static func describe(_ s: PlaybackState) -> String {
        switch s {
        case .idle: "idle"; case .resolving: "finding the stream"; case .preparing: "preparing"; case .buffering: "buffering"; case .playing: "playing"; case .paused: "paused"
        case .seeking: "seeking"; case .ended: "finished"; case .recovering: "reconnecting"; case .failed: "stopped with an error"
        }
    }
}

// MARK: - the one place that decides

enum AssistantDecision: Equatable {
    case allow
    /// Show this preview and ask again before doing it.
    case confirm(preview: String)
    case deny(String)
}

/// What is true right now, gathered when a button is tapped. The decision below depends on nothing else, so it can be tested without a real profile, PIN or player.
struct AssistantSituation {
    var activeProfileID: String
    var isKids: Bool
    /// Locked folders are hidden at this moment.
    var restricting: Bool
    var isLocked: (String) -> Bool
    var hasPlayback: Bool
    var playbackKey: String?
    var itemExists: (String) -> Bool
    var mpvAvailable: Bool
    var now = Date()
}

/// Rechecked when a button is tapped, not when it was offered: who is using the app, what they may see, what is playing, and whether the target still exists and is allowed.
/// A model's answer, a playlist's text, a guide description or a subtitle can never grant anything here.
@MainActor enum AssistantAuthorizer {
    /// Suggestions older than this are not run: the situation they were made for has probably changed.
    static let lifetime: TimeInterval = 15 * 60
    /// A seam for tests of the preview-and-confirm path, since no current action needs one.
    static var extraConfirmation: ((AssistantProposal.Kind) -> String?)?

    /// Gathers the situation from the real profile, parental and player state. Taking them as arguments lets a test use real ones on storage of its own.
    static func situation(profiles: ProfileService, parental: ParentalControls, playback: PlaybackCoordinator, catalog: SQLiteCatalogRepository) -> AssistantSituation {
        AssistantSituation(activeProfileID: profiles.activeID, isKids: parental.kidsMode || profiles.active.kind == .kids, restricting: parental.isRestricting, isLocked: { parental.isLocked($0) },
                           hasPlayback: playback.current != nil, playbackKey: playback.current?.itemID,
                           itemExists: { id in ((try? catalog.movie(id: id)) ?? nil) != nil || ((try? catalog.seriesItem(id: id)) ?? nil) != nil || ((try? catalog.channel(id: id)) ?? nil) != nil },
                           mpvAvailable: playback.availableEngines.contains(.mpv))
    }

    static func situation(_ c: AppContainer) -> AssistantSituation { situation(profiles: c.profiles, parental: c.parental, playback: c.playback, catalog: c.catalog) }

    static func check(_ p: AssistantProposal, container c: AppContainer) -> AssistantDecision { decide(p, situation(c)) }

    /// Whether a folder's contents may be used right now, from the live parental state.
    static func accessAllowed(categoryID: String?, restricting: Bool, isLocked: (String) -> Bool) -> Bool {
        guard let categoryID else { return true }
        return !(restricting && isLocked(categoryID))
    }

    static func decide(_ p: AssistantProposal, _ s: AssistantSituation) -> AssistantDecision {
        let spec = AssistantActions.spec(for: p.kind)
        // 1. Who is using the app. A kids profile never gets the assistant, and a profile switch cancels what was offered to the previous one.
        if s.isKids { return .deny("The assistant is not available in a kids profile.") }
        if p.origin.profileID != s.activeProfileID { return .deny("The profile changed since this was suggested, so I cancelled it. Ask again.") }
        // 2. Still fresh.
        if s.now.timeIntervalSince(p.origin.createdAt) > lifetime { return .deny("That suggestion is out of date. Ask again and I will check the current situation.") }
        // 3. What was playing is still playing.
        if spec.needsPlayback {
            guard s.hasPlayback else { return .deny("Nothing is playing now.") }
            if let key = p.origin.playbackKey, key != s.playbackKey { return .deny("What was playing has changed since this was suggested.") }
        }
        // 4. The target is still there, and still allowed under the parental restrictions in force now.
        if let cat = p.origin.categoryID, s.restricting, s.isLocked(cat) { return .deny("That title is in a locked folder. Unlock restricted content first.") }
        if let id = p.origin.targetItemID, !s.itemExists(id) { return .deny("That title is no longer in your library.") }
        // 5. Settings: the entry must still be changeable, and the value allowed.
        if case .setting(let id, let value) = p.kind {
            guard let e = AppSettingsCatalog.find(id), e.changeable else { return .deny("That setting cannot be changed from here.") }
            guard e.accepts(value) else { return .deny("That value is not allowed for \(e.title).") }
        }
        if case .engine(let key) = p.kind, key == "mpv", !s.mpvAvailable { return .deny("MPV is not available on this device.") }
        // 6. Anything that removes or changes many things shows a preview first.
        if let preview = spec.confirmation ?? extraConfirmation?(p.kind), !p.confirmed { return .confirm(preview: preview) }
        return .allow
    }
}
