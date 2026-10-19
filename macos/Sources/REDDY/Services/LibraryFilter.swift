import Foundation

/// What the Filter on Movies and Series can narrow by, apart from the search words and the sort order. Every choice becomes part of the catalog query, so long lists
/// stay paged and counted correctly.
struct LibraryFilter: Equatable, Sendable {
    enum Status: String, CaseIterable, Identifiable, Sendable {
        case unwatched = "Not watched", started = "Started", watched = "Watched", favorites = "Favorites", newEpisodes = "New episodes"
        var id: String { rawValue }
    }

    var categoryID: String?
    var language: String?
    var quality: String?
    var minRating: Double?
    var decade: Int?
    var status: Status?

    var count: Int { [categoryID != nil, language != nil, quality != nil, minRating != nil, decade != nil, status != nil].filter { $0 }.count }
    var isActive: Bool { count > 0 }

    /// Puts the choices into a catalog query. The folder is left to the screen, which also checks folder locks.
    func apply(to q: inout VODQuery, kind: ContentKind) {
        q.language = language; q.quality = quality; q.minRating = minRating; q.decade = decade
        switch status {
        case .unwatched?: q.unwatchedOnly = true
        case .started?: q.watch = .started
        case .watched?: q.watch = .watched
        case .favorites?: q.favoritesOnly = true
        case .newEpisodes?: if kind == .series { q.newEpisodesOnly = true }
        case nil: break
        }
    }

    /// The statuses that make sense for this kind of title.
    static func statuses(for kind: ContentKind) -> [Status] { Status.allCases.filter { $0 != .newEpisodes || kind == .series } }
}

/// The languages and qualities the open list really has, so the panel never offers a choice that would show nothing.
struct LibraryFilterOptions: Equatable, Sendable {
    var languages: [String] = []
    var qualities: [String] = []
}

enum LibraryFilterTerms {
    /// The words a title or folder uses for each picture quality; the first of each is what the person sees.
    static let qualityTerms: [String: [String]] = [
        "4K": ["4K", "UHD", "2160p"], "1080p": ["1080p", "FHD"], "720p": ["720p"], "HDR": ["HDR"], "Dolby Vision": ["Dolby Vision", "DoVi"],
    ]
    static let qualityOrder = ["4K", "1080p", "720p", "HDR", "Dolby Vision"]
    static let ratings: [Double] = [9, 8, 7, 6]
    static let decades = [2020, 2010, 2000, 1990, 1980, 1970]
}
