import SwiftUI

/// Player settings for Music: playback, queue behaviour, windows and notifications, theatre mode and global hotkeys. Shown as the player block.
struct MusicPlayerSettingsSection: View {
    let hub: MusicHub
    @State private var notifyNote: String?

    private var settings: MusicSettings { hub.library.settings }
    private var prefs: MusicPlayerPrefs { hub.library.settings.player }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicTokens.settingsGroupSpacing) {
            playbackGroup
            queueGroup
            MusicShuffleAutoplaySettingsGroup(hub: hub)
            windowsGroup
            theatreGroup
            MusicHotkeysSection(hub: hub)
        }
    }

    private func pref<V>(_ kp: WritableKeyPath<MusicPlayerPrefs, V>) -> Binding<V> {
        Binding(get: { hub.library.settings.player[keyPath: kp] }, set: { hub.library.settings.player[keyPath: kp] = $0 })
    }

    private var crossfadeLength: Double { MusicCrossfade.length(setting: settings.crossfadeSeconds) }

    @AppStorage(MusicSeekPrefs.backKey) private var seekBack = MusicSeekPrefs.defaultInterval
    @AppStorage(MusicSeekPrefs.forwardKey) private var seekForward = MusicSeekPrefs.defaultInterval
    @AppStorage(MusicSeekPrefs.resumeKey) private var resumeMinutes = MusicSeekPrefs.defaultResumeMinutes

    private var playbackGroup: some View {
        MusicSettingsGroup(title: "Player") {
            MusicToggleRow(title: "Pause when headphones disconnect", atlas: "control.music.settingsPauseOnDisconnect", info: "Pauses playback when the headphones or Bluetooth speaker that were playing are unplugged or switched off, so music does not suddenly play out loud.",
                           isOn: Binding(get: { hub.library.settings.player.pauseWhenOutputRemoved }, set: { hub.library.settings.player.pauseWhenOutputRemoved = $0 }))
            MusicToggleRow(title: "Normalise volume", info: "Brings songs to the same loudness. Quiet songs are raised by up to 3 dB with a limiter against clipping.",
                           isOn: Binding(get: { settings.normalizeVolume }, set: { hub.library.settings.normalizeVolume = $0; hub.player.refreshNormalisation() }))
            MusicToggleRow(title: "Crossfade", info: "Songs flow into each other without a gap. It is not used in listening rooms, in the Album, Audiophile and Classical modes, or while the equalizer, pitch, reverb, Karaoke or a format that cannot overlap is in use.",
                           isOn: Binding(get: { crossfadeLength > 0 }, set: { on in hub.library.settings.crossfadeSeconds = on ? Double(prefs.crossfadeLength) : 0 }))
            if crossfadeLength > 0 {
                MusicSliderRow(title: "Crossfade length",
                               value: Binding(get: { crossfadeLength },
                                              set: { v in let n = Int(min(10, max(1, v.rounded()))); hub.library.settings.player.crossfadeLength = n; hub.library.settings.crossfadeSeconds = Double(n) }),
                               range: 1...10, valueText: "\(Int(crossfadeLength)) s")
            }
            MusicToggleRow(title: "Autoplay", info: "Keeps similar music coming when two songs or fewer are left.",
                           isOn: Binding(get: { settings.endlessPlayback }, set: { hub.player.setAutoplay($0) }))
            MusicToggleRow(title: "Start playing when the app opens", isOn: pref(\.playOnStart))
            MusicPickerRow(title: "Skip back", atlas: "control.music.settingsSeekBack", info: "How far the skip-back key jumps.", selection: $seekBack,
                           options: MusicSeekPrefs.intervalChoices.map { (value: $0, label: Localized.string("%@ seconds", String($0))) })
            MusicPickerRow(title: "Skip forward", atlas: "control.music.settingsSeekForward", info: "How far the skip-forward key jumps.", selection: $seekForward,
                           options: MusicSeekPrefs.intervalChoices.map { (value: $0, label: Localized.string("%@ seconds", String($0))) })
            MusicPickerRow(title: "Remember my place", atlas: "control.music.settingsResume", info: "A recording this long or longer (a mix, a lecture, a long work) carries on from where you stopped, separately for each one.", selection: $resumeMinutes,
                           options: MusicSeekPrefs.resumeChoices.map { (value: $0, label: $0 == 0 ? Localized.string("Never") : Localized.string("%@ minutes or longer", String($0))) })
        }
    }

    private var queueGroup: some View {
        MusicSettingsGroup(title: "Queue") {
            MusicToggleRow(title: "Move instead of duplicating", info: "Adding a song that is already queued moves it rather than adding a second copy.", isOn: pref(\.preventDuplicates))
            MusicToggleRow(title: "Keep shuffle on for new queues", info: "Otherwise an album you open plays in order.", isOn: pref(\.stickyShuffle))
            MusicToggleRow(title: "Shuffle the whole queue", info: "Shuffle also mixes in songs added with Add to Queue. Play Next always stays next.", isOn: pref(\.shuffleWholeQueue))
        }
    }

    private var windowsGroup: some View {
        MusicSettingsGroup(title: "Windows") {
            MusicToggleRow(title: "Show the song in the window title", isOn: pref(\.windowTitleFollowsTrack))
            MusicToggleRow(title: "Menu bar item", info: "The playing song and playback controls in the menu bar.", isOn: pref(\.menuBarItem))
            MusicToggleRow(title: "Notify when the song changes", info: "Only while StreamSetu is in the background.", isOn: Binding(get: { prefs.trackNotifications }, set: { on in
                hub.library.settings.player.trackNotifications = on
                if on { Task { let s = await NotificationPermission.request(); notifyNote = s == .denied ? "Notifications are turned off for StreamSetu in System Settings." : nil } }
            }))
            if prefs.trackNotifications {
                MusicToggleRow(title: "Also when StreamSetu is open", info: "Only for songs that started on their own, not ones you picked.", isOn: pref(\.trackNotificationsFocused))
            }
            if let notifyNote { MusicNote(text: notifyNote, tone: .warning) }
        }
    }

    private var theatreGroup: some View {
        MusicSettingsGroup(title: "Theatre mode", footer: "A large, quiet view for the song playing. Columns need a wide window.") {
            MusicToggleRow(title: "Show lyrics", isOn: pref(\.theatreLyrics))
            MusicToggleRow(title: "Show the queue", isOn: pref(\.theatreQueue))
            MusicToggleRow(title: "Show a clock", isOn: pref(\.theatreClock))
            if prefs.theatreClock {
                MusicPickerRow(title: "Clock side", selection: pref(\.theatreClockSide), options: [("left", "Left"), ("right", "Right")])
                MusicPickerRow(title: "Clock format", selection: pref(\.theatreClockFormat), options: [("auto", "Automatic"), ("12", "12 hour"), ("24", "24 hour")])
            }
        }
    }
}
