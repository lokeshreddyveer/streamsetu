import Foundation

// Lets the host drive the real player. Only existing public members are used; nothing here reads streams, files or tokens.

extension MusicPlayer: MusicRemoteControllable {
    func remoteSnapshot() -> MusicRemoteState {
        let ahead: [String]
        if let i = index, i + 1 < queue.count {
            ahead = queue[(i + 1)...].prefix(MusicRemoteLimits.upNextCount).map { $0.title }
        } else { ahead = [] }
        guard let t = current else {
            var s = MusicRemoteState.idle
            s.volume = Double(volume); s.queueCount = queue.count
            return s
        }
        return MusicRemoteState(
            hasTrack: true, title: t.title, artist: t.artistLine,
            artworkURL: MusicRemoteSanitizer.artworkURL(t.thumbnails.best(minSide: 300)),
            position: position, duration: duration > 0 ? duration : t.duration, isPlaying: isPlaying,
            volume: Double(volume), queueCount: queue.count, queueIndex: index, upNext: ahead).sanitized()
    }

    func remotePlay() { resume() }
    func remotePause() { pause() }
    func remoteNext() { next() }
    func remotePrevious() { previous() }
    func remoteSeek(to seconds: TimeInterval) { seek(to: seconds) }
    func remoteSetVolume(_ v: Float) { volume = v }
    func remotePlayQueue(_ tracks: [MusicTrack], startAt: Int) { play(tracks, startAt: startAt) }
}

extension MusicHub {
    /// The devices feature for this hub. Created on first use; it advertises and listens only when the person has turned it on.
    var devices: MusicDevices { MusicDevices.shared(player: player) }
}
