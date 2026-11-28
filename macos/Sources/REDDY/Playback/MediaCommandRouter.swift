import Foundation
import MediaPlayer

// ONE registration with the system's remote command centre (media keys, Control Centre, lock screen, AirPods). The library player and Podcasts
// no longer add their own targets: each conforms to `RemoteCommandHandling` and registers with the router. The router sends a command to the CURRENT
// AUDIO OWNER only (`AudioOwnership.owner`), enables exactly the commands that owner supports, and accepts Now Playing information from the owner only.
// Enabled-state is event driven: it is recomputed when the owner changes and when the owner says its support changed (`supportChanged`), never on a timer.

enum RemoteCommandKind: CaseIterable, Hashable, Sendable { case play, pause, toggle, next, previous, skipForward, skipBackward, seek }

enum RemoteCommandResult: Equatable, Sendable { case success, failed, noActionable }

struct RemoteCommandEvent: Equatable, Sendable {
    var kind: RemoteCommandKind
    /// For `.seek`: the position asked for.
    var position: TimeInterval?
    /// For skips: the interval the system asked for.
    var interval: TimeInterval?
}

/// Which commands an owner answers, and its skip intervals.
struct RemoteCommandSupport: Equatable, Sendable {
    var enabled: Set<RemoteCommandKind> = []
    var skipForward = 15
    var skipBackward = 15
    static let none = RemoteCommandSupport()
    static let basic = RemoteCommandSupport(enabled: [.play, .pause, .toggle])
}

/// What an owner (the library player, Podcasts) offers the router.
@MainActor protocol RemoteCommandHandling: AnyObject {
    /// What it answers right now. Read when the owner changes or when it calls `router.supportChanged(for:)`; not polled.
    var remoteSupport: RemoteCommandSupport { get }
    func handleRemote(_ event: RemoteCommandEvent) -> RemoteCommandResult
    /// It became the owner (publish Now Playing again) or stopped being it (the router has already cleared what it published).
    func remoteOwnershipChanged(isOwner: Bool)
}
extension RemoteCommandHandling { func remoteOwnershipChanged(isOwner: Bool) {} }

/// The part of the system the router talks to, so a test can count registrations.
@MainActor protocol CommandCenterSurface: AnyObject {
    /// Adds exactly one target per command. Idempotent.
    func install(_ handler: @escaping @MainActor (RemoteCommandEvent) -> RemoteCommandResult)
    /// Removes exactly the targets `install` added.
    func uninstall()
    func apply(_ support: RemoteCommandSupport)
    func publish(_ info: [String: Any], playing: Bool)
    func clearNowPlaying()
    var installedTargets: Int { get }
}

@MainActor final class SystemCommandCenterSurface: CommandCenterSurface {
    private var targets: [(command: MPRemoteCommand, token: Any)] = []
    var installedTargets: Int { targets.count }

    private func commands() -> [(RemoteCommandKind, MPRemoteCommand)] {
        let r = MPRemoteCommandCenter.shared()
        return [(.play, r.playCommand), (.pause, r.pauseCommand), (.toggle, r.togglePlayPauseCommand), (.next, r.nextTrackCommand), (.previous, r.previousTrackCommand),
                (.skipForward, r.skipForwardCommand), (.skipBackward, r.skipBackwardCommand), (.seek, r.changePlaybackPositionCommand)]
    }

    func install(_ handler: @escaping @MainActor (RemoteCommandEvent) -> RemoteCommandResult) {
        guard targets.isEmpty else { return }
        for (kind, command) in commands() {
            let token = command.addTarget { event in
                let e = RemoteCommandEvent(kind: kind, position: (event as? MPChangePlaybackPositionCommandEvent)?.positionTime, interval: (event as? MPSkipIntervalCommandEvent)?.interval)
                let result = MainActor.assumeIsolated { handler(e) }
                switch result { case .success: return .success; case .failed: return .commandFailed; case .noActionable: return .noActionableNowPlayingItem }
            }
            targets.append((command, token))
        }
    }

    func uninstall() {
        for t in targets { t.command.removeTarget(t.token) }
        targets = []
        apply(.none)
    }

    func apply(_ s: RemoteCommandSupport) {
        for (kind, command) in commands() { command.isEnabled = s.enabled.contains(kind) }
        let r = MPRemoteCommandCenter.shared()
        r.skipForwardCommand.preferredIntervals = [NSNumber(value: s.skipForward)]
        r.skipBackwardCommand.preferredIntervals = [NSNumber(value: s.skipBackward)]
    }

    func publish(_ info: [String: Any], playing: Bool) {
        let c = MPNowPlayingInfoCenter.default()
        c.nowPlayingInfo = info
        c.playbackState = playing ? .playing : .paused
    }

    func clearNowPlaying() {
        let c = MPNowPlayingInfoCenter.default()
        c.nowPlayingInfo = nil; c.playbackState = .stopped
    }
}

@MainActor final class MediaCommandRouter {
    /// The app's router: the system command centre and the app's one `AudioOwnership`.
    static let shared = MediaCommandRouter(surface: SystemCommandCenterSurface(), ownership: .shared)

    private struct Weak { weak var value: (any RemoteCommandHandling)? }
    private let surface: CommandCenterSurface
    let ownership: AudioOwnership
    private var handlers: [MediaSource: Weak] = [:]
    private var applied: RemoteCommandSupport?
    private(set) var publishedBy: MediaSource?
    private var lastOwner: MediaSource?
    private var installed = false

    init(surface: CommandCenterSurface, ownership: AudioOwnership) {
        self.surface = surface; self.ownership = ownership
        lastOwner = ownership.owner
        ownership.addObserver { [weak self] _ in self?.ownerChanged() }
    }

    /// Registers an owner-capable player once. The system registration happens at the first call, and only once.
    func register(_ handler: any RemoteCommandHandling, for source: MediaSource) {
        handlers[source] = Weak(value: handler)
        if !installed { installed = true; surface.install { [weak self] e in self?.dispatch(e) ?? .noActionable } }
        refreshSupport()
    }

    func unregister(_ source: MediaSource) {
        handlers[source] = nil
        clearNowPlaying(from: source)
        refreshSupport()
    }

    /// Removes the system targets (shutdown, tests). A later `register` installs again.
    func shutdown() { surface.uninstall(); installed = false; applied = nil; publishedBy = nil }

    private var ownerHandler: (any RemoteCommandHandling)? { ownership.owner.flatMap { handlers[$0]?.value } }

    /// The owner's support changed (a next track appeared, a skip interval changed). Ignored from anyone else.
    func supportChanged(for source: MediaSource) {
        guard ownership.owner == source else { return }
        refreshSupport()
    }

    /// Routes a command to the owner only. With no owner, or an owner that has no handler (an embedded service answers for itself), nothing is actionable.
    func dispatch(_ event: RemoteCommandEvent) -> RemoteCommandResult {
        guard let h = ownerHandler else { return .noActionable }
        guard h.remoteSupport.enabled.contains(event.kind) else { return .noActionable }
        return h.handleRemote(event)
    }

    /// Now Playing information: accepted from the current owner only (returns false otherwise, and nothing is published).
    @discardableResult func publish(_ info: [String: Any], playing: Bool, from source: MediaSource) -> Bool {
        guard ownership.owner == source else { return false }
        surface.publish(info, playing: playing)
        publishedBy = source
        return true
    }

    /// Clears what `source` published (and only that).
    func clearNowPlaying(from source: MediaSource) {
        guard publishedBy == source else { return }
        surface.clearNowPlaying(); publishedBy = nil
    }

    /// The owner stopped for good (the player closed, the item ended): it no longer owns the audio, its Now Playing goes and the commands are disabled.
    func ownerStopped(_ source: MediaSource) {
        clearNowPlaying(from: source)
        ownership.release(source, reason: .stopped)
    }

    private func ownerChanged() {
        let now = ownership.owner
        if let p = publishedBy, p != now { surface.clearNowPlaying(); publishedBy = nil }          // a stale Now Playing never outlives its owner
        if lastOwner != now {
            let old = lastOwner; lastOwner = now
            if let old { handlers[old]?.value?.remoteOwnershipChanged(isOwner: false) }
            if let now { handlers[now]?.value?.remoteOwnershipChanged(isOwner: true) }
        }
        refreshSupport()
    }

    private func refreshSupport() {
        let s = ownerHandler?.remoteSupport ?? .none
        guard s != applied else { return }
        applied = s
        surface.apply(s)
    }
}
