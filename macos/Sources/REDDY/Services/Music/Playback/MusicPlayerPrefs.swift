import Foundation

/// The person's player preferences, stored inside `MusicSettings.player`. Every field decodes with a default, so a settings file written
/// before a field existed loads cleanly.
struct MusicPlayerPrefs: Codable, Equatable, Sendable {
    /// Adds move instead of duplicating: every other copy of a song is removed first.
    var preventDuplicates = false
    /// A shuffled queue keeps the playing album or playlist in order unless this is on: then shuffle carries over to a new queue.
    var stickyShuffle = false
    /// Shuffle also mixes the "Add to queue" rows into the playlist.
    var shuffleWholeQueue = true
    /// Start the restored queue when the app opens.
    var playOnStart = false
    /// The last crossfade length the person chose, so switching crossfade back on restores it (1 to 10 whole seconds).
    var crossfadeLength = 5
    /// A desktop notification when the track changes.
    var trackNotifications = false
    /// Also notify when the app has focus and the track changed on its own.
    var trackNotificationsFocused = false
    /// The window title follows the playing track (macOS).
    var windowTitleFollowsTrack = true
    /// A menu bar item with the playing track and transport (macOS).
    var menuBarItem = false
    /// The mini player opens in its small 320 by 88 form.
    var miniCompact = false
    /// Where the mini player was left: the window's lower-left origin in screen points, or nil for the default corner.
    var miniPositionX: Double? = nil
    var miniPositionY: Double? = nil
    /// Theatre mode columns and clock.
    var theatreLyrics = true
    var theatreQueue = false
    var theatreClock = false
    /// "left" or "right".
    var theatreClockSide = "right"
    /// "auto", "12" or "24".
    var theatreClockFormat = "auto"
    /// System-wide hotkeys (macOS only). Off until the person turns them on.
    var globalHotkeys = MusicHotkeyConfig()
    /// Music-video mode: a song that is a video plays its picture too, from the same player so sound and picture share one clock. Off by default.
    var videoMode = false
    /// Draw the seek bar as a moving wave while playing (it is a plain line when off, paused or when Reduce Motion is on).
    var wavySeekBar = false
    /// Pause when the headphones or speaker that were playing are unplugged or switched off.
    var pauseWhenOutputRemoved = true
    /// The equalizer, tone pad and stereo widening. Off until the person turns it on; it survives restarts.
    var equalizer = MusicEqualizerSettings()
    /// Automix: beat-matched transitions between songs stored on this device. Off by default; nothing is downloaded.
    var automix = MusicAutomixSettings()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case preventDuplicates, stickyShuffle, shuffleWholeQueue, playOnStart, crossfadeLength, trackNotifications, trackNotificationsFocused
        case windowTitleFollowsTrack, menuBarItem, miniCompact, miniPositionX, miniPositionY
        case theatreLyrics, theatreQueue, theatreClock, theatreClockSide, theatreClockFormat, globalHotkeys, videoMode, wavySeekBar, pauseWhenOutputRemoved
        case equalizer, automix
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preventDuplicates = try c.decodeIfPresent(Bool.self, forKey: .preventDuplicates) ?? false
        stickyShuffle = try c.decodeIfPresent(Bool.self, forKey: .stickyShuffle) ?? false
        shuffleWholeQueue = try c.decodeIfPresent(Bool.self, forKey: .shuffleWholeQueue) ?? true
        playOnStart = try c.decodeIfPresent(Bool.self, forKey: .playOnStart) ?? false
        let len = try c.decodeIfPresent(Int.self, forKey: .crossfadeLength) ?? 5
        crossfadeLength = min(10, max(1, len))
        trackNotifications = try c.decodeIfPresent(Bool.self, forKey: .trackNotifications) ?? false
        trackNotificationsFocused = try c.decodeIfPresent(Bool.self, forKey: .trackNotificationsFocused) ?? false
        windowTitleFollowsTrack = try c.decodeIfPresent(Bool.self, forKey: .windowTitleFollowsTrack) ?? true
        menuBarItem = try c.decodeIfPresent(Bool.self, forKey: .menuBarItem) ?? false
        miniCompact = try c.decodeIfPresent(Bool.self, forKey: .miniCompact) ?? false
        miniPositionX = try c.decodeIfPresent(Double.self, forKey: .miniPositionX)
        miniPositionY = try c.decodeIfPresent(Double.self, forKey: .miniPositionY)
        theatreLyrics = try c.decodeIfPresent(Bool.self, forKey: .theatreLyrics) ?? true
        theatreQueue = try c.decodeIfPresent(Bool.self, forKey: .theatreQueue) ?? false
        theatreClock = try c.decodeIfPresent(Bool.self, forKey: .theatreClock) ?? false
        let side = try c.decodeIfPresent(String.self, forKey: .theatreClockSide) ?? "right"
        theatreClockSide = side == "left" ? "left" : "right"
        let fmt = try c.decodeIfPresent(String.self, forKey: .theatreClockFormat) ?? "auto"
        theatreClockFormat = ["auto", "12", "24"].contains(fmt) ? fmt : "auto"
        globalHotkeys = try c.decodeIfPresent(MusicHotkeyConfig.self, forKey: .globalHotkeys) ?? MusicHotkeyConfig()
        videoMode = try c.decodeIfPresent(Bool.self, forKey: .videoMode) ?? false
        wavySeekBar = try c.decodeIfPresent(Bool.self, forKey: .wavySeekBar) ?? false
        pauseWhenOutputRemoved = try c.decodeIfPresent(Bool.self, forKey: .pauseWhenOutputRemoved) ?? true
        equalizer = (try? c.decodeIfPresent(MusicEqualizerSettings.self, forKey: .equalizer)) ?? MusicEqualizerSettings()
        automix = (try? c.decodeIfPresent(MusicAutomixSettings.self, forKey: .automix)) ?? MusicAutomixSettings()
    }

    var queueOptions: MusicQueue.Options { MusicQueue.Options(preventDuplicates: preventDuplicates, shuffleWholeQueue: shuffleWholeQueue) }
}

/// The global hotkey table: master switch (off by default) and one binding string per action, such as "Ctrl+Alt+Space".
struct MusicHotkeyConfig: Codable, Equatable, Sendable {
    var enabled = false
    var bindings: [String: String] = MusicGlobalHotkeyAction.defaultBindings

    init() {}

    private enum CodingKeys: String, CodingKey { case enabled, bindings }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        bindings = try c.decodeIfPresent([String: String].self, forKey: .bindings) ?? MusicGlobalHotkeyAction.defaultBindings
    }
}
