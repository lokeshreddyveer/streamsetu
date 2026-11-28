import Foundation

/// SoundCloud shapes to the app's own music models. Pure, so tests feed canned JSON.
enum SoundCloudMapping {
    /// Pictures come in named sizes (`-large` is 100 px). The 500 px one is asked for instead; the original stays as the small size.
    static func upgraded(_ url: String?) -> String? {
        guard let url, url.hasPrefix("http") else { return nil }
        let re = try? NSRegularExpression(pattern: "-(large|crop|badge|small|tiny|mini|t\\d+x\\d+)\\.(jpg|jpeg|png|webp)")
        let ns = url as NSString
        guard let re, let m = re.firstMatch(in: url, range: NSRange(location: 0, length: ns.length)) else { return url }
        return ns.replacingCharacters(in: m.range, with: "-t500x500." + ns.substring(with: m.range(at: 2)))
    }

    static func thumbnails(_ url: String?) -> [MusicThumbnail] {
        guard let big = upgraded(url) else { return [] }
        var out: [MusicThumbnail] = []
        if let url, url != big { out.append(MusicThumbnail(url: url, width: 100, height: 100)) }
        out.append(MusicThumbnail(url: big, width: 500, height: 500))
        return out
    }

    /// The artist of an upload: the publisher's own artist field when the uploader is a label or a channel, otherwise the uploader.
    static func artistRef(for t: SCTrack) -> MusicArtistRef {
        let u = t.user
        let uploader = u?.displayName ?? ""
        let credited = (t.publisherArtist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !credited.isEmpty, !SoundCloudMatch.sameArtist(credited, uploader) || uploader.isEmpty {
            return MusicArtistRef(id: "", name: credited, thumbnails: thumbnails(u?.avatarURL))
        }
        return MusicArtistRef(id: u?.id ?? "", name: uploader.isEmpty ? "Unknown artist" : uploader, thumbnails: thumbnails(u?.avatarURL), externalURL: u?.permalinkURL)
    }

    static func track(_ t: SCTrack) -> MusicTrack? {
        guard let title = t.title, !title.isEmpty else { return nil }
        let artist = artistRef(for: t)
        var art = thumbnails(t.artworkURL)
        if art.isEmpty { art = artist.thumbnails }
        let genre = (t.genre ?? "").lowercased()
        var out = MusicTrack(id: t.id, providerID: SoundCloudProvider.providerID, title: title, durationMs: t.durationMs, artists: [artist],
                             album: nil, thumbnails: art, explicit: t.explicit, popularity: t.plays, isrc: t.isrc, externalURL: t.permalinkURL,
                             directStreams: nil)
        if genre.contains("podcast") || genre.contains("talk") { out.isPodcast = true }
        out.creditBundle = SoundCloudCreditMapper.bundle(for: t, artist: artist)
        return out
    }

    static func artist(_ u: SCUser) -> MusicArtist {
        MusicArtist(id: u.id, providerID: SoundCloudProvider.providerID, name: u.displayName, thumbnails: thumbnails(u.avatarURL),
                    followers: u.followers, bio: u.about, externalURL: u.permalinkURL)
    }

    static func playlist(_ p: SCPlaylist) -> MusicPlaylist {
        var art = thumbnails(p.artworkURL)
        if art.isEmpty { art = thumbnails(p.tracks.first?.artworkURL) }
        if art.isEmpty { art = thumbnails(p.user?.avatarURL) }
        return MusicPlaylist(id: p.id, providerID: SoundCloudProvider.providerID, name: p.title, summary: p.about, owner: p.user?.displayName,
                             thumbnails: art, trackCount: p.trackCount, isPublic: true, externalURL: p.permalinkURL)
    }

    static func album(_ p: SCPlaylist) -> MusicAlbum {
        var art = thumbnails(p.artworkURL)
        if art.isEmpty { art = thumbnails(p.tracks.first?.artworkURL) }
        let owner = p.user.map { MusicArtistRef(id: $0.id, name: $0.displayName, thumbnails: thumbnails($0.avatarURL), externalURL: $0.permalinkURL) }
        return MusicAlbum(id: p.id, providerID: SoundCloudProvider.providerID, title: p.title, artists: owner.map { [$0] } ?? [], thumbnails: art,
                          releaseDate: p.releaseDate.map { String($0.prefix(10)) }, totalTracks: p.trackCount, albumType: "Album", externalURL: p.permalinkURL)
    }
}

/// What a SoundCloud upload says about itself, for the graph: the uploader or credited artist, the genre, the year, and a `version` hint when the
/// title says remix, bootleg, edit and so on (so it is never taken for the studio recording).
enum SoundCloudCreditMapper {
    static let sourceID = "soundcloud"

    static func bundle(for t: SCTrack, artist: MusicArtistRef) -> MusicCreditBundle? {
        var c = MusicCreditCollector()
        c.add(artist.name, role: .primary, id: artist.id, level: .track)
        var h = MusicProviderHints()
        h.genre = t.genre
        h.year = MusicProviderHints.year(t.createdAt)
        let tags = SoundCloudMatch.versionTags(t.title ?? "")
        if let first = ["remix", "bootleg", "mashup", "flip", "rework", "edit", "cover", "live", "slowed", "sped", "nightcore"].first(where: tags.contains) { h.version = first }
        return c.bundle(hints: h.isEmpty ? nil : h)
    }
}
