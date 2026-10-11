import Foundation

/// Extra facts about a movie or series from The Movie Database: trailers, cast, who made it, and what is similar.
struct TitleDetails: Codable, Sendable, Equatable {
    struct Trailer: Codable, Sendable, Equatable, Identifiable { var key: String; var name: String; var type: String; var id: String { key }
        var watchURL: URL? { URL(string: "https://www.youtube.com/watch?v=\(key)") } }
    struct Person: Codable, Sendable, Equatable, Identifiable { var name: String; var role: String?; var photoPath: String?; var id: String { name + (role ?? "") }
        var photoURL: String? { photoPath.map { MetadataMatchService.imageBase + "w185" + $0 } } }
    struct Similar: Codable, Sendable, Equatable, Identifiable { var tmdbID: Int; var title: String; var year: Int?; var id: Int { tmdbID } }

    var tmdbID: Int
    var isSeries: Bool
    var tagline: String?
    var overview: String?
    var runtimeMinutes: Int?
    var releaseDate: String?
    var genres: [String] = []
    var certification: String?
    var rating: Double?
    var votes: Int?
    var seasons: Int?
    var trailers: [Trailer] = []
    var cast: [Person] = []
    /// Directors for a film, creators for a series.
    var makers: [String] = []
    var similar: [Similar] = []

    var year: Int? { releaseDate.flatMap { Int($0.prefix(4)) } }
    var bestTrailer: Trailer? { trailers.first }
}

// MARK: parsing TMDB's reply

enum TitleDetailsParser {
    private struct Reply: Decodable {
        struct Genre: Decodable { let name: String }
        struct Video: Decodable { let key: String; let name: String; let site: String; let type: String; let official: Bool? }
        struct Videos: Decodable { let results: [Video] }
        struct Cast: Decodable { let name: String; let character: String?; let profile_path: String? }
        struct Crew: Decodable { let name: String; let job: String? }
        struct Credits: Decodable { let cast: [Cast]; let crew: [Crew] }
        struct Rec: Decodable { let id: Int; let title: String?; let name: String?; let release_date: String?; let first_air_date: String? }
        struct Recs: Decodable { let results: [Rec] }
        struct Creator: Decodable { let name: String }
        struct ReleaseCountry: Decodable { struct R: Decodable { let certification: String? }; let iso_3166_1: String; let release_dates: [R] }
        struct ReleaseDates: Decodable { let results: [ReleaseCountry] }
        struct ContentRating: Decodable { let iso_3166_1: String; let rating: String }
        struct ContentRatings: Decodable { let results: [ContentRating] }
        let id: Int
        let tagline: String?, overview: String?
        let runtime: Int?, episode_run_time: [Int]?
        let release_date: String?, first_air_date: String?
        let genres: [Genre]?
        let vote_average: Double?, vote_count: Int?
        let number_of_seasons: Int?
        let videos: Videos?, credits: Credits?, recommendations: Recs?
        let created_by: [Creator]?
        let release_dates: ReleaseDates?, content_ratings: ContentRatings?
    }

    static func parse(_ data: Data, isSeries: Bool) -> TitleDetails? {
        guard let r = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        var d = TitleDetails(tmdbID: r.id, isSeries: isSeries)
        d.tagline = r.tagline.flatMap { $0.isEmpty ? nil : $0 }
        d.overview = r.overview.flatMap { $0.isEmpty ? nil : $0 }
        d.runtimeMinutes = r.runtime.flatMap { $0 > 0 ? $0 : nil } ?? r.episode_run_time?.first
        d.releaseDate = (isSeries ? r.first_air_date : r.release_date).flatMap { $0.isEmpty ? nil : $0 }
        d.genres = r.genres?.map(\.name) ?? []
        d.rating = r.vote_average.flatMap { $0 > 0 ? $0 : nil }
        d.votes = r.vote_count
        d.seasons = r.number_of_seasons
        // official YouTube trailers first, then other trailers, then teasers
        let yt = (r.videos?.results ?? []).filter { $0.site == "YouTube" }
        let rank: (Reply.Video) -> Int = { ($0.type == "Trailer" ? 0 : $0.type == "Teaser" ? 2 : 4) + ($0.official == true ? 0 : 1) }
        d.trailers = yt.filter { $0.type == "Trailer" || $0.type == "Teaser" }.sorted { rank($0) < rank($1) }.prefix(4).map { .init(key: $0.key, name: $0.name, type: $0.type) }
        d.cast = (r.credits?.cast ?? []).prefix(12).map { .init(name: $0.name, role: $0.character.flatMap { $0.isEmpty ? nil : $0 }, photoPath: $0.profile_path) }
        d.makers = isSeries ? (r.created_by ?? []).map(\.name) : Array(Set((r.credits?.crew ?? []).filter { $0.job == "Director" }.map(\.name))).sorted()
        d.similar = (r.recommendations?.results ?? []).prefix(20).compactMap { x in
            guard let t = x.title ?? x.name else { return nil }
            return .init(tmdbID: x.id, title: t, year: (x.release_date ?? x.first_air_date).flatMap { Int($0.prefix(4)) })
        }
        if isSeries {
            let all = r.content_ratings?.results ?? []
            d.certification = (all.first { $0.iso_3166_1 == "US" } ?? all.first)?.rating
        } else {
            let all = r.release_dates?.results ?? []
            let pick = { (c: Reply.ReleaseCountry) in c.release_dates.compactMap(\.certification).first { !$0.isEmpty } }
            d.certification = all.first { $0.iso_3166_1 == "US" }.flatMap(pick) ?? all.compactMap(pick).first
        }
        return d
    }
}
