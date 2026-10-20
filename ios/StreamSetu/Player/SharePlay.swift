import Foundation
import AVFoundation
import GroupActivities
import Observation

/// What is shared in a SharePlay session: a film or a live channel, named by a streamsetu:// link that each person's own app opens from their own playlist.
struct WatchTogether: GroupActivity {
    var title: String
    var link: URL

    var metadata: GroupActivityMetadata {
        var m = GroupActivityMetadata()
        m.title = title
        m.type = .watchTogether
        return m
    }
}

/// Watching together over FaceTime: one person starts it from the player, the others' apps open the same title from their own playlist, and the system keeps every player at the same
/// place (play, pause and seeking are shared). It works with the system player (AVPlayer); a film that needs the MPV engine cannot be shared.
@MainActor @Observable
final class SharePlayService {
    static let shared = SharePlayService()
    private(set) var active = false
    private var session: GroupSession<WatchTogether>?
    private var tasks: [Task<Void, Never>] = []
    private weak var container: AppContainer?
    private var starting = false

    /// Listens for sessions other people start. Call once the app has started.
    func listen(_ c: AppContainer, open: @escaping @MainActor (URL) -> Void) {
        container = c
        tasks.append(Task { [weak self] in
            for await s in WatchTogether.sessions() { self?.join(s, open: open) }
        })
    }

    /// What the player on screen can share: a film or a live channel from a playlist, with the system player.
    func shareable(_ c: AppContainer) -> (title: String, link: URL)? {
        guard let r = c.playback.current, c.playback.activeAVPlayer != nil, r.sourceID != LocalMedia.sourceID else { return nil }
        switch r.kind {
        case .movie: return DeepLink.link(movie: r.title).map { (r.title, $0) }
        case .channel where r.isLive: return DeepLink.link(channel: r.title).map { (r.title, $0) }
        default: return nil
        }
    }

    /// Starts a session for what is playing. The system asks who to share with when there is no FaceTime call yet.
    func start(_ c: AppContainer) async {
        guard let item = shareable(c) else { return }
        let activity = WatchTogether(title: item.title, link: item.link)
        starting = true
        defer { starting = false }
        switch await activity.prepareForActivation() {
        case .activationPreferred: _ = try? await activity.activate()
        default: break
        }
    }

    /// Starts a session once the film or channel that was just opened is playing with the system player (it can take a few seconds to begin).
    func startWhenReady(_ c: AppContainer) {
        Task { [weak self] in
            for _ in 0..<40 {
                if self?.shareable(c) != nil, c.playback.state.isPlaying { await self?.start(c); return }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func join(_ s: GroupSession<WatchTogether>, open: @escaping @MainActor (URL) -> Void) {
        session = s
        s.join()
        active = true
        // The person who started it is already playing; everyone else opens the same title.
        if !starting { open(s.activity.link) }
        tasks.append(Task { [weak self] in
            for _ in 0..<90 {
                if Task.isCancelled { return }
                if let player = self?.container?.playback.activeAVPlayer, player.currentItem != nil { player.playbackCoordinator.coordinateWithSession(s); return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        })
        tasks.append(Task { [weak self] in
            for await state in s.$state.values {
                if case .invalidated = state { self?.active = false; self?.session = nil; return }
            }
        })
    }

    func leave() { session?.leave(); active = false; session = nil }
}
