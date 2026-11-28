import Foundation
import Observation

/// What the sleep timer needs from the player, so tests can drive it without audio.
@MainActor
protocol MusicSleepPlayback: AnyObject {
    var isPlaying: Bool { get }
    var isBuffering: Bool { get }
    var volume: Float { get set }
    var position: TimeInterval { get }
    var duration: TimeInterval { get }
    var currentUID: String? { get }
    func pause()
    /// Marks the playing song as the last one (the player's own stop-after), so an end-of-track timer ends exactly at the song's end. True when this call set the mark.
    func armStopAfterCurrentSong() -> Bool
    /// Takes back a mark that `armStopAfterCurrentSong` set, when the timer is cancelled before the song ended.
    func disarmStopAfterCurrentSong()
}

extension MusicSleepPlayback {
    func armStopAfterCurrentSong() -> Bool { false }
    func disarmStopAfterCurrentSong() {}
}

extension MusicPlayer: MusicSleepPlayback {
    var currentUID: String? { current?.uid }
}

/// How long to wait before pausing.
enum MusicSleepPreset: Hashable, Sendable, Identifiable {
    case minutes(Int)
    case endOfTrack

    static let all: [MusicSleepPreset] = [.minutes(15), .minutes(30), .minutes(45), .minutes(60), .minutes(90), .endOfTrack]
    var id: String { switch self { case .minutes(let m): "m\(m)"; case .endOfTrack: "end" } }
    var title: String { switch self { case .minutes(let m): Localized.string("%d minutes", m); case .endOfTrack: Localized.string("End of this track") } }
}

/// The pure part of the timer: fade curve and labels.
enum MusicSleepLogic {
    static let fadeSeconds: TimeInterval = SleepTimer.fadeSeconds

    /// 1 until the last `fadeSeconds`, then a straight line down to 0 at the deadline.
    static func fadeFactor(remaining: TimeInterval) -> Float {
        if remaining >= fadeSeconds { return 1 }
        if remaining <= 0 { return 0 }
        return Float(remaining / fadeSeconds)
    }

    static func label(remaining: TimeInterval) -> String { MusicTime.clock(remaining.rounded(.up)) }
}

/// Pauses playback after a chosen time, easing the volume down over the last 10 seconds. It keeps nothing on disk. While no timer runs it owns no
/// task, so it costs nothing; while one runs it wakes once a second.
@MainActor @Observable
final class MusicSleepTimer {
    private(set) var preset: MusicSleepPreset?
    /// Seconds left, refreshed once a second while a timer runs; nil when none does.
    private(set) var remaining: TimeInterval?
    var isRunning: Bool { preset != nil }

    @ObservationIgnored private weak var player: (any MusicSleepPlayback)?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let autoTick: Bool
    @ObservationIgnored private var deadline: Date?
    @ObservationIgnored private var trackUID: String?
    @ObservationIgnored private var originalVolume: Float = 1
    @ObservationIgnored private var fading = false
    /// The last value the fade wrote; a different volume means the person moved the slider during the fade, and their choice wins.
    @ObservationIgnored private var lastFaded: Float?
    @ObservationIgnored private var overridden = false
    @ObservationIgnored private var idleTicks = 0
    /// True once the player has played (or buffered) since the timer was set; a timer armed while paused is not cancelled before that.
    @ObservationIgnored private var sawPlayback = false
    /// Seconds left at the previous tick of an end-of-track timer: a jump from almost nothing back to a whole song is the same song starting again (repeat one).
    @ObservationIgnored private var lastLeft: TimeInterval?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// True while the timer owns the player's stop-after mark for the playing song.
    @ObservationIgnored private var armedStop = false

    /// `autoTick` is false in tests, which call `tick()` themselves with their own clock.
    init(player: (any MusicSleepPlayback)? = nil, now: @escaping () -> Date = { Date() }, autoTick: Bool = true) {
        self.player = player
        self.now = now
        self.autoTick = autoTick
    }

    func attach(_ player: any MusicSleepPlayback) { self.player = player }

    func start(_ p: MusicSleepPreset) {
        cancel()
        guard let player else { return }
        // "End of this track" with nothing loaded has no track to end: it is not started (it would be cancelled one second later with no sign).
        if p == .endOfTrack, player.currentUID == nil { return }
        preset = p
        originalVolume = player.volume
        trackUID = player.currentUID
        sawPlayback = player.isPlaying || player.isBuffering
        switch p {
        case .minutes(let m):
            deadline = now().addingTimeInterval(TimeInterval(m * 60))
            remaining = TimeInterval(m * 60)
        case .endOfTrack:
            deadline = nil
            remaining = max(0, player.duration - player.position)
            armedStop = player.armStopAfterCurrentSong()
        }
        if autoTick {
            task = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                    self?.tick()
                }
            }
        }
    }

    /// Stops the timer and puts the volume back if it was being faded.
    func cancel() {
        task?.cancel(); task = nil
        if fading, !overridden { player?.volume = originalVolume }
        if armedStop { player?.disarmStopAfterCurrentSong() }
        reset()
    }

    /// One step of the countdown. Public so tests can drive it.
    func tick() {
        guard let preset, let player else { cancel(); return }
        // Between tracks the player is briefly neither playing nor buffering; two quiet ticks in a row mean a manual pause or stop.
        if !player.isPlaying && !player.isBuffering {
            idleTicks += 1
            // Only a pause after music was playing means the person stopped it: a timer set while paused waits for Play instead of vanishing two seconds later.
            if idleTicks >= 2, sawPlayback { cancel(); return }
        } else { idleTicks = 0; sawPlayback = true }

        let left: TimeInterval
        switch preset {
        case .minutes:
            guard let deadline else { cancel(); return }
            left = deadline.timeIntervalSince(now())
        case .endOfTrack:
            if let uid = trackUID, let cur = player.currentUID, cur != uid {
                // The person started another song (or skipped) after setting this: the song the timer was for is over, and the new one keeps playing. The stop mark the timer
                // set belonged to the old song, so cancelling drops it. Only when nothing is playing (the song ended on its own) does the timer finish.
                // The song ran to its end (the last reading was within two seconds of it): that is what the timer was for, whether or not the player's own mark was still set.
                if let before = lastLeft, before <= 2 { finish() }
                else if armedStop, player.isPlaying { cancel() } else { finish() }
                return
            }
            left = max(0, player.duration - player.position)
            // Repeat one: the song ended between two ticks and began again, so this timer's track is over.
            if let before = lastLeft, before <= 1.5, left > before + 3 { finish(); return }
            lastLeft = left
        }
        remaining = max(0, left)
        // A length that is not known yet (a live source, a song still loading) is not the end of the song.
        if left <= 0, !(preset == .endOfTrack && player.duration <= 0 && player.isPlaying) { finish(); return }
        // Until the fade starts the volume is the person's: a change made during the countdown is kept, not reverted at the end.
        if !fading { originalVolume = player.volume }
        if let w = lastFaded, abs(player.volume - w) > 0.002 { overridden = true; lastFaded = nil }
        let f = MusicSleepLogic.fadeFactor(remaining: left)
        if f < 1, !overridden {
            fading = true
            let v = originalVolume * f
            lastFaded = v
            player.volume = v
        } else if f >= 1, fading, !overridden {
            // The song was moved back out of the fade (a seek, or it began again): the volume the person had comes back.
            player.volume = originalVolume
            fading = false; lastFaded = nil
        }
    }

    private func finish() {
        let restore = originalVolume
        let keep = overridden
        let p = player
        task?.cancel(); task = nil
        // The mark clears itself when the song ends by it; when the timer finishes some other way (repeat one keeps looping the song) it is still on the row, so it is taken off.
        if armedStop { p?.disarmStopAfterCurrentSong() }
        armedStop = false
        p?.pause()
        if !keep { p?.volume = restore }
        fading = false
        reset()
    }

    private func reset() {
        preset = nil; remaining = nil; deadline = nil; trackUID = nil; fading = false; idleTicks = 0; sawPlayback = false; lastFaded = nil; overridden = false; lastLeft = nil; armedStop = false
    }
}
