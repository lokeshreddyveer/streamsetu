import AVFoundation

/// Turns AVFoundation's KVO and notifications into plain events for the engine.
@MainActor
final class AVPlayerObserver {
    enum Event {
        case ready
        case failed(Error)
        case timeControl(AVPlayer.TimeControlStatus)
        case stalled
        case reachedEnd
        case tick
    }

    private var observations: [NSKeyValueObservation] = []
    private var tokens: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private weak var player: AVPlayer?

    init(player: AVPlayer, item: AVPlayerItem, handler: @escaping @MainActor (Event) -> Void) {
        self.player = player
        observations.append(item.observe(\.status, options: [.initial, .new]) { item, _ in
            let status = item.status, err = item.error
            Task { @MainActor in
                if status == .readyToPlay { handler(.ready) }
                else if status == .failed { handler(.failed(err ?? PlaybackError(.unknown))) }
            }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { p, _ in
            let s = p.timeControlStatus
            Task { @MainActor in handler(.timeControl(s)) }
        })
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { _ in
            Task { @MainActor in handler(.reachedEnd) }
        })
        tokens.append(nc.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { n in
            let err = n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in handler(.failed(err ?? PlaybackError(.unknown))) }
        })
        tokens.append(nc.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { _ in
            Task { @MainActor in handler(.stalled) }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { _ in
            Task { @MainActor in handler(.tick) }
        }
    }

    func invalidate() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens.removeAll()
        if let t = timeObserver { player?.removeTimeObserver(t); timeObserver = nil }
    }

    deinit { /* invalidate() must be called explicitly on the main actor */ }
}
