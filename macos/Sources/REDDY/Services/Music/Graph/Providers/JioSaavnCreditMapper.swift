import Foundation

/// JioSaavn song and album replies name people by role in `more_info.artistMap.artists` (`music`, `singer`, `lyricist`, `starring`, and where present
/// `producer`, `composer`), plus `primary_artists` and `featured_artists`. Roles the service did not send stay absent; `starring` is the film's cast,
/// so it is a film-level credit.
enum JioSaavnCreditMapper: MusicProviderCreditSource {
    static let sourceID = "jiosaavn"

    static func trackBundle(_ d: [String: Any]) -> MusicCreditBundle? {
        let more = d.dict("more_info") ?? [:]
        var c = MusicCreditCollector()
        if let map = artistMap(more) {
            for a in map.array("primary_artists") { add(a, role: .primary, level: .track, to: &c) }
            for a in map.array("featured_artists") { add(a, role: .featured, level: .track, to: &c) }
            for a in map.array("artists") {
                guard let role = role(a.str("role")) else { continue }
                add(a, role: role, level: role == .starring ? .film : .track, to: &c)
            }
        }
        if c.credits.isEmpty {
            // No artist map: the flat name lists some replies carry instead.
            for (key, role) in flatRoles {
                let level: MusicCreditLevel = role == .starring ? .film : .track
                c.addNames((d.str(key) ?? more.str(key)).map(JioSaavnProvider.clean), role: role, level: level)
            }
        }
        return c.bundle(hints: hints(d))
    }

    /// An album reply: the album's own artist map (when it names anyone), the flat `music` list, and the film's cast gathered from its songs.
    static func albumBundle(_ d: [String: Any]) -> MusicCreditBundle? {
        let more = d.dict("more_info") ?? [:]
        var c = MusicCreditCollector()
        if let map = artistMap(more) {
            for a in map.array("primary_artists") { add(a, role: .primary, level: .album, to: &c) }
            for a in map.array("featured_artists") { add(a, role: .featured, level: .album, to: &c) }
            for a in map.array("artists") {
                guard let role = role(a.str("role")) else { continue }
                add(a, role: role, level: role == .starring ? .film : .album, to: &c)
            }
        }
        if !c.credits.contains(where: { $0.role == .music }) {
            c.addNames((more.str("music") ?? d.str("music")).map(JioSaavnProvider.clean), role: .music, level: .album)
        }
        // The cast the service lists on the album's songs, billed once for the film.
        for song in d.array("list") {
            guard let map = artistMap(song.dict("more_info") ?? [:]) else { continue }
            for a in map.array("artists") where role(a.str("role")) == .starring { add(a, role: .starring, level: .film, to: &c) }
        }
        return c.bundle(hints: hints(d))
    }

    // MARK: pieces

    private static let flatRoles: [(String, MusicCreditRole)] = [("music", .music), ("singers", .singer), ("lyricist", .lyricist), ("starring", .starring)]

    /// The service sends the map as an object, and some replies as a JSON text of one.
    static func artistMap(_ more: [String: Any]) -> [String: Any]? {
        if let m = more.dict("artistMap") { return m }
        if let s = more["artistMap"] as? String, let data = s.data(using: .utf8), let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return m }
        return nil
    }

    /// Only roles the service names; `primary_artists` and `featured_artists` rows repeated inside `artists` are read from their own lists.
    static func role(_ raw: String?) -> MusicCreditRole? {
        switch raw?.lowercased() {
        case "music": .music
        case "singer": .singer
        case "lyricist": .lyricist
        case "starring": .starring
        case "producer": .producer
        case "composer": .composer
        case "conductor": .conductor
        case "arranger": .arranger
        default: nil
        }
    }

    private static func add(_ a: [String: Any], role: MusicCreditRole, level: MusicCreditLevel, to c: inout MusicCreditCollector) {
        c.add(a.str("name").map(JioSaavnProvider.clean), role: role, id: a.str("id"), level: level)
    }

    static func hints(_ d: [String: Any]) -> MusicProviderHints? {
        var h = MusicProviderHints()
        h.language = d.str("language")?.lowercased()
        h.year = MusicProviderHints.year(d.str("year"))
        return h.isEmpty ? nil : h
    }
}
