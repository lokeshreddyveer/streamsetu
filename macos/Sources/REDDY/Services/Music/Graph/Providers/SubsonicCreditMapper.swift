import Foundation

/// Subsonic and OpenSubsonic songs. OpenSubsonic servers send `artists`, `albumArtists`, `displayComposer` and a `contributors` list of
/// `{role, subRole, artist}`; some send the same list as `participants`. A server that sends none yields no credits.
enum SubsonicCreditMapper: MusicProviderCreditSource {
    static let sourceID = "subsonic"

    static func trackBundle(_ d: [String: Any]) -> MusicCreditBundle? { trackBundle(d, id: { $0 }) }

    /// `id` turns the server's raw artist id into the id the provider's artist refs use.
    static func trackBundle(_ d: [String: Any], id: (String) -> String) -> MusicCreditBundle? {
        var c = MusicCreditCollector()
        func pid(_ a: [String: Any]) -> String? { a.str("id").map(id) }
        for a in d.array("artists") { c.add(a.str("name"), role: .primary, id: pid(a), level: .track) }
        for a in d.array("albumArtists") { c.add(a.str("name"), role: .albumArtist, id: pid(a), level: .album) }
        var sawComposer = false
        for row in d.array("contributors") + d.array("participants") {
            let person = row.dict("artist") ?? row
            guard let role = role(row.str("role")) else { continue }
            if role == .composer { sawComposer = true }
            c.add(person.str("name"), role: role, id: pid(person), level: role == .albumArtist ? .album : .track,
                  instrument: role == .performer ? row.str("subRole") : nil)
        }
        if !sawComposer { c.addNames(d.str("displayComposer"), role: .composer) }
        var h = MusicProviderHints()
        h.year = d.int("year")
        h.genre = d.str("genre") ?? d.array("genres").first?.str("name")
        return c.bundle(hints: h.isEmpty ? nil : h)
    }

    static func role(_ raw: String?) -> MusicCreditRole? {
        switch raw?.lowercased() {
        case "artist": .primary
        case "albumartist": .albumArtist
        case "composer": .composer
        case "conductor": .conductor
        case "lyricist": .lyricist
        case "performer": .performer
        case "producer": .producer
        case "remixer": .remixer
        case "arranger": .arranger
        default: nil
        }
    }
}
