import Foundation

/// Picks the recording of a documented raga song out of a source's search results. The title has to match; the film, composer and singers (what the table documents)
/// decide between several songs of one name, and a title that only contains the song's is taken only when one of those agrees too.
enum MusicRagaMatch {
    static func best(for song: MusicRagaSong, in tracks: [MusicTrack]) -> MusicTrack? {
        let want = MusicText.normalize(song.title)
        guard !want.isEmpty else { return nil }
        let people = song.singers + [song.composer]
        var best: (track: MusicTrack, score: Int)?
        for t in tracks {
            let title = MusicText.normalize(t.title)
            let level: Int
            if title == want { level = 3 }
            else if MusicRelatedMatch.titleScore(song.title, t.title) >= MusicRelatedMatch.accept { level = 2 }
            else if title.contains(want) { level = 1 }
            else { continue }
            var evidence = 0
            let artistHit = t.artists.contains { a in people.contains { !$0.isEmpty && MusicRelatedMatch.nameScore(a.name, $0) >= MusicRelatedMatch.accept } }
            if artistHit { evidence += 2 }
            if !song.film.isEmpty {
                let filmWords = MusicText.normalize(song.film)
                let albumTitle = MusicText.normalize(t.album?.title ?? "")
                if (!albumTitle.isEmpty && (albumTitle.contains(filmWords) || filmWords.contains(albumTitle))) || title.contains(filmWords) { evidence += 1 }
            }
            if level == 1 && evidence == 0 { continue }
            let score = level * 10 + evidence
            if best == nil || score > best!.score { best = (t, score) }
        }
        return best?.track
    }
}
