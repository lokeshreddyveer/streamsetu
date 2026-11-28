import Foundation

// The Watch Movie button as a state machine. The library check and the open both go through the bridge the app installs; this file knows nothing
// of the app's router, its movie screen, its databases or the player. Opening a film page never touches audio; pressing the button only asks the app
// to open its own movie page (the app's audio ownership pauses music when the movie starts playing, and the queue stays).

enum MusicFilmWatchState: Equatable, Sendable {
    /// Nothing is drawn: a Kids or locked profile, or not enough is known about the film to ask.
    case hidden
    /// The film is in the library: show "Watch Movie".
    case available(MusicFilmWatchRef)
    /// The film has an id to ask with and is not in the library: a quiet "Not in your library" line, no button.
    case notInLibrary
}

@MainActor
struct MusicFilmWatchLogic {
    var isInLibrary: (MusicFilmWatchRef) -> Bool
    var open: (MusicFilmWatchRef) -> Bool

    /// The app's installed bridge (nothing installed: every film is "not in the library").
    static func host(_ h: MusicFilmWatchBridgeHost = .shared) -> MusicFilmWatchLogic {
        MusicFilmWatchLogic(isInLibrary: { h.isInLibrary($0) }, open: { h.openMovie($0) })
    }

    func state(for ref: MusicFilmWatchRef?, gated: Bool) -> MusicFilmWatchState {
        guard !gated, let ref, ref.tmdbID != nil, !ref.title.isEmpty else { return .hidden }
        return isInLibrary(ref) ? .available(ref) : .notInLibrary
    }

    enum Outcome: Equatable, Sendable { case opened, unavailable }

    /// One tap, one call to the bridge. A refusal (the library changed, or the profile became gated) leaves the caller to refresh its state.
    func press(_ ref: MusicFilmWatchRef) -> Outcome { open(ref) ? .opened : .unavailable }
}

enum MusicFilmWatchRefs {
    /// The words the app's library matcher needs: the TMDB id of the film (or series), its title and year.
    static func ref(snapshot s: MusicEntitySnapshot?, externalIDs ids: [ExternalID]) -> MusicFilmWatchRef? {
        guard let s, s.kind == .film || s.kind == .series else { return nil }
        let series = s.kind == .series
        let tmdb = ids.first { $0.scheme == (series ? .tmdbTV : .tmdbMovie) }.flatMap { Int($0.value) }
        return MusicFilmWatchRef(tmdbID: tmdb, title: s.name, year: s.year, isSeries: series)
    }
}
