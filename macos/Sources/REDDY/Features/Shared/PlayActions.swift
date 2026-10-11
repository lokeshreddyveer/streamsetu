import Foundation

/// Starting playback from a card. Movies play directly; a series resumes (or starts) the right episode.
@MainActor
struct PlayActions {
    let container: AppContainer
    let toasts: ToastCenter

    func play(_ item: LibraryItem) {
        switch item {
        case .movie(let m): container.playback.play(movie: m)
        case .series(let s): playSeries(s)
        }
    }

    func playSeries(_ s: Series) {
        let c = container
        Task { @MainActor in
            do {
                let detail = try await c.details.series(id: s.id)
                let target = await Task.detached { try? c.history.resumeTarget(seriesID: s.id) }.value ?? detail.episodes.first
                guard let episode = target else { toasts.show("No episodes are available for \(s.title) yet.", symbol: "exclamationmark.triangle.fill", kind: .warning); return }
                c.playback.play(episode: episode, series: detail.series)
            } catch {
                toasts.show("Couldn't load episodes for \(s.title). \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)", symbol: "exclamationmark.triangle.fill", kind: .warning)
            }
        }
    }

    static func open(_ item: LibraryItem, router: AppRouter) {
        switch item { case .movie(let m): router.open(movie: m); case .series(let s): router.open(series: s) }
    }
}
