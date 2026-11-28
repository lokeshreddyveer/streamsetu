import Foundation

/// Audius track rows: the uploader (`user`) is the credited artist; `remix_of` and the `cover_original_*` fields say the track is a remix or cover.
enum AudiusCreditMapper: MusicProviderCreditSource {
    static let sourceID = "audius"

    static func trackBundle(_ d: [String: Any]) -> MusicCreditBundle? {
        var c = MusicCreditCollector()
        let user = d.dict("user") ?? [:]
        c.add(user.str("name") ?? user.str("handle"), role: .primary, id: user.str("id"), level: .track)
        var h = MusicProviderHints()
        h.genre = d.str("genre")
        h.year = MusicProviderHints.year(d.str("release_date") ?? d.str("created_at"))
        if let remix = d.dict("remix_of"), !remix.array("tracks").isEmpty {
            h.version = "remix"
        } else if let title = d.str("cover_original_song_title") {
            h.version = "cover"
            h.versionOf = [title, d.str("cover_original_artist")].compactMap { $0 }.joined(separator: " - ")
        }
        return c.bundle(hints: h.isEmpty ? nil : h)
    }
}
