import Foundation

/// A music video row asked to play as sound: its official audio twin is used when the service names one, else found by search.
enum MusicOfficialAudio {
    static let runtimeWindowMs: Int64 = 10_000

    /// The same row as its audio twin, from the id the service gave.
    static func counterpart(of video: MusicTrack) -> MusicTrack? {
        guard video.isVideo == true, let id = video.counterpartVideoID, !id.isEmpty, id != (video.videoID ?? video.id) else { return nil }
        var t = video
        t.id = id; t.videoID = id; t.isVideo = false; t.counterpartVideoID = video.videoID ?? video.id
        t.directStreams = nil
        return t
    }

    /// The search text for a video row.
    static func query(for video: MusicTrack) -> String {
        [MusicCandidateRules.cleanTitle(video.title), MusicCandidateRules.primaryArtist(video)].compactMap { $0 }.joined(separator: " ")
    }

    /// From search results, the audio-only row with the same version and an artist in common whose runtime is nearest to the video's, within 10 s.
    static func choose(for video: MusicTrack, among results: [MusicTrack]) -> MusicTrack? {
        let wantedTags = MusicCandidateRules.versionTags(title: video.title, album: video.album?.title)
        var best: (MusicTrack, Int64)?
        for r in results where r.isVideo != true && r.id != video.id && r.id != video.videoID {
            guard MusicCandidateRules.versionTags(title: r.title, album: r.album?.title) == wantedTags else { continue }
            guard MusicCandidateRules.sharesArtist(track: video, candidateArtist: r.artistLine, candidateTitle: r.title) == true else { continue }
            guard MusicText.normalize(MusicCandidateRules.cleanTitle(r.title)) == MusicText.normalize(MusicCandidateRules.cleanTitle(video.title))
                    || MusicTextMatch.similarity(MusicTextMatch.coreTokens(video.title), MusicTextMatch.coreTokens(r.title)) >= 0.8 else { continue }
            guard video.durationMs > 0, r.durationMs > 0 else { continue }
            let drift = abs(video.durationMs - r.durationMs)
            guard drift <= runtimeWindowMs else { continue }
            if best == nil || drift < best!.1 { best = (r, drift) }
        }
        return best?.0
    }
}
