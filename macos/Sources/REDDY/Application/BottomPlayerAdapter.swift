import Foundation

/// Maps the playback session onto what the bottom bar shows. The bar only ever describes the item that is *playing*.
@MainActor
enum BottomPlayerAdapter {
    static func state(_ p: PlaybackCoordinator, program: EPGProgram?) -> BottomPlayerState? {
        guard let req = p.current else { return nil }
        let live = req.isLive
        let status: String
        var failed = false
        switch p.state {
        case .idle, .ended: status = live ? "Stopped" : "Ended"
        case .resolving, .preparing: status = "Loading…"
        case .buffering: status = "Buffering…"
        case .seeking: status = "Seeking…"
        case .recovering: status = "Reconnecting…"
        case .playing: status = live ? "Live" : "Playing"
        case .paused: status = "Paused"
        case .failed(let e): status = e.message; failed = true
        }
        var meta = p.subtitle ?? ""
        if live, let program { meta = program.title }
        return BottomPlayerState(
            title: req.title, meta: meta, status: status,
            artworkURL: req.artworkURL, isLive: live,
            isPlaying: p.state.isPlaying, isBusy: p.state.isBusy, failed: failed,
            position: p.position, duration: live ? nil : p.duration,
            volume: p.volume, muted: p.isMuted)
    }
}
