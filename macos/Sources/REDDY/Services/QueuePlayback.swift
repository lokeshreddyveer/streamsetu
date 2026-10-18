import Foundation

extension AppContainer {
    /// Starts a title taken from the queue: a movie plays; a series plays the episode that would be watched next (or the first one).
    /// [problem] is told when a series has no episodes to play.
    @MainActor func play(queued item: LibraryItem, problem: @escaping @MainActor (String) -> Void) {
        switch item {
        case .movie(let m):
            playback.play(movie: m)
            #if os(iOS)
            playback.isExpanded = true
            #endif
        case .series(let s):
            Task { @MainActor in
                do {
                    let detail = try await details.series(id: s.id)
                    let target = await Task.detached { [history] in try? history.resumeTarget(seriesID: s.id) }.value ?? detail.episodes.first
                    guard let episode = target else { problem("No episodes are available for \(s.title) yet."); return }
                    playback.play(episode: episode, series: detail.series)
                    #if os(iOS)
                    playback.isExpanded = true
                    #endif
                } catch { problem("Couldn't load episodes for \(s.title).") }
            }
        }
    }
}
