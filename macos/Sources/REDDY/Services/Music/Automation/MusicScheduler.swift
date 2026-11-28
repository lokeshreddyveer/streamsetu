import Foundation
import Observation
#if os(macOS)
import CoreAudio
#endif

// Things that happen by themselves while StreamSetu is open: schedules (play at a time, a wake-up alarm that fades in, stop at a time), rules for an audio output (when
// your headphones connect), an action when Music starts, and triggers on playback events. Each runs ordinary commands through MusicAutomation, with its own permission.
// They work only while the app is running: StreamSetu does not install anything that runs in the background on its own.

struct MusicSchedule: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case play, alarm, stop }
    var id = UUID()
    var kind: Kind
    var hour: Int
    var minute: Int
    /// 1 = Sunday ... 7 = Saturday (Calendar's weekday). Empty means every day.
    var weekdays: Set<Int> = []
    /// What to start (play and alarm): a command like "playLiked" or "playPlaylist" with its argument.
    var call = MusicCommandCall(name: MusicCommandName.playLikedShuffled.rawValue)
    var enabled = true
    /// Alarm only: seconds to fade the volume in from quiet.
    var fadeSeconds = 60
    var lastFired: Date?
}

struct MusicOutputRule: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    /// Part of the output's name, such as "AirPods" or "Car".
    var match: String
    var calls: [MusicCommandCall]
    var enabled = true
}

struct MusicTrigger: Codable, Identifiable, Equatable, Sendable {
    enum Event: String, Codable, CaseIterable, Sendable {
        case playbackStarted, playbackPaused, songChanged
        var title: String {
            switch self {
            case .playbackStarted: Localized.string("Playback starts")
            case .playbackPaused: Localized.string("Playback pauses")
            case .songChanged: Localized.string("The song changes")
            }
        }
    }
    var id = UUID()
    var event: Event
    var call: MusicCommandCall
    var enabled = true
}

struct MusicAutomationConfig: Codable, Equatable, Sendable {
    var schedules: [MusicSchedule] = []
    var rules: [MusicOutputRule] = []
    var triggers: [MusicTrigger] = []
    /// Run when Music is first opened in a session; nil does nothing.
    var launch: MusicCommandCall?
}

enum MusicScheduleRules {
    /// Whether `s` is due at `now`: the minute matches, the day is allowed, and it has not already fired in this minute.
    static func isDue(_ s: MusicSchedule, now: Date, calendar: Calendar = .current) -> Bool {
        guard s.enabled else { return false }
        let c = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        guard c.hour == s.hour, c.minute == s.minute else { return false }
        if !s.weekdays.isEmpty, let d = c.weekday, !s.weekdays.contains(d) { return false }
        if let last = s.lastFired, now.timeIntervalSince(last) < 60 { return false }
        return true
    }
    static func ruleMatches(_ rule: MusicOutputRule, outputName: String) -> Bool {
        let m = rule.match.trimmingCharacters(in: .whitespaces)
        return rule.enabled && !m.isEmpty && outputName.range(of: m, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// The name of the audio output that sound is going to right now: the one the person chose in Music, otherwise the Mac's current default output.
@MainActor
enum MusicActiveOutput {
    static func name(_ hub: MusicHub) -> String? {
        let o = hub.player.outputs
        if let uid = o.currentUID, let n = o.available.first(where: { $0.uid == uid })?.name { return n }
        #if os(macOS)
        return systemDefaultName()
        #else
        return nil
        #endif
    }

    #if os(macOS)
    private static func systemDefaultName() -> String? {
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        var name: Unmanaged<CFString>?
        var nsize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var naddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &naddr, 0, nil, &nsize, &name) == noErr, let n = name else { return nil }
        return n.takeRetainedValue() as String
    }
    #endif
}

@MainActor @Observable
final class MusicScheduler {
    static let shared = MusicScheduler()
    static let key = "music.automation.config"

    var config: MusicAutomationConfig { didSet { save() } }
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private weak var hub: MusicHub?
    @ObservationIgnored private var last: (playing: Bool, uid: String?, output: String?) = (false, nil, nil)
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var rampTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        config = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(MusicAutomationConfig.self, from: $0) } ?? MusicAutomationConfig()
    }

    private func save() { if let d = try? JSONEncoder().encode(config) { UserDefaults.standard.set(d, forKey: Self.key) } }

    /// Starts watching. Called once when Music opens; a second call does nothing.
    func start(hub: MusicHub) {
        guard timer == nil else { return }
        self.hub = hub
        let p = hub.player
        last = (p.isPlaying, p.current?.uid, MusicActiveOutput.name(hub))
        if !launched, let call = config.launch { launched = true; MusicAutomation.perform(call, from: .schedule, hub: hub) }
        launched = true
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func tick() {
        guard let hub else { return }
        let now = Date()
        for i in config.schedules.indices where MusicScheduleRules.isDue(config.schedules[i], now: now) {
            config.schedules[i].lastFired = now
            run(config.schedules[i], hub: hub)
        }
        let p = hub.player
        let state = (p.isPlaying, p.current?.uid, MusicActiveOutput.name(hub))
        if state.0 != last.playing { fire(state.0 ? .playbackStarted : .playbackPaused, hub: hub) }
        if state.1 != last.uid, state.1 != nil { fire(.songChanged, hub: hub) }
        if state.2 != last.output, let name = state.2 {
            for r in config.rules where MusicScheduleRules.ruleMatches(r, outputName: name) { for c in r.calls { MusicAutomation.perform(c, from: .schedule, hub: hub) } }
        }
        last = state
    }

    private func fire(_ e: MusicTrigger.Event, hub: MusicHub) {
        for t in config.triggers where t.enabled && t.event == e { MusicAutomation.perform(t.call, from: .trigger, hub: hub) }
    }

    private func run(_ s: MusicSchedule, hub: MusicHub) {
        switch s.kind {
        case .stop: fadeOutAndPause(hub: hub)
        case .play: MusicAutomation.perform(s.call, from: .schedule, hub: hub)
        case .alarm:
            hub.player.volume = 0.05
            let r = MusicAutomation.perform(s.call, from: .schedule, hub: hub)
            guard r.ok else { hub.player.volume = 1; return }
            rampTask?.cancel()
            let steps = max(5, s.fadeSeconds), p = hub.player
            rampTask = Task { @MainActor in
                for i in 1...steps {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                    p.volume = max(p.volume, 0.05 + 0.95 * Float(i) / Float(steps))
                }
            }
        }
    }

    /// A gentle stop: the volume falls over ten seconds, then playback pauses and the volume comes back.
    func fadeOutAndPause(hub: MusicHub) {
        let p = hub.player
        guard p.isPlaying else { return }
        let original = p.volume
        rampTask?.cancel()
        rampTask = Task { @MainActor in
            for i in 1...10 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { p.volume = original; return }
                p.volume = original * (1 - Float(i) / 10)
            }
            p.pause(); p.volume = original
        }
    }
}
