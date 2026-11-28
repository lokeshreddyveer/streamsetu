import Foundation

/// An audio source that is not asked about other sources' songs while a song is being matched, but offers its own candidates when the person
/// opens "Choose another audio source". Uploads on SoundCloud are often covers, remixes or re-uploads, so a swap is only ever the person's choice.
protocol MusicAlternativeOffering: MusicAudioProvider {
    func alternatives(for track: MusicTrack) async throws -> [MusicAudioSource]
}

extension SoundCloudProvider: MusicAlternativeOffering {
    /// Uploads of the same recording as `track`: the same title and version, a credited artist, and a length within 3 percent (or 5 seconds).
    func alternatives(for track: MusicTrack) async throws -> [MusicAudioSource] {
        if track.providerID == Self.providerID { return [] }
        if await client.isResting { MusicDebugLog.log("soundcloud", "alternatives skipped: resting"); return [] }
        let words = ([track.title] + track.artists.prefix(1).map(\.name)).joined(separator: " ")
        let found = try await searchTracks(words, page: .offset(offset: 0, limit: 20)).items
        let picked = found.compactMap { c -> MusicAudioSource? in
            let score = SoundCloudMatch.alternativeScore(want: track, got: c)
            guard score >= 0.45 else { return nil }
            return MusicAudioSource(id: c.id, providerID: Self.providerID, title: c.title, artist: c.artistLine, album: nil,
                                    durationMs: c.durationMs > 0 ? c.durationMs : nil, thumbnails: c.thumbnails, externalURL: c.externalURL, confidence: score)
        }.sorted { $0.confidence > $1.confidence }.prefix(5)
        MusicDebugLog.log("soundcloud", "alternatives for \(track.uid): \(picked.count) of \(found.count)")
        return Array(picked)
    }

    /// The artist's own uploads for the "More on SoundCloud" shelf. Empty unless one SoundCloud profile is confidently that artist.
    func moreFromArtist(named name: String) async -> [MusicTrack] {
        if await client.isResting { return [] }
        do {
            let rows = try await fetchRows("search/users", ["q": name], page: .offset(offset: 0, limit: 8)).rows
            guard let user = SoundCloudMatch.confidentUser(named: name, among: rows.compactMap { SoundCloudJSON.user($0) }) else {
                MusicDebugLog.log("soundcloud", "more-on-soundcloud: no confident profile")
                return []
            }
            let tracks = try await artistTopTracks(id: user.id)
            MusicDebugLog.log("soundcloud", "more-on-soundcloud: \(tracks.count) tracks")
            return tracks
        } catch {
            MusicDebugLog.log("soundcloud", "more-on-soundcloud failed")
            return []
        }
    }
}
