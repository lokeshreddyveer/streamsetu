import Foundation
import AVFoundation

// The rules around the next track and around failure: when to prime the lookahead, when its result may be used, what to do when a stream
// fails. All plain values and functions, so every branch can be tested without audio.

// MARK: lookahead

/// Which queue row is primed (loaded in the background so the change is gapless) and the guards that keep a late result from landing in
/// the wrong place.
struct MusicGaplessState: Sendable, Equatable {
    /// The row that is loaded as the lookahead, if any.
    private(set) var primedID: UUID?
    /// Bumped on every explicit play, jump or invalidation. A prime that finishes after a bump discards itself.
    private(set) var generation = 0
    /// A prime that has started and not finished, per row, so two callers (the track start and an endless-playback top-up) do not both load it.
    private(set) var inFlight: UUID?

    enum Skip: Equatable, Sendable { case none, liveCurrent, liveNext, repeatOne, noNext }

    /// Why a lookahead must not be primed right now. Repeat-one loops the file itself; live broadcasts load by a normal start.
    static func skipReason(repeatMode: MusicRepeat, hasNext: Bool, currentIsLive: Bool, nextIsLive: Bool) -> Skip {
        if repeatMode == .one { return .repeatOne }
        if currentIsLive { return .liveCurrent }
        if !hasNext { return .noNext }
        if nextIsLive { return .liveNext }
        return .none
    }

    /// Starts a prime for `id`. Returns the generation to check later, or nil when that row is already primed or being primed.
    mutating func begin(for id: UUID) -> Int? {
        guard primedID != id, inFlight != id else { return nil }
        inFlight = id
        return generation
    }

    /// The race guard, evaluated just before the primed item is appended: the generation is unchanged, the slot still holds this row,
    /// and nothing else is primed. A duplicate entry would offset the engine's list from the queue pointer for the rest of the session.
    func canCommit(generation g: Int, id: UUID, nextRowID: UUID?) -> Bool {
        g == generation && nextRowID == id && primedID == nil
    }

    mutating func commit(_ id: UUID) { primedID = id; if inFlight == id { inFlight = nil } }

    /// A prime that ended without committing (failed, cancelled or discarded).
    mutating func abandon(_ id: UUID) { if inFlight == id { inFlight = nil } }

    /// Drops the primed row and any prime in flight.
    mutating func invalidate() { primedID = nil; inFlight = nil; generation += 1 }

    /// A new explicit load supersedes everything.
    mutating func bump() { generation += 1; inFlight = nil }

    /// Whether the queue's next row now differs from the primed one. Moves deeper in the queue never change it, so they never invalidate.
    func isStale(nextRowID: UUID?) -> Bool { primedID != nil && primedID != nextRowID }

    /// At a natural end of track: the advance is gapless only when the row the queue moves to is the primed one and the engine is not idle
    /// (an end of file can report not-idle for a moment, so both are checked).
    func isGaplessAdvance(nextRowID: UUID?, engineIdle: Bool) -> Bool {
        guard let p = primedID, let n = nextRowID else { return false }
        return p == n && !engineIdle
    }
}

/// Removal budget for one prime: a bad stretch of the queue cannot eat it whole.
struct MusicPrimeBudget: Sendable, Equatable {
    static let maxRemovals = 3
    private(set) var removed = 0
    var canRemoveAnother: Bool { removed < Self.maxRemovals }
    mutating func recordRemoval() { removed += 1 }
}

// MARK: failure ladder

/// Thrown when a track from the person's own disk is no longer there.
struct MusicLocalFileMissing: Error, Sendable { var title: String }

/// What a failure means for the queue.
enum MusicFailureKind: Equatable, Sendable {
    /// This track only (unavailable, region lock, dead link).
    case thisTrack
    /// Every track would fail the same way (offline, an account is needed for everything).
    case affectsEveryTrack
    /// The audio output vanished (sleep and wake, unplugged, driver restart). Not a bad stream.
    case deviceLost
    /// A local file that is gone.
    case missingLocalFile
    /// This track only, and it needs the person's own sign-in.
    case needsSignIn
    /// The source said "busy, retry later". The same track is tried again with growing waits and is never skipped.
    case throttled
    /// The source refuses this network. Nothing is skipped; the row waits in place.
    case networkRefused

    static func classify(_ error: Error) -> MusicFailureKind {
        if error is MusicLocalFileMissing { return .missingLocalFile }
        if let m = error as? MusicError {
            switch m {
            case .network: return .affectsEveryTrack
            case .rateLimited: return .throttled
            case .refused: return .thisTrack   // one refused request must not stall the queue: try the next candidate or row
            case .notSignedIn: return .needsSignIn
            default: return .thisTrack
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            let offline: Set<Int> = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed,
                                     NSURLErrorInternationalRoamingOff, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorTimedOut]
            return offline.contains(ns.code) ? .affectsEveryTrack : .thisTrack
        }
        if ns.domain == AVFoundationErrorDomain {
            let device: Set<Int> = [AVError.Code.deviceNotConnected.rawValue, AVError.Code.deviceWasDisconnected.rawValue]
            if device.contains(ns.code) { return .deviceLost }
        }
        return .thisTrack
    }
}

enum MusicFailureAction: Equatable, Sendable {
    /// Evict the cached stream URL and load this track once more, resuming where it was.
    case retry
    /// Move on to the next row with a transient note.
    case skip(String)
    /// Show the error and stay on this row. Nothing is skipped or deleted.
    case stay
    /// Stop the engine, keep the row and the position, show the device message, wait for the person.
    case holdForDevice
    /// Take the row out of the queue and go on.
    case removeRow(String)
    /// Tell the person and stop: the queue ends here.
    case stopWithError
    /// Several failures in a row: pause with this message instead of skipping on.
    case stopSeveral(String)
    /// The source is throttling: load the same track again after this many seconds. `announce` is true for the first refusal only.
    case waitAndRetry(TimeInterval, announce: Bool)
    /// Throttled too many times in a row: stay on the track and wait for play.
    case holdThrottled(String)
    /// The source refuses this network: stay on the track and say so.
    case holdNetworkRefused(String)
}

extension MusicFailureAction {
    /// A short name for the failure log.
    var logName: String {
        switch self {
        case .retry: return "retry with a fresh lookup"
        case .skip: return "skip to the next song"
        case .stay: return "stay and retry when online"
        case .holdForDevice: return "hold for the audio device"
        case .removeRow: return "remove the missing file"
        case .stopWithError: return "stop (end of queue)"
        case .stopSeveral: return "stop (several in a row)"
        case .waitAndRetry(let s, _): return "wait \(Int(s)) s and retry (source busy)"
        case .holdThrottled: return "hold (source busy)"
        case .holdNetworkRefused: return "hold (network refused)"
        }
    }
}

enum MusicPlaybackMessages {
    static let deviceLost = "Your audio device is unavailable. Press play once it's back."
    static let throttledFirst = "The music source is busy. Trying the same song again shortly."
    static let throttledHold = "The music source is still busy. Press play to try again."
    static let networkRefused = "This music source does not accept this network. Press play to try again, or change the source in Music settings."
    static func skipped(_ kind: MusicFailureKind, title: String) -> String {
        Localized.string(kind == .needsSignIn ? "Skipped (sign-in needed): %@" : "Skipped (unavailable): %@", title)
    }
    static func missingFile(_ title: String) -> String { Localized.string("%@ is no longer on your disk", title) }
    static func skippedWithReason(title: String, reason: String) -> String {
        let plain = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
        return Localized.string("Couldn't play %1$@: %2$@. Skipping to the next song.", title, plain)
    }
    /// A plain sentence for why a song did not start, from whatever the resolver or the player reported.
    static func reason(error: Error?, message: String, title: String) -> String {
        if let m = error as? MusicError {
            switch m {
            case .noPlayableSource(let detail):
                // The resolver appends a plain reason (private, removed, region-locked) after the title.
                if detail.count > title.count, detail.hasPrefix(title) {
                    let plain = detail.dropFirst(title.count).drop { $0 == "." || $0 == " " }
                    if !plain.isEmpty { return Localized.string(String(plain)) }
                }
                return Localized.string("This song could not be played from any source right now.")
            case .network(let s): return "The music source did not answer (\(s))"
            case .notSignedIn: return "This source needs a sign-in"
            case .rateLimited: return "The music source is busy"
            default: break
            }
        }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("Cannot Open") || text.contains("-11828") { return "This audio format cannot be played" }
        return text.isEmpty ? "The stream would not start" : text
    }
}

/// One retry per play of a track, then skip. The marker is cleared on every queue pointer move, so a track retried in the morning gets
/// a retry again tonight. After `maxConsecutiveFailures` failed songs in a row the queue stops instead of skipping on: whatever is wrong
/// (connection, sources) is not about one song.
struct MusicFailureLadder: Sendable, Equatable {
    static let maxConsecutiveFailures = 4
    static let severalInARow = "Several songs in a row could not be played: check your connection or sources"
    private(set) var retried: Set<UUID> = []
    private(set) var consecutive = 0
    /// Waits for a source that said "retry later". Separate from the counters above: a throttled track is never skipped or counted as failed.
    private(set) var throttle = MusicThrottleLadder()

    mutating func pointerMoved() { retried = []; throttle.reset() }

    /// A song started playing: the run of failures is over.
    mutating func playbackStarted() { consecutive = 0; throttle.reset() }

    /// The person pressed play on a held track: the throttle count starts again.
    mutating func userRetried() { throttle.reset() }

    /// What to do about a failure on `row`. `atTail` is true when no row follows and nothing playable is left to wrap to (under repeat-all the
    /// caller passes false while another playable row exists, see `MusicWrapRule`; the run-of-failures stop below ends any spin). `resolveFailure` is true for "could not get a stream" and false for "the
    /// engine failed the stream mid-play". `permanent` marks a verdict that will not change (private, removed, region-locked): no retry.
    mutating func decide(_ kind: MusicFailureKind, row: UUID, title: String, resolveFailure: Bool, atTail: Bool, permanent: Bool = false,
                         retryAfter: TimeInterval? = nil) -> MusicFailureAction {
        switch kind {
        case .deviceLost: return .holdForDevice
        case .throttled:
            switch throttle.refused(retryAfter: retryAfter) {
            case .wait(let s, let announce): return .waitAndRetry(s, announce: announce)
            case .hold: return .holdThrottled(Localized.string(MusicPlaybackMessages.throttledHold))
            }
        case .networkRefused: return .holdNetworkRefused(Localized.string(MusicPlaybackMessages.networkRefused))
        case .affectsEveryTrack: return .stay
        case .missingLocalFile: return .removeRow(MusicPlaybackMessages.missingFile(title))
        case .thisTrack, .needsSignIn:
            // One fresh try per play, for a failed resolve as well: a flaky provider often answers the second time.
            if !permanent, !retried.contains(row) { retried.insert(row); return .retry }
            consecutive += 1
            if consecutive >= Self.maxConsecutiveFailures { consecutive = 0; return .stopSeveral(Self.severalInARow) }
            return atTail ? .stopWithError : .skip(MusicPlaybackMessages.skipped(kind, title: title))
        }
    }
}

/// The red-triangle markers on queue and list rows: which songs could not be started, why, and until when. A marker expires with its verdict,
/// goes the moment the song plays or the person presses play on it, and the table never holds more than `capacity` rows.
struct MusicFailureMarks: Sendable, Equatable {
    static let capacity = 200
    struct Entry: Sendable, Equatable { var text: String; var until: Date }
    private(set) var entries: [String: Entry] = [:]

    mutating func mark(_ uid: String, reason: String, now: Date = Date(), lifetime: TimeInterval = MusicUnplayableMemory.memory) {
        prune(now: now)
        entries[uid] = Entry(text: reason, until: now.addingTimeInterval(lifetime))
        if entries.count > Self.capacity, let oldest = entries.min(by: { $0.value.until < $1.value.until })?.key { entries[oldest] = nil }
    }

    /// The reason to show on a marked row, or nil when it was never marked, was cleared, or the mark has run out.
    func reason(for uid: String, now: Date = Date()) -> String? {
        guard let e = entries[uid], e.until > now else { return nil }
        return e.text
    }

    mutating func clear(_ uid: String) { entries[uid] = nil }
    mutating func prune(now: Date = Date()) { entries = entries.filter { $0.value.until > now } }
    var uids: Set<String> { Set(entries.keys) }
}

/// A song whose rest-of-stream check failed after it started is swapped to another address at most once per queue row, so a song with no good
/// address can never loop. The table is bounded.
struct MusicLateSwapGate: Sendable, Equatable {
    static let capacity = 50
    private(set) var swapped: [String: UUID] = [:]

    /// True the first time for this row of this song; false for every later late rejection of it.
    mutating func allow(uid: String, row: UUID) -> Bool {
        if swapped[uid] == row { return false }
        if swapped.count >= Self.capacity { swapped = [:] }
        swapped[uid] = row
        return true
    }
}

/// Retry timing after a load failed for lack of a network: 2, 4, 8, 15 and then 30 s, up to ten tries. A quiet five minutes resets the
/// ladder. One ladder is shared by every caller.
struct MusicOfflineLadder: Sendable, Equatable {
    static let delays: [TimeInterval] = [2, 4, 8, 15, 30, 30, 30, 30, 30, 30]
    static let resetAfter: TimeInterval = 300
    private(set) var step = 0
    private(set) var lastTrigger: Date?

    /// The wait before the next automatic try, or nil when the ladder is spent (focus and coming back online still trigger a try).
    mutating func nextDelay(now: Date = Date()) -> TimeInterval? {
        if let l = lastTrigger, now.timeIntervalSince(l) > Self.resetAfter { step = 0 }
        lastTrigger = now
        guard step < Self.delays.count else { return nil }
        defer { step += 1 }
        return Self.delays[step]
    }

    mutating func reset() { step = 0; lastTrigger = nil }
}
