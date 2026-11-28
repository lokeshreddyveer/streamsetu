import Foundation

/// A film as Music knows it, in the words the host app can match against its own library.
struct MusicFilmWatchRef: Hashable, Sendable {
    var tmdbID: Int?
    var title: String
    var year: Int?
    var isSeries = false
    init(tmdbID: Int?, title: String, year: Int? = nil, isSeries: Bool = false) { self.tmdbID = tmdbID; self.title = title; self.year = year; self.isSeries = isSeries }
}

/// What Music asks of the app about a film (section 4.8). Music never imports the app's router: the app installs the real implementation once at
/// launch. Opening a film page leaves audio playing; this bridge is only used when the person presses "Watch Movie", and the app's audio ownership
/// then pauses Music (the queue is kept).
protocol MusicFilmWatchBridge: Sendable {
    /// True when the person's library holds the film and it may be shown (locked, hidden, adult and Kids restrictions already applied).
    @MainActor func isInLibrary(_ film: MusicFilmWatchRef) -> Bool
    /// Opens the film in the app's own movie page. False when it could not (not in the library, or gated).
    @MainActor func openMovie(_ film: MusicFilmWatchRef) -> Bool
}

/// Where the installed bridge lives. Nothing installed (tests, a gated profile): every film is "not in the library" and nothing opens.
final class MusicFilmWatchBridgeHost: @unchecked Sendable {
    static let shared = MusicFilmWatchBridgeHost()
    private let lock = NSLock()
    private var bridge: (any MusicFilmWatchBridge)?
    func install(_ b: (any MusicFilmWatchBridge)?) { lock.lock(); bridge = b; lock.unlock() }
    var installed: (any MusicFilmWatchBridge)? { lock.lock(); defer { lock.unlock() }; return bridge }

    @MainActor func isInLibrary(_ film: MusicFilmWatchRef) -> Bool { installed?.isInLibrary(film) ?? false }
    @MainActor func openMovie(_ film: MusicFilmWatchRef) -> Bool { installed?.openMovie(film) ?? false }
}
