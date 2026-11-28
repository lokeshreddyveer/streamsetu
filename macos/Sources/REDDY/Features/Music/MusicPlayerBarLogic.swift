import SwiftUI

// Pure logic behind the player bar and the Now Playing panel: which controls stay visible at a width, the scrub and playback state, the marquee
// schedule, the facts shown in the quality popover and the artwork size. No views here, so every number is tested.

// MARK: right cluster and priority collapse

/// The controls of the bar's right side, in the order they are kept as the bar gets narrower (most important first).
enum MusicBarControl: String, CaseIterable, Hashable, Sendable {
    case queue, lyrics, output, volume, expand, quality, effects, sleep, surfaces, comments
}

enum MusicBarMetrics {
    /// The bar is 76 pt tall; the compact bar 68 pt (both inside the 68 to 80 pt range of the design).
    static let heightFull: CGFloat = 76
    static let heightCompact: CGFloat = 68
    /// Artwork edge in the bar's left block.
    static let artwork: CGFloat = 52
    static let artworkCompact: CGFloat = 44
    /// One icon control with the gap after it.
    static let slot: CGFloat = MusicTokens.hitTarget + MusicSpace.xxs
    static let volumeSlider: CGFloat = 112
    static let moreWidth: CGFloat = slot

    /// Width one control takes in the cluster, gap included.
    static func width(of control: MusicBarControl) -> CGFloat {
        switch control {
        case .volume: slot + volumeSlider
        case .quality: 112
        case .effects, .sleep: slot + 28
        case .surfaces:
            #if os(macOS)
            slot * 2
            #else
            slot
            #endif
        case .queue, .lyrics, .output, .expand, .comments: slot
        }
    }

    static func height(for cls: MusicLayoutClass) -> CGFloat { cls == .compact ? heightCompact : heightFull }
}

/// The scrubber's own focus treatment: a thin ring only for keyboard focus, thicker under Increase Contrast. Never after the mouse.
enum MusicBarFocusRing {
    static func visible(focused: Bool, keyboard: Bool) -> Bool { focused && keyboard }
    static func lineWidth(increasedContrast: Bool) -> CGFloat { increasedContrast ? 2 : 1 }
}

enum MusicBarCollapse {
    /// Most important first; the tail folds into the "..." menu first.
    static let priority: [MusicBarControl] = [.queue, .lyrics, .output, .volume, .expand, .quality, .effects, .sleep, .surfaces, .comments]
    /// Left to right on screen.
    static let displayOrder: [MusicBarControl] = [.quality, .effects, .sleep, .surfaces, .comments, .lyrics, .queue, .output, .volume, .expand]

    struct Result: Equatable, Sendable {
        var shown: [MusicBarControl]
        var overflow: [MusicBarControl]
    }

    /// The longest prefix of the priority list that fits in `available` points next to the "..." button. A wider bar never shows fewer
    /// controls than a narrower one. Controls that are not `present` (no comments for this track, no quality yet) take no room.
    static func resolve(available: CGFloat, present: Set<MusicBarControl>) -> Result {
        let ordered = priority.filter(present.contains)
        guard available.isFinite else { return Result(shown: [], overflow: ordered) }
        var used = MusicBarMetrics.moreWidth
        var shown: [MusicBarControl] = []
        for c in ordered {
            let w = MusicBarMetrics.width(of: c)
            if used + w > available { break }
            used += w
            shown.append(c)
        }
        return Result(shown: shown, overflow: Array(ordered.dropFirst(shown.count)))
    }

    /// Whether the compact bar also shows the next button next to play and pause.
    static func compactShowsNext(width: CGFloat) -> Bool { width >= 340 }
}

// MARK: scrub and playback

/// Playback position and the person's finger are two separate things. While dragging the bar shows the finger; after release it holds the
/// released value until playback has caught up (or a second has passed), so the thumb never snaps back to the old position. Pure: time is
/// passed in, so tests use their own clock.
struct MusicScrubState: Equatable, Sendable {
    static let settleTolerance = 0.02
    static let settleTimeout: TimeInterval = 1.0
    static let keyStep = 0.02
    /// Page Up and Page Down move this far (ten small steps, as the slider pattern suggests).
    static let pageStep = 0.2

    private(set) var dragFraction: Double?
    private(set) var pendingFraction: Double?
    private(set) var pendingAt: TimeInterval = 0

    var isScrubbing: Bool { dragFraction != nil }

    static func clamp(_ f: Double) -> Double { f.isFinite ? min(1, max(0, f)) : 0 }

    mutating func begin(_ fraction: Double) {
        dragFraction = Self.clamp(fraction)
        pendingFraction = nil
    }

    mutating func update(_ fraction: Double) {
        if dragFraction == nil { begin(fraction) } else { dragFraction = Self.clamp(fraction) }
    }

    /// Ends the drag and returns the fraction to seek to (nil when no drag was active).
    mutating func end(_ fraction: Double? = nil, now: TimeInterval) -> Double? {
        guard let held = dragFraction else { return nil }
        let target = Self.clamp(fraction ?? held)
        dragFraction = nil
        pendingFraction = target
        pendingAt = now
        return target
    }

    mutating func cancel() { dragFraction = nil; pendingFraction = nil }

    /// What the bar draws: the finger while scrubbing, the released value until playback arrives, else playback.
    func displayFraction(playback: Double, now: TimeInterval) -> Double {
        if let d = dragFraction { return d }
        if let p = pendingFraction, now - pendingAt < Self.settleTimeout, abs(Self.clamp(playback) - p) > Self.settleTolerance { return p }
        return Self.clamp(playback)
    }

    /// Drops the held value once playback has reached it or the wait is over. Call from the position change.
    mutating func settle(playback: Double, now: TimeInterval) {
        guard let p = pendingFraction else { return }
        if now - pendingAt >= Self.settleTimeout || abs(Self.clamp(playback) - p) <= Self.settleTolerance { pendingFraction = nil }
    }

    /// A keyboard or VoiceOver nudge: one step forward or back from the displayed value.
    static func nudged(_ fraction: Double, forward: Bool) -> Double { clamp(fraction + (forward ? keyStep : -keyStep)) }
    static func paged(_ fraction: Double, forward: Bool) -> Double { clamp(fraction + (forward ? pageStep : -pageStep)) }
}

/// Widths of the time labels so the bar does not shift as digits change: tabular digits plus a fixed width chosen from the song length.
enum MusicBarTimeLabel {
    /// Width in points for a label of a song of `duration` seconds (an hour or more needs the extra "h:" digits).
    static func width(forDuration duration: TimeInterval) -> CGFloat {
        guard duration.isFinite else { return 40 }
        return duration >= 3600 ? 58 : 40
    }

    /// "1:05 of 3:45" for the scrubber's spoken value.
    static func spoken(position: TimeInterval, duration: TimeInterval) -> String {
        Localized.string("%1$@ of %2$@", MusicTime.clock(position), MusicTime.clock(duration))
    }
}

// MARK: marquee

/// When a long title moves: it rests first, scrolls one pass, rests again, and stops after a few passes so it never moves for ever.
/// Reduce Motion never moves it at all (the view checks that). Time is passed in, so the schedule is tested with a fake clock.
enum MusicMarqueeSchedule {
    static let initialRest: TimeInterval = 2.0
    static let restBetween: TimeInterval = 3.0
    static let maxPasses = 3

    static func passDuration(textWidth: CGFloat) -> TimeInterval { TimeInterval((textWidth + MusicMarqueeMath.gap) / MusicMarqueeMath.speed) }
    static func totalDuration(textWidth: CGFloat) -> TimeInterval {
        initialRest + TimeInterval(maxPasses) * (passDuration(textWidth: textWidth) + restBetween)
    }

    /// Horizontal shift (zero or negative) after `elapsed` seconds of running.
    static func offset(elapsed: TimeInterval, textWidth: CGFloat) -> CGFloat {
        guard elapsed.isFinite, textWidth > 0, elapsed > initialRest else { return 0 }
        let pass = passDuration(textWidth: textWidth)
        let cycle = pass + restBetween
        let t = elapsed - initialRest
        let n = Int(t / cycle)
        guard n < maxPasses else { return 0 }
        let within = t - TimeInterval(n) * cycle
        return within < pass ? -CGFloat(within) * MusicMarqueeMath.speed : 0
    }

    static func isFinished(elapsed: TimeInterval, textWidth: CGFloat) -> Bool { elapsed >= totalDuration(textWidth: textWidth) }
}

/// A running marquee with its own start time and an injectable clock (seconds).
struct MusicMarqueeRun: Equatable, Sendable {
    private(set) var startedAt: TimeInterval
    init(startedAt: TimeInterval) { self.startedAt = startedAt }
    mutating func restart(at now: TimeInterval) { startedAt = now }
    func elapsed(at now: TimeInterval) -> TimeInterval { max(0, now - startedAt) }
    func offset(at now: TimeInterval, textWidth: CGFloat) -> CGFloat { MusicMarqueeSchedule.offset(elapsed: elapsed(at: now), textWidth: textWidth) }
    func isFinished(at now: TimeInterval, textWidth: CGFloat) -> Bool { MusicMarqueeSchedule.isFinished(elapsed: elapsed(at: now), textWidth: textWidth) }
}

// MARK: quality facts

/// What the audio quality popover may say. Every row comes from the stream the player holds for this track or from the output the player
/// reports; nothing is guessed. Lossless is stated only when the stream is flagged lossless AND its codec is a known lossless one
/// (`isVerifiedLossless`); the chip then shows the sample rate instead of a bitrate. Bit depth is not exposed by the stream, so it is never shown.
struct MusicQualityFacts: Equatable, Sendable {
    struct Row: Equatable, Sendable, Identifiable {
        var id: String
        var label: String
        var value: String
    }

    var rows: [Row]
    /// The short text for the chip, nil when the stream says nothing worth a chip.
    var chip: String?
    var isVerifiedLossless: Bool

    static let losslessCodecs: Set<String> = ["flac", "alac", "wav", "wave", "aiff", "pcm"]

    static func isVerifiedLossless(_ s: MusicStream) -> Bool {
        s.isLossless && losslessCodecs.contains(s.codec.lowercased())
    }

    static func khz(_ hz: Int) -> String { String(format: "%g kHz", Double(hz) / 1000) }

    static func make(stream: MusicStream?, effectsActive: Bool = false, route: String? = nil) -> MusicQualityFacts {
        var rows: [Row] = []
        var chip: String?
        var lossless = false
        if let s = stream {
            let codec = s.codec.trimmingCharacters(in: .whitespaces)
            if !codec.isEmpty { rows.append(Row(id: "codec", label: Localized.string("Codec"), value: codec.uppercased())) }
            let container = s.container.trimmingCharacters(in: .whitespaces)
            if !container.isEmpty { rows.append(Row(id: "container", label: Localized.string("Container"), value: container.uppercased())) }
            if let b = s.bitrate, b > 0 { rows.append(Row(id: "bitrate", label: Localized.string("Bitrate"), value: "\(b) kbps")) }
            if let r = s.sampleRate, r > 0 { rows.append(Row(id: "sampleRate", label: Localized.string("Sample rate"), value: khz(r))) }
            lossless = isVerifiedLossless(s)
            if lossless { rows.append(Row(id: "lossless", label: Localized.string("Lossless"), value: Localized.string("Yes"))) }
            rows.append(Row(id: "delivery", label: Localized.string("Delivery"), value: deliveryName(s.proto)))
            var parts: [String] = []
            if !codec.isEmpty { parts.append(codec.uppercased()) }
            if lossless, let r = s.sampleRate, r > 0 { parts.append(khz(r)) }
            else if let b = s.bitrate, b > 0 { parts.append("\(b) kbps") }
            chip = parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        if let route, !route.isEmpty { rows.append(Row(id: "route", label: Localized.string("Output"), value: route)) }
        if effectsActive { rows.append(Row(id: "effects", label: Localized.string("Effects"), value: Localized.string("On, the sound is processed"))) }
        return MusicQualityFacts(rows: rows, chip: chip, isVerifiedLossless: lossless)
    }

    static func deliveryName(_ p: MusicStreamProtocol) -> String {
        switch p {
        case .progressive: Localized.string("Direct file")
        case .hls: "HLS"
        case .dash: "DASH"
        }
    }
}

/// The output line: what the player's output policy actually resolved to.
enum MusicOutputRoute {
    static func label(resolution: MusicOutputDevicePolicy.Resolution, chosenName: String?) -> String {
        switch resolution {
        case .systemDefault: Localized.string("System output")
        case .device: chosenName ?? Localized.string("System output")
        case .yieldedMissing, .yieldedFailed: Localized.string("System output")
        }
    }
}

// MARK: now playing

enum MusicNowPlayingMetrics {
    static let artworkRange: ClosedRange<CGFloat> = 320...500
    /// Space left on each side of the artwork inside the panel.
    static let sideMargin: CGFloat = MusicSpace.md

    /// The artwork edge for a panel `panelWidth` wide: as large as the panel allows up to 500, and 320 or more whenever the panel can hold
    /// that (a narrower panel fills its width instead of overflowing).
    static func artworkSize(panelWidth: CGFloat) -> CGFloat {
        guard panelWidth.isFinite, panelWidth > 0 else { return 0 }
        let room = max(0, panelWidth - sideMargin * 2)
        return min(artworkRange.upperBound, room)
    }

    static let headerGap: CGFloat = MusicSpace.xs

    /// Widest the title column in the panel header may be: the header less the heart, the "..." menu and the gaps. The heart follows the text.
    static func headerTitleMaxWidth(headerWidth: CGFloat) -> CGFloat {
        guard headerWidth.isFinite else { return 0 }
        return max(0, headerWidth - MusicTokens.hitTarget * 2 - headerGap * 2)
    }

    /// Labels under the title: explicit and the music-video version, only when the track says so.
    static func versionLabels(_ t: MusicTrack) -> [String] {
        var out: [String] = []
        if t.explicit { out.append(Localized.string("Explicit")) }
        if t.isVideo == true { out.append(Localized.string("Music video")) }
        return out
    }
}
