import Foundation

/// The recommender's view of the play history, kept incrementally and off the main actor: the main actor hands over the history array (shared, not
/// copied), this actor converts only the rows that are new since the last read.
actor MusicHistoryMirrorBox {
    private var mirror = MusicHistoryMirror<PlayRecord, MusicHistoryPlay>()
    func plays(_ history: [PlayRecord]) -> [MusicHistoryPlay] {
        mirror.update(history) { MusicHistoryPlay(providerUID: $0.track.uid, at: $0.at, playedMs: $0.playedMs, durationMs: $0.track.durationMs) }
    }
    func reset() { mirror = MusicHistoryMirror() }
}
