import Foundation

@MainActor
struct StartPlaybackUseCase {
    let playback: PlaybackCoordinator
    func channel(_ c: Channel, in list: [Channel]) { playback.play(channel: c, queue: list) }
    func movie(_ m: Movie, resume: Bool = true) { playback.play(movie: m, resume: resume) }
    func episode(_ e: Episode, of s: Series, resume: Bool = true) { playback.play(episode: e, series: s, resume: resume) }
}
