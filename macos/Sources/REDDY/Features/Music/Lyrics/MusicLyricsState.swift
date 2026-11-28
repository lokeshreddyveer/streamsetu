import SwiftUI
import Observation

// Shared state of the animated lyrics panel: the person's display preferences, the clock that feeds every row, and the model that
// decides which rows are lit and where the list is heading. Rows read only what they need so a line change touches a few views.

enum MusicLyricsPrefs {
    static let blurKey = "music.lyrics.blur"
    static let textStepKey = "music.lyrics.textStep"
    static let translationLanguageKey = "music.lyrics.translationLanguage"
    static let alignmentKey = "music.lyrics.alignment"
    static let textSteps: [Double] = [0.85, 1, 1.15, 1.3, 1.5]

    static var blurEnabled: Bool { UserDefaults.standard.object(forKey: blurKey) as? Bool ?? true }
    static var textStep: Int { min(textSteps.count - 1, max(0, UserDefaults.standard.object(forKey: textStepKey) as? Int ?? 1)) }

    /// The language lyric translations are asked for; empty follows the system.
    static var translationLanguage: String { UserDefaults.standard.string(forKey: translationLanguageKey) ?? "" }
    static func effectiveTranslationLanguage(_ stored: String = translationLanguage) -> String {
        stored.isEmpty ? (Locale.current.language.languageCode?.identifier ?? "en") : stored
    }
}

/// Where the lyric lines sit: automatic puts a duet's second voice on the far side; the others place every line the same way.
enum MusicLyricsAlignment: Int, CaseIterable, Sendable {
    case automatic = 0, start, center, end

    static var saved: MusicLyricsAlignment { MusicLyricsAlignment(rawValue: UserDefaults.standard.object(forKey: MusicLyricsPrefs.alignmentKey) as? Int ?? 0) ?? .automatic }
    var next: MusicLyricsAlignment { MusicLyricsAlignment(rawValue: (rawValue + 1) % Self.allCases.count) ?? .automatic }
    var symbol: String {
        switch self {
        case .automatic: "textformat.alt"
        case .start: "text.alignleft"
        case .center: "text.aligncenter"
        case .end: "text.alignright"
        }
    }
    var title: String {
        switch self {
        case .automatic: Localized.string("Alignment: automatic")
        case .start: Localized.string("Alignment: left")
        case .center: Localized.string("Alignment: centered")
        case .end: Localized.string("Alignment: right")
        }
    }
    /// Whether a line sits on the trailing side, given what the duet layout says about it.
    func isFar(duetFar: Bool) -> Bool {
        switch self {
        case .automatic: duetFar
        case .start, .center: false
        case .end: true
        }
    }
    var isCentered: Bool { self == .center }
}

/// Feeds the lyric clock from the player's coarse readings and turns it into lyric time (offsets applied).
@MainActor
final class MusicLyricsTimeKeeper {
    private var clock = MusicLyricClock()
    private var token = 0
    var songOffsetMs: Int64 = 0
    var globalOffsetMs: Int64 = 0
    private(set) var playing = false
    private var lastPositionSeconds: Double?

    /// The player's position moves every 0.25 s but a timer may ask more often: a repeat of the same reading, stamped with a later time, would look like a late reading and skew the clock.
    static func isRepeat(position: Double, lastPosition: Double?, playing: Bool, lastPlaying: Bool, discontinuity: Bool) -> Bool {
        !discontinuity && playing == lastPlaying && lastPosition == position
    }

    static func now() -> Double { Date().timeIntervalSinceReferenceDate }

    /// An announced jump (seek, offset change, restart) bumps the token so the clock moves at once instead of waiting for a second reading to agree.
    func feed(positionSeconds: Double, playing: Bool, rate: Double, discontinuity: Bool = false, at: Double = MusicLyricsTimeKeeper.now()) {
        if Self.isRepeat(position: positionSeconds, lastPosition: lastPositionSeconds, playing: playing, lastPlaying: self.playing, discontinuity: discontinuity) { return }
        lastPositionSeconds = positionSeconds
        if discontinuity { token += 1 }
        clock.ingest(MusicLyricClockReading(positionMs: max(0, positionSeconds) * 1000, takenAt: at, token: token, advancing: playing))
        self.playing = playing
    }

    /// Where the song is now, before offsets.
    func playbackMs(at date: Date) -> Int64 { Int64(clock.positionMs(at: date.timeIntervalSinceReferenceDate)) }

    /// The time to look lyrics up at.
    func lyricMs(at date: Date) -> Int64 {
        MusicLyricsMotion.lyricTime(position: playbackMs(at: date), songOffset: songOffsetMs, globalOffset: globalOffsetMs)
    }
}

/// What the panel knows about the song right now. `live` rows are drawn through a frame loop; every other row is a still picture.
@MainActor @Observable
final class MusicLyricsPanelModel {
    private(set) var lit: Set<Int> = []
    private(set) var live: Set<Int> = []
    private(set) var focus: Int?
    private(set) var leadMs: Double = 350
    private(set) var breaks: Set<Int> = []
    var following = true
    var lastManualScroll: Date?
    var browsing: Bool { !following }
    var pickMode = false
    var picked: Set<Int> = []
    private(set) var isPlaying = false
    /// Bumps when the clock moved while no frame loop is running (a seek while paused) so still pictures redraw.
    private(set) var tick = 0
    func nudge() { tick &+= 1 }
    private(set) var firstPlacementDone = false
    var rowHeights: [Int: CGFloat] = [:]
    var viewportHeight: CGFloat = 600

    static let liveTailMs: Int64 = 1000
    static let liveLeadMs: Int64 = 400

    struct Snapshot: Equatable {
        var lit: Set<Int>
        var live: Set<Int>
        var focus: Int?
    }

    static func snapshot(lines: [MusicLyricLine], ms: Int64) -> Snapshot {
        let lit = MusicLyricsMotion.litRows(lines: lines, at: ms)
        let focus = MusicLyricsMotion.focusRow(lines: lines, at: ms).index
        var live = lit
        if let newest = MusicLyricsLookup.lineIndex(in: lines, at: ms + liveLeadMs) { live.insert(newest) }
        var i = (lit.max() ?? -1)
        while i >= 0 && i >= (lit.min() ?? 0) - 2 {
            if let end = MusicLyricsMotion.knownEnd(lines[i]) ?? (i + 1 < lines.count ? lines[i + 1].timeMs : nil), ms - end < liveTailMs, ms >= lines[i].timeMs { live.insert(i) }
            i -= 1
        }
        return Snapshot(lit: lit, live: live, focus: focus)
    }

    func apply(_ s: Snapshot, lines: [MusicLyricLine], ms: Int64) {
        if lit != s.lit { lit = s.lit }
        if live != s.live { live = s.live }
        if focus != s.focus { focus = s.focus }
        let lead = MusicLyricsMotion.focusRow(lines: lines, at: ms).leadMs
        if leadMs != lead { leadMs = lead }
    }

    func setPlaying(_ p: Bool) { if isPlaying != p { isPlaying = p } }
    func markPlaced() { firstPlacementDone = true }
    func resetForTrack() {
        lit = []; live = []; focus = nil; following = true; lastManualScroll = nil; pickMode = false; picked = []
        firstPlacementDone = false; rowHeights = [:]
    }

    func manualScroll(now: Date = Date()) { lastManualScroll = now; following = false }

    /// Called from a slow check while the panel is up: auto-follow resumes 3 s after the last manual scroll.
    func resumeIfDue(now: Date = Date()) {
        if !following, !pickMode, MusicLyricsMotion.followResumes(lastManual: lastManualScroll, now: now) { following = true }
    }

    var cardFull = false

    /// Picks or drops a line within the share card's character budget; the answer says whether the card was full.
    func togglePick(_ i: Int, lines: [MusicLyricLine]) {
        cardFull = MusicLyricsShareCard.toggle(i, in: &picked, lines: lines) == .full
    }
}

/// Asks the shared translation service for the extra lines the person switched on, once a song's lyrics are known.
@MainActor
enum MusicLyricsExtrasRequest {
    /// What to ask for. Pure so it can be tested: reading first (local and instant), then translation only when the song carries none and the system translator exists.
    static func plan(showRomanisation: Bool, showTranslation: Bool, hasRomanization: Bool, hasTranslation: Bool, translatorAvailable: Bool, isEmpty: Bool) -> (romanise: Bool, translate: Bool) {
        guard !isEmpty else { return (false, false) }
        return (showRomanisation && !hasRomanization, showTranslation && !hasTranslation && translatorAvailable)
    }

    static func request(hub: MusicHub, track: MusicTrack, lyrics l: MusicLyrics) {
        let settings = hub.library.settings
        let svc = hub.translation
        let p = plan(showRomanisation: settings.showRomanisation, showTranslation: settings.showTranslation, hasRomanization: l.hasRomanization,
                     hasTranslation: l.hasTranslation, translatorAvailable: svc.isAvailable, isEmpty: l.isEmpty)
        if p.romanise, svc.romanization.subLines == nil { svc.requestRomanization(of: l) }
        if p.translate, svc.translation.subLines == nil {
            svc.requestTranslation(of: l, trackID: track.uid, target: MusicLyricsPrefs.effectiveTranslationLanguage())
        }
    }
}
