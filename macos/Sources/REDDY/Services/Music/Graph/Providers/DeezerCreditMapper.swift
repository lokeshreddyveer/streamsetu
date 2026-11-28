import Foundation

/// Deezer's `track/{id}` reply lists `contributors`, each with a `role` (`Main`, `Featured`). Search and album rows do not carry the list.
enum DeezerCreditMapper: MusicProviderCreditSource {
    static let sourceID = "deezer"

    static func trackBundle(_ d: [String: Any]) -> MusicCreditBundle? {
        var c = MusicCreditCollector()
        for a in d.array("contributors") {
            let role: MusicCreditRole
            switch a.str("role")?.lowercased() {
            case "main": role = .primary
            case "featured": role = .featured
            case "composer": role = .composer
            case "lyricist": role = .lyricist
            case "producer": role = .producer
            case "remixer": role = .remixer
            default: continue
            }
            c.add(a.str("name"), role: role, id: a.str("id"), level: .track)
        }
        var h = MusicProviderHints()
        h.year = MusicProviderHints.year(d.str("release_date"))
        return c.bundle(hints: h.isEmpty ? nil : h)
    }
}
