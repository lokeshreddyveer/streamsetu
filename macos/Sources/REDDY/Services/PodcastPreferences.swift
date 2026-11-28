import Foundation

/// What the person chose for Podcasts in the first-run setup (and can change by running it again): the country whose charts they want, and the categories they care about.
/// Both are only read by Podcasts: the charts follow the region, and Discover offers the categories as one row.
enum PodcastPreferences {
    static let regionKey = "podcasts.pref.region"
    static let genresKey = "podcasts.pref.genres"

    /// The two-letter region chosen in setup (lower case), or nil to follow the system region.
    static func region(_ d: UserDefaults = .standard) -> String? {
        guard let r = d.string(forKey: regionKey)?.lowercased(), r.count == 2, r.allSatisfy(\.isLetter) else { return nil }
        return r
    }

    static func setRegion(_ code: String?, _ d: UserDefaults = .standard) {
        if let code, code.count == 2 { d.set(code.lowercased(), forKey: regionKey) } else { d.removeObject(forKey: regionKey) }
    }

    static func genres(_ d: UserDefaults = .standard) -> [PodcastGenre] {
        ((d.array(forKey: genresKey) as? [Int]) ?? []).compactMap(PodcastGenre.init(rawValue:))
    }

    static func setGenres(_ genres: [PodcastGenre], _ d: UserDefaults = .standard) {
        if genres.isEmpty { d.removeObject(forKey: genresKey) } else { d.set(genres.map(\.rawValue), forKey: genresKey) }
    }
}
