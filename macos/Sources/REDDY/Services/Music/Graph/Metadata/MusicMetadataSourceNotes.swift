import Foundation

/// The words Settings shows for each metadata source: a name, one line, and the privacy note (what is sent, and to whom). One list, so the screen, the
/// translations and each source's `policy.privacyNote` stay the same text (a test compares them).
struct MusicMetadataSourceNote: Identifiable, Sendable {
    var id: MusicSourceID
    var title: String
    var detail: String
    var note: String
}

enum MusicMetadataSourceNotes {
    static let all: [MusicMetadataSourceNote] = [
        .init(id: .musicbrainz, title: "MusicBrainz", detail: "Song and album credits.",
              note: "Song, album and artist names, durations and ISRC codes are sent to MusicBrainz (musicbrainz.org) to find credits. No account, and never your listening history."),
        .init(id: .wikidata, title: "Wikidata", detail: "Films, cast, crew and ids.",
              note: "Film, song and person names and ids are sent to Wikidata (wikidata.org) to find cast, crew and links. No account, and never your listening history."),
        .init(id: .wikipedia, title: "Wikipedia", detail: "Cast lists and portraits, in many languages.",
              note: "Film titles and article names are sent to Wikipedia and Wikimedia Commons (wikipedia.org, wikimedia.org) to read cast lists and portraits. No account, and never your listening history."),
        .init(id: .imdb, title: "IMDb", detail: "Film cast names. Unofficial; it switches itself off if refused.",
              note: "Film titles are sent to IMDb's public search and title pages (imdb.com) to read cast names. Unofficial: it switches itself off if IMDb refuses. No account, and never your listening history."),
        .init(id: .listenbrainz, title: "ListenBrainz", detail: "Streaming and artist links.",
              note: "MusicBrainz recording ids (not names or your plays) are sent to ListenBrainz (listenbrainz.org) to find streaming and artist links. No account."),
        .init(id: .tmdb, title: "TMDB", detail: "Film cast and posters. Optional.",
              note: "Film and person names are sent to The Movie Database (themoviedb.org) through the app's own TMDB connection, only while TMDB lookups are on. Optional."),
        .init(id: .omdb, title: "OMDb", detail: "Film cast by IMDb id. Needs your own key.",
              note: "Film titles and IMDb ids are sent to OMDb (omdbapi.com) together with the key you entered. Off until you add a key."),
        .init(id: .discogs, title: "Discogs", detail: "Per-song credits for older records. Slow.",
              note: "Album titles and artist names are sent to Discogs (discogs.com) to read per-song credits. Off by default; slow, because Discogs limits requests."),
        .init(id: .lastfm, title: "Last.fm", detail: "Similar artists and tags. Needs a key.",
              note: "Artist names are sent to Last.fm (last.fm) with the application key, to find similar artists and tags. On only when a key is available."),
    ]

    static func note(for id: MusicSourceID) -> String? { all.first { $0.id == id }?.note }
}
