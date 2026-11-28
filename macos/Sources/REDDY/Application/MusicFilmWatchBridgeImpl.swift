import Foundation

/// The app's side of Music's "Watch Movie" bridge. A film is "in the library" only when it matches an item the recommendation view allows (so a
/// locked, hidden, adult or Kids-restricted title never shows) and the profile is not gated. Opening goes through the app's own router; it changes
/// the app's destination, never Music's queue, and the app's audio ownership pauses Music when the movie plays.
@MainActor
final class MusicFilmWatchBridgeImpl: MusicFilmWatchBridge {
    private let container: AppContainer
    private let router: AppRouter

    init(container: AppContainer, router: AppRouter) { self.container = container; self.router = router }

    private func item(for film: MusicFilmWatchRef) -> LibraryItem? {
        guard let tmdb = film.tmdbID, container.parental.kidsMode == false, container.appLock.isLocked == false else { return nil }
        let credit = FilmCredit(tmdbID: tmdb, isSeries: film.isSeries, title: film.title, originalTitle: nil, date: film.year.map { String($0) },
                                posterPath: nil, overview: nil, rating: nil, votes: nil, popularity: 0, role: nil)
        let preferred = OtherLanguages.preferredName(container.settings.preferredAudioLanguage)
        guard let match = FilmographyMatcher(db: container.db, preferredLanguage: preferred).match([credit])[credit.id] else { return nil }
        let view = container.catalog.recommendationView
        if match.kind == .series { return ((try? view.seriesItem(id: match.representative)) ?? nil).map(LibraryItem.series) }
        return ((try? view.movie(id: match.representative)) ?? nil).map(LibraryItem.movie)
    }

    func isInLibrary(_ film: MusicFilmWatchRef) -> Bool { item(for: film) != nil }

    func openMovie(_ film: MusicFilmWatchRef) -> Bool {
        switch item(for: film) {
        case .movie(let m): router.open(movie: m); return true
        case .series(let s): router.open(series: s); return true
        case nil: return false
        }
    }
}
