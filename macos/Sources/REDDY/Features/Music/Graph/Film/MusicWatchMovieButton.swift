import SwiftUI

/// "Watch Movie" when the film is in the person's library, a quiet "Not in your library" line when it is not, nothing when the profile is gated or the
/// film cannot be asked about. The button calls the app's bridge once per tap and does nothing else: it never touches the music player. The movie's
/// own screen starts playing only when the person presses Play there, and the app's audio ownership then pauses music with the queue kept.
struct MusicWatchMovieButton: View {
    let state: MusicFilmWatchState
    var isSeries = false
    let action: () -> Void

    var body: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .available:
            Button(action: action) {
                Label(isSeries ? Localized.string("Watch Series") : Localized.string("Watch Movie"), systemImage: "play.rectangle.fill")
            }
            .musicButton(.secondary, size: .large)
            .help(Localized.string("Opens it in your library. Your music queue is kept; music pauses when you press Play on the movie."))
            .accessibilityLabel(isSeries ? Localized.string("Watch Series") : Localized.string("Watch Movie"))
            .accessibilityHint(Localized.string("Opens it in your library. Your music queue is kept."))
            .atlas("control.music.filmWatchMovie")
        case .notInLibrary:
            Label { Text(verbatim: Localized.string("Not in your library")).musicText(.caption) } icon: { Image(systemName: "film").font(.system(size: MusicIconSize.tiny)) }
                .foregroundStyle(ColorTokens.textTertiary)
                .accessibilityElement(children: .combine)
        }
    }
}
