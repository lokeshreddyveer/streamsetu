import AVFoundation

/// The player settings that trade a little stall safety for a quicker first sound, used only for the first seconds of a song. Once the song
/// has played for `relaxAfter` seconds the normal settings come back, so a slow link is protected for the rest of the song.
enum MusicFastStart {
    /// How much sound the player may collect ahead of the playhead while the song is starting.
    static let startBufferSeconds: TimeInterval = 3
    /// Seconds of played sound after which the start settings are lifted.
    static let relaxAfter: TimeInterval = 4

    /// Start settings: begin as soon as the item can play, and keep only a short lead.
    static func apply(item: AVPlayerItem, player: AVPlayer) {
        player.automaticallyWaitsToMinimizeStalling = false
        item.preferredForwardBufferDuration = startBufferSeconds
    }

    /// Normal settings: the system decides how much to buffer and when to wait.
    static func relax(item: AVPlayerItem?, player: AVPlayer) {
        player.automaticallyWaitsToMinimizeStalling = true
        item?.preferredForwardBufferDuration = 0
    }

    /// True when the start settings should be lifted: the song has played long enough, or it is already stalling.
    static func shouldRelax(playedSeconds: TimeInterval, isWaiting: Bool) -> Bool { playedSeconds >= relaxAfter || (isWaiting && playedSeconds > 0.5) }
}
