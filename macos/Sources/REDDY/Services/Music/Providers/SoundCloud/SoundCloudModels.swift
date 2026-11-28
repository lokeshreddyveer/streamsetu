import Foundation

// SoundCloud's web replies, read leniently. Every field is optional and an unknown shape gives nil or an empty value, never a crash:
// the service changes these replies without notice.

/// One uploader or artist profile.
struct SCUser: Sendable, Hashable {
    var id: String
    var username: String
    var fullName: String? = nil
    var permalink: String? = nil
    var permalinkURL: String? = nil
    var avatarURL: String? = nil
    var followers: Int? = nil
    var trackCount: Int? = nil
    var verified = false
    var city: String? = nil
    var country: String? = nil
    var about: String? = nil

    /// What a person would call this profile.
    var displayName: String { username.isEmpty ? (fullName ?? permalink ?? "") : username }
}

/// One way to fetch a track's audio: an address to ask, not the audio address itself.
struct SCTranscoding: Sendable, Hashable {
    var url: String
    var preset: String = ""
    /// `progressive`, `hls`, or an encrypted variant such as `ctr-encrypted-hls`.
    var proto: String = ""
    var mime: String = ""
    var snipped = false
    var quality: String? = nil
}

struct SCTrack: Sendable, Hashable {
    var id: String
    var title: String? = nil
    var durationMs: Int64 = 0
    var user: SCUser? = nil
    var artworkURL: String? = nil
    var permalinkURL: String? = nil
    var genre: String? = nil
    var tags: String? = nil
    var about: String? = nil
    var createdAt: String? = nil
    var plays: Int? = nil
    var likes: Int? = nil
    var commentCount: Int? = nil
    var streamable: Bool? = nil
    var policy: String? = nil
    var access: String? = nil
    var trackAuthorization: String? = nil
    var transcodings: [SCTranscoding] = []
    var waveformURL: String? = nil
    var publisherArtist: String? = nil
    var isrc: String? = nil
    var explicit = false
    /// A playlist lists most tracks as bare ids; they are fetched in one batch before use.
    var isStub: Bool { title == nil }
}

struct SCPlaylist: Sendable, Hashable {
    var id: String
    var title: String
    var about: String? = nil
    var user: SCUser? = nil
    var artworkURL: String? = nil
    var permalinkURL: String? = nil
    var trackCount: Int? = nil
    var isAlbum = false
    var releaseDate: String? = nil
    var tracks: [SCTrack] = []
}

struct SCComment: Sendable, Hashable {
    var id: String
    var body: String
    var timestampMs: Int64?
    var userID: String?
}

enum SCResolved: Sendable {
    case track(SCTrack), playlist(SCPlaylist), user(SCUser)
}

/// Reads raw JSON into the models above.
enum SoundCloudJSON {
    static func object(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
    static func any(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }

    /// The rows of a collection reply (`{"collection": [...]}`) or of a bare array.
    static func rows(_ any: Any?) -> [[String: Any]] {
        if let o = any as? [String: Any] { return (o["collection"] as? [[String: Any]]) ?? [] }
        return (any as? [[String: Any]]) ?? []
    }
    static func nextHref(_ any: Any?) -> String? { ((any as? [String: Any])?["next_href"] as? String).flatMap { $0.isEmpty ? nil : $0 } }

    static func user(_ d: [String: Any]?) -> SCUser? {
        guard let d, let id = d.str("id") else { return nil }
        var verifiedFlag = (d["verified"] as? Bool) ?? false
        if let badges = d.dict("badges"), (badges["verified"] as? Bool) == true { verifiedFlag = true }
        return SCUser(id: id, username: d.str("username") ?? "", fullName: d.str("full_name"), permalink: d.str("permalink"),
                      permalinkURL: d.str("permalink_url"), avatarURL: d.str("avatar_url"), followers: d.int("followers_count"),
                      trackCount: d.int("track_count"), verified: verifiedFlag, city: d.str("city"), country: d.str("country_code"),
                      about: d.str("description"))
    }

    static func transcoding(_ d: [String: Any]) -> SCTranscoding? {
        guard let url = d.str("url") else { return nil }
        let f = d.dict("format")
        return SCTranscoding(url: url, preset: d.str("preset") ?? "", proto: f?.str("protocol") ?? "", mime: f?.str("mime_type") ?? "",
                             snipped: (d["snipped"] as? Bool) ?? false, quality: d.str("quality"))
    }

    static func track(_ d: [String: Any]?) -> SCTrack? {
        guard let d, let id = d.str("id") else { return nil }
        // A "kind" other than track (a user or a playlist inside a mixed list) is not a track.
        if let kind = d.str("kind"), kind != "track" { return nil }
        let media = d.dict("media")
        let transcodings = (media?["transcodings"] as? [[String: Any]] ?? []).compactMap(transcoding)
        let meta = d.dict("publisher_metadata")
        let duration = d.int("full_duration") ?? d.int("duration") ?? 0
        return SCTrack(id: id, title: d.str("title"), durationMs: Int64(duration), user: user(d.dict("user")), artworkURL: d.str("artwork_url"),
                       permalinkURL: d.str("permalink_url"), genre: d.str("genre"), tags: d.str("tag_list"), about: d.str("description"),
                       createdAt: d.str("created_at") ?? d.str("display_date"), plays: d.int("playback_count"), likes: d.int("likes_count"),
                       commentCount: d.int("comment_count"), streamable: d["streamable"] as? Bool, policy: d.str("policy"), access: d.str("access"),
                       trackAuthorization: d.str("track_authorization"), transcodings: transcodings, waveformURL: d.str("waveform_url"),
                       publisherArtist: meta?.str("artist"), isrc: meta?.str("isrc"), explicit: (meta?["explicit"] as? Bool) ?? false)
    }

    static func playlist(_ d: [String: Any]?) -> SCPlaylist? {
        guard let d, let id = d.str("id") else { return nil }
        if let kind = d.str("kind"), kind != "playlist", kind != "system-playlist" { return nil }
        guard let title = d.str("title") else { return nil }
        let isAlbum = (d["is_album"] as? Bool) == true || (d.str("set_type") ?? "").lowercased() == "album"
        let tracks = (d["tracks"] as? [[String: Any]] ?? []).compactMap(track)
        return SCPlaylist(id: id, title: title, about: d.str("description"), user: user(d.dict("user")), artworkURL: d.str("artwork_url"),
                          permalinkURL: d.str("permalink_url"), trackCount: d.int("track_count") ?? (tracks.isEmpty ? nil : tracks.count),
                          isAlbum: isAlbum, releaseDate: d.str("release_date") ?? d.str("display_date"), tracks: tracks)
    }

    static func comment(_ d: [String: Any]) -> SCComment? {
        guard let id = d.str("id"), let body = d.str("body") else { return nil }
        return SCComment(id: id, body: body, timestampMs: d.int("timestamp").map(Int64.init), userID: d.dict("user")?.str("id") ?? d.str("user_id"))
    }

    /// The answer of the resolve endpoint: a track, a set or a profile.
    static func resolved(_ d: [String: Any]?) -> SCResolved? {
        guard let d else { return nil }
        switch d.str("kind") {
        case "track": return track(d).map(SCResolved.track)
        case "playlist", "system-playlist": return playlist(d).map(SCResolved.playlist)
        case "user": return user(d).map(SCResolved.user)
        default: return nil
        }
    }
}
