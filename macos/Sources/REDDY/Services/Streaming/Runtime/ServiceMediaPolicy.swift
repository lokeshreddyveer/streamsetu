import Foundation
import Observation

/// Where media can start from. A service keeps playing when it is hidden; it stops only when something else starts.
enum MediaSource: Hashable, Sendable {
    case service(ProviderID)
    case nativePlayer
    case podcasts
    case music

    /// Short, privacy-safe code for diagnostics (never a title, address or account).
    var code: String {
        switch self {
        case .service: "service"
        case .nativePlayer: "native"
        case .podcasts: "podcasts"
        case .music: "music"
        }
    }
}

/// Why media must stop although nothing else started. `signedOut`, `dataCleared`, `disabled`, `removed` and `accessRevoked` concern one service; the others every service.
enum MediaSafetyStop: Hashable, Sendable {
    case kidsProfile, locked, blocked, signedOut
    case profileSwitched, dataCleared, disabled, removed, accessRevoked

    var code: String {
        switch self {
        case .kidsProfile: "kids"; case .locked: "locked"; case .blocked: "blocked"; case .signedOut: "signed-out"
        case .profileSwitched: "profile"; case .dataCleared: "data-cleared"; case .disabled: "disabled"; case .removed: "removed"; case .accessRevoked: "revoked"
        }
    }
}

/// What a rule asks for: which services to pause, and which native participants pause too.
struct MediaStopPlan: Equatable, Sendable {
    enum Services: Equatable, Sendable { case none, all, allExcept(ProviderID) }
    var services: Services = .none
    var pausesPodcast = false
    var pausesMusic = false
    var pausesNativePlayer = false
    static let nothing = MediaStopPlan()
    var isEmpty: Bool { self == .nothing }

    /// Whether the plan pauses this participant.
    func pauses(_ source: MediaSource) -> Bool {
        switch source {
        case .service(let id):
            switch services { case .none: false; case .all: true; case .allExcept(let keep): keep != id }
        case .nativePlayer: pausesNativePlayer
        case .podcasts: pausesPodcast
        case .music: pausesMusic
        }
    }
}

/// The single owner of the "media stops only when something else starts" policy. Pure: no WebKit, no view. `AudioOwnership` runs it.
///
/// - anything that really starts playing (the native player, Podcasts, or a service that is seen playing) pauses every other participant;
/// - NAVIGATION NEVER CLAIMS: opening a service, switching tabs, searching or opening the Podcasts screen changes nothing about who owns the audio.
///   Entering a service pauses only the native video player (its picture is replaced); that is not a claim and leaves the owner as it was;
/// - a Kids profile, the lock, a blocked state, a profile switch, signing out, clearing data, or a service that is disabled, removed or revoked stop what they concern.
enum ServiceMediaPolicy {
    /// Something started playing: what else must stop. A source never stops itself.
    static func otherMediaStarted(from source: MediaSource) -> MediaStopPlan {
        // Changed: every claim pauses every other participant (a service playing now also pauses the native player).
        var plan = MediaStopPlan(services: .all, pausesPodcast: true, pausesMusic: true, pausesNativePlayer: true)
        switch source {
        case .service(let id): plan.services = .allExcept(id)
        case .nativePlayer: plan.pausesNativePlayer = false
        case .podcasts: plan.pausesPodcast = false
        case .music: plan.pausesMusic = false
        }
        return plan
    }

    /// The person moved to another destination (a service, a native tab, Podcasts, a search). Only the native video player yields to a service; nothing is claimed.
    static func navigation(from: ProviderID?, to: ProviderID?) -> MediaStopPlan {
        guard let to, to != from else { return .nothing }
        return MediaStopPlan(pausesNativePlayer: true)
    }

    /// A restriction came on: everything the services play stops.
    static func safety(_ reason: MediaSafetyStop) -> MediaStopPlan { MediaStopPlan(services: .all) }

    /// Typing in the top search returns to StreamSetu's own results; a playing service is not stopped by that.
    static func searchStarted() -> MediaStopPlan { .nothing }
}

// MARK: - participants

/// Anything that can make sound and must be silenced when something else takes the audio. The native video player and Podcasts conform
/// (or use `ClosureAudioParticipant`); every embedded service is registered by the host registry.
@MainActor protocol AudioParticipant: AnyObject {
    var audioID: MediaSource { get }
    /// True while it makes (or is about to make) sound. Used for settling checks and the faster poll; a claim pauses every other participant regardless.
    var isPlaying: Bool { get }
    func pause()
    /// Called when `claimant` took the audio. The default pauses; the native player stops instead for Podcasts (as before).
    func yieldAudio(to claimant: MediaSource)
    /// False when this participant may not resume by itself (Kids profile, lock). Nothing resumes by itself today.
    var resumeAllowed: Bool { get }
}
extension AudioParticipant {
    func yieldAudio(to claimant: MediaSource) { pause() }
    var resumeAllowed: Bool { true }
}

@MainActor final class ClosureAudioParticipant: AudioParticipant {
    let audioID: MediaSource
    private let playing: () -> Bool
    private let pauser: () -> Void
    private let yielder: ((MediaSource) -> Void)?
    init(_ id: MediaSource, isPlaying: @escaping () -> Bool, pause: @escaping () -> Void, yieldAudio: ((MediaSource) -> Void)? = nil) {
        audioID = id; playing = isPlaying; pauser = pause; yielder = yieldAudio
    }
    var isPlaying: Bool { playing() }
    func pause() { pauser() }
    func yieldAudio(to claimant: MediaSource) { if let yielder { yielder(claimant) } else { pauser() } }
}

/// Why ownership changed (codes only; they are what Diagnostics counts).
enum OwnershipReason: String, Sendable {
    case nativePlay = "native-play", podcastPlay = "podcast-play", musicPlay = "music-play"
    case servicePlaySeen = "service-play-seen", hiddenAutoplay = "hidden-autoplay"
    case stopped, terminated, safety, unregistered, other
}

struct OwnershipChange: Equatable, Sendable {
    var owner: MediaSource?
    var generation: UInt64
    var reason: OwnershipReason
}

/// In-memory counters of reason codes: parked views, web process terminations and ownership changes. Never a title, address, account or path.
@MainActor final class MediaDiagnostics {
    static let shared = MediaDiagnostics()
    private(set) var counts: [String: Int] = [:]
    /// Web views parked right now.
    private(set) var parkedNow = 0
    func count(_ code: String) { counts[code, default: 0] += 1 }
    func parked(_ delta: Int) { parkedNow = max(0, parkedNow + delta); count(delta > 0 ? "parked.added" : "parked.removed") }
    /// "code: count" lines, sorted, for a diagnostics report.
    var lines: [String] { counts.sorted { $0.key < $1.key }.map { entry in "\(entry.key): \(entry.1)" } + ["parked.now: \(parkedNow)"] }
    func reset() { counts = [:]; parkedNow = 0 }
}

// MARK: - the coordinator

/// THE one authority on who owns the audio. Small and pure: no WebKit, no view, no timer.
///
/// - `claim` is synchronous: when it returns, every other participant has already been told to pause. Native participants (the video player, Podcasts)
///   call it BEFORE they start their audio; none of them relies on polling.
/// - Embedded services are the exception and the limit: WebKit's public API offers no "started playing" event, only `requestMediaPlaybackState`,
///   which is polled (see `ServiceMediaMonitor`). A page can therefore start between two observations and briefly overlap with another source; the claim
///   that follows a detection pauses the others, and ownership is correct from then on. Polling is best effort, never complete detection.
/// - Every change bumps a monotonic `generation`. An asynchronous observation carries the generation that was current when it was requested and is
///   dropped when ownership has changed since (`observedAt:`), so a late "playing" from an old owner can never pause the newest one.
/// - Claiming again as the current owner is idempotent: no new generation and the owner is not paused.
@MainActor @Observable final class AudioOwnership {
    static let shared = AudioOwnership()

    private(set) var owner: MediaSource?
    private(set) var generation: UInt64 = 0
    @ObservationIgnored private var participants: [MediaSource: any AudioParticipant] = [:]
    @ObservationIgnored private var observers: [Int: (OwnershipChange) -> Void] = [:]
    @ObservationIgnored private var nextObserver = 0
    @ObservationIgnored var diagnostics: MediaDiagnostics = .shared
    /// Observations and claims that were ignored because they were stale (for tests and diagnostics).
    @ObservationIgnored private(set) var staleIgnored = 0

    init() {}

    func register(_ p: any AudioParticipant) { participants[p.audioID] = p }
    func unregister(_ id: MediaSource) {
        participants[id] = nil
        release(id, reason: .unregistered)
    }
    func participant(_ id: MediaSource) -> (any AudioParticipant)? { participants[id] }
    var registered: [MediaSource] { Array(participants.keys) }

    /// Called after every change of owner or generation. Returns a token for `removeObserver`.
    @discardableResult func addObserver(_ f: @escaping (OwnershipChange) -> Void) -> Int {
        nextObserver += 1; observers[nextObserver] = f; return nextObserver
    }
    func removeObserver(_ token: Int) { observers[token] = nil }

    /// Participants that report playing right now.
    var playing: [MediaSource] { participants.values.filter(\.isPlaying).map(\.audioID) }
    func isAnyPlaying(except source: MediaSource? = nil) -> Bool { participants.values.contains { $0.isPlaying && $0.audioID != source } }

    /// `source` starts (or is seen) playing. Pauses every other participant before returning. `observedAt` is the generation current when the
    /// observation was requested; a different one means the owner changed since, and the claim is dropped (returns nil).
    @discardableResult func claim(_ source: MediaSource, reason: OwnershipReason, observedAt: UInt64? = nil) -> UInt64? {
        if let observedAt, observedAt != generation { staleIgnored += 1; diagnostics.count("ownership.stale"); return nil }
        let plan = ServiceMediaPolicy.otherMediaStarted(from: source)
        if owner == source {
            // Idempotent: same owner, same generation, itself never paused. Others that started in the meantime are still silenced.
            for p in Array(participants.values) where p.audioID != source && p.isPlaying && plan.pauses(p.audioID) { p.yieldAudio(to: source) }
            return generation
        }
        generation &+= 1
        owner = source
        diagnostics.count("ownership.\(reason.rawValue)")
        for p in Array(participants.values) where p.audioID != source && plan.pauses(p.audioID) { p.yieldAudio(to: source) }
        notify(reason)
        return generation
    }

    /// The owner stopped (closed, ended, process gone). Ignored when `source` is not the owner or `generation` is old.
    @discardableResult func release(_ source: MediaSource, generation g: UInt64? = nil, reason: OwnershipReason = .stopped) -> Bool {
        guard owner == source else { return false }
        if let g, g != generation { staleIgnored += 1; return false }
        owner = nil; generation &+= 1
        diagnostics.count("ownership.release.\(reason.rawValue)")
        notify(reason)
        return true
    }

    /// Nobody owns the audio (a safety stop). Participants are not touched here; the caller pauses them.
    func releaseAll(reason: OwnershipReason = .safety) {
        guard owner != nil else { return }
        owner = nil; generation &+= 1
        notify(reason)
    }

    private func notify(_ reason: OwnershipReason) {
        let c = OwnershipChange(owner: owner, generation: generation, reason: reason)
        for f in Array(observers.values) { f(c) }
    }
}
