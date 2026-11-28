import Foundation
import Observation

// Listening modes: a mode changes how the whole app behaves, not just what is queued. Each mode is a profile of switches that the player, the pages, the background work and the
// streaming code read. The person's own settings are never overwritten for good: what a mode changes when it starts is remembered and put back when the mode ends.

enum MusicListeningMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard, album, party, study, roadTrip, audiophile, background, batterySaving, dataSaving, guest, collector, classical, radio, practice, exhibition
    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: Localized.string("Normal")
        case .album: Localized.string("Album experience")
        case .party: Localized.string("Party")
        case .study: Localized.string("Study")
        case .roadTrip: Localized.string("Road trip")
        case .audiophile: Localized.string("Audiophile")
        case .background: Localized.string("Background")
        case .batterySaving: Localized.string("Battery saving")
        case .dataSaving: Localized.string("Data saving")
        case .guest: Localized.string("Guest listening")
        case .collector: Localized.string("Collector")
        case .classical: Localized.string("Classical")
        case .radio: Localized.string("Radio")
        case .practice: Localized.string("Practice")
        case .exhibition: Localized.string("Exhibition")
        }
    }

    var detail: String {
        switch self {
        case .standard: Localized.string("Everything as you set it.")
        case .album: Localized.string("Albums play in their own order, gapless, with no shuffle, no fades and no endless playback after them.")
        case .party: Localized.string("Guests in a Listen Together room may add songs. Your own taste is not changed by what they pick.")
        case .study: Localized.string("Less to look at: no motion, no pop-ups, no lyrics strip and no visualizer.")
        case .roadTrip: Localized.string("Large simple controls, endless playback on, and the best use of downloaded songs when the signal drops.")
        case .audiophile: Localized.string("The signal is left alone: no equalizer, effects, volume levelling or fades.")
        case .background: Localized.string("The screen does as little as possible while music plays: no animation, no visualizer, a slow lyrics clock.")
        case .batterySaving: Localized.string("Optional background work (sound analysis, filling in details) waits, animations are off and the visualizer draws less.")
        case .dataSaving: Localized.string("Lower audio quality, smaller pictures, no moving artwork and no pre-loading of extra songs.")
        case .guest: Localized.string("What is played is not counted: no history, no scrobbles, and your recommendations stay as they are.")
        case .collector: Localized.string("Details first: the side panel opens on Song Information with credits and release facts.")
        case .classical: Localized.string("Played in order, gapless, by whole works, with composer and work shown first.")
        case .radio: Localized.string("Opens Radio, turns off endless song playback and keeps live station details in front.")
        case .practice: Localized.string("Section controls: loops, bookmarks, small skips and slower playback are one tap away.")
        case .exhibition: Localized.string("Full-screen artwork with the visualizer, for showing music rather than choosing it.")
        }
    }

    var symbol: String {
        switch self {
        case .standard: "slider.horizontal.3"; case .album: "square.stack"; case .party: "party.popper"; case .study: "book"; case .roadTrip: "car"
        case .audiophile: "waveform.badge.magnifyingglass"; case .background: "moon"; case .batterySaving: "battery.50"; case .dataSaving: "antenna.radiowaves.left.and.right.slash"
        case .guest: "person.crop.circle.badge.questionmark"; case .collector: "list.bullet.rectangle"; case .classical: "music.quarternote.3"; case .radio: "dot.radiowaves.left.and.right"
        case .practice: "metronome"; case .exhibition: "photo.artframe"
        }
    }
}

/// What a mode switches. Every other part of the app asks this, never the mode's name.
struct MusicModeProfile: Equatable, Sendable {
    var reducesMotion = false
    /// Success and info toasts are held back; errors always show.
    var quietToasts = false
    var hidesLyricsStrip = false
    var noVisualizer = false
    /// 0 means no cap.
    var visualizerFPSCap = 0
    var bypassesSignalProcessing = false
    var noFades = false
    var keepsOrder = false
    var noEndlessPlayback = false
    var forcesEndlessPlayback = false
    var privateListening = false
    var pausesBackgroundWork = false
    var lowQuality = false
    var noExtraArtwork = false
    var noPreloading = false
    var largeControls = false
    var guestsMayQueue = false
    var opensSection: MusicSection?
    var showsInformation = false
    var fullScreenArtwork = false
    var practiceTools = false
    var slowLyricsClock = false

    static func of(_ m: MusicListeningMode) -> MusicModeProfile {
        var p = MusicModeProfile()
        switch m {
        case .standard: break
        case .album: p.keepsOrder = true; p.noFades = true; p.noEndlessPlayback = true
        case .party: p.guestsMayQueue = true; p.privateListening = true
        case .study: p.reducesMotion = true; p.quietToasts = true; p.hidesLyricsStrip = true; p.noVisualizer = true
        case .roadTrip: p.largeControls = true; p.forcesEndlessPlayback = true
        case .audiophile: p.bypassesSignalProcessing = true; p.noFades = true
        case .background: p.reducesMotion = true; p.noVisualizer = true; p.slowLyricsClock = true; p.quietToasts = true
        case .batterySaving: p.reducesMotion = true; p.pausesBackgroundWork = true; p.visualizerFPSCap = 15; p.noPreloading = true
        case .dataSaving: p.lowQuality = true; p.noExtraArtwork = true; p.noPreloading = true
        case .guest: p.privateListening = true
        case .collector: p.showsInformation = true
        case .classical: p.keepsOrder = true; p.noFades = true; p.noEndlessPlayback = true
        case .radio: p.opensSection = .radio; p.noEndlessPlayback = true
        case .practice: p.practiceTools = true
        case .exhibition: p.fullScreenArtwork = true; p.reducesMotion = false
        }
        return p
    }
}

/// The current mode. Read anywhere (`MusicListeningModes.profile` needs no actor); changed through `set`.
@MainActor @Observable
final class MusicListeningModes {
    static let shared = MusicListeningModes()
    nonisolated static let key = "music.listeningMode"
    nonisolated static let backupKey = "music.listeningMode.backup"

    private(set) var mode: MusicListeningMode

    init() { mode = Self.stored }

    nonisolated static var stored: MusicListeningMode { MusicListeningMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .standard }
    nonisolated static var profile: MusicModeProfile { .of(stored) }

    /// What the person had before the mode changed it, so ending the mode puts it back.
    private struct Backup: Codable { var shuffle: Bool; var endless: Bool; var privateOn: Bool; var tempo: Double; var seekBack: Int; var seekForward: Int }

    func set(_ new: MusicListeningMode, hub: MusicHub) {
        guard new != mode else { return }
        let old = MusicModeProfile.of(mode)
        if mode != .standard { restore(hub: hub) }
        mode = new
        UserDefaults.standard.set(new.rawValue, forKey: Self.key)
        let p = MusicModeProfile.of(new)
        guard new != .standard else { MusicDebugLog.log("mode", "back to normal"); return }
        _ = old
        saveBackup(hub: hub)
        MusicDebugLog.log("mode", "mode \(new.rawValue)")
        let player = hub.player
        if p.keepsOrder, player.shuffle { player.shuffle = false }
        if p.noEndlessPlayback { player.setAutoplay(false) }
        if p.forcesEndlessPlayback { player.setAutoplay(true) }
        if p.privateListening { MusicPrivateListening.shared.isOn = true }
        if p.practiceTools {
            UserDefaults.standard.set(5, forKey: MusicSeekPrefs.backKey); UserDefaults.standard.set(5, forKey: MusicSeekPrefs.forwardKey)
            MusicChromeState.shared.marksOpen = true
        }
        if let s = p.opensSection { hub.nav.select(s) }
        // The Credits tab carries the recording's facts (length, release, ISRC, stream details); the Info tab has no button any more.
        if p.showsInformation { MusicContextPanelState.shared.show(.credits) }
        if p.fullScreenArtwork { MusicChromeState.shared.visualizerOpen = true }
        if p.pausesBackgroundWork || p.noVisualizer { player.setVisualizer(false) }
        if p.bypassesSignalProcessing { player.modeChangedSignalPath() }
        MusicToasts.shared.show(Localized.string("%@ mode", new.title), kind: .info)
    }

    private func saveBackup(hub: MusicHub) {
        let b = Backup(shuffle: hub.player.shuffle, endless: hub.library.settings.endlessPlayback, privateOn: MusicPrivateListening.shared.isOn, tempo: 1,
                       seekBack: UserDefaults.standard.integer(forKey: MusicSeekPrefs.backKey), seekForward: UserDefaults.standard.integer(forKey: MusicSeekPrefs.forwardKey))
        if let d = try? JSONEncoder().encode(b) { UserDefaults.standard.set(d, forKey: Self.backupKey) }
    }

    private func restore(hub: MusicHub) {
        guard let d = UserDefaults.standard.data(forKey: Self.backupKey), let b = try? JSONDecoder().decode(Backup.self, from: d) else { return }
        hub.player.setAutoplay(b.endless)
        MusicPrivateListening.shared.isOn = b.privateOn
        UserDefaults.standard.set(b.seekBack, forKey: MusicSeekPrefs.backKey); UserDefaults.standard.set(b.seekForward, forKey: MusicSeekPrefs.forwardKey)
        UserDefaults.standard.removeObject(forKey: Self.backupKey)
        hub.player.modeChangedSignalPath()
    }
}
