import Foundation

/// Providers disagree about types ("12", 12, 12.0, true). Decode any scalar leniently.
struct Flex: Decodable, Sendable, Hashable {
    let string: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { string = nil }
        else if let s = try? c.decode(String.self) { string = s }
        else if let i = try? c.decode(Int.self) { string = String(i) }
        else if let d = try? c.decode(Double.self) { string = d == d.rounded() ? String(Int(d)) : String(d) }
        else if let b = try? c.decode(Bool.self) { string = b ? "1" : "0" }
        else { string = nil }
    }

    var nonEmpty: String? { string.nilIfEmpty }
    var int: Int? { string.flatMap { Int($0) ?? Double($0).map(Int.init) } }
    var double: Double? { string.flatMap(Double.init) }
}

/// A string or an array of strings (`backdrop_path`).
struct FlexList: Decodable, Sendable, Hashable {
    let values: [String]
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let a = try? c.decode([String].self) { values = a }
        else if let s = try? c.decode(String.self) { values = [s] }
        else { values = [] }
    }
}

struct XtreamCategoryDTO: Decodable, Sendable {
    let category_id: Flex?
    let category_name: Flex?
}

struct XtreamLiveDTO: Decodable, Sendable {
    let num: Flex?
    let name: Flex?
    let stream_id: Flex?
    let stream_icon: Flex?
    let epg_channel_id: Flex?
    let category_id: Flex?
    /// "1" when the provider keeps an archive for this channel, and for how many days.
    let tv_archive: Flex?
    let tv_archive_duration: Flex?
}

struct XtreamVODDTO: Decodable, Sendable {
    let num: Flex?
    let name: Flex?
    let stream_id: Flex?
    let stream_icon: Flex?
    let rating: Flex?
    let added: Flex?
    let category_id: Flex?
    let container_extension: Flex?
    let year: Flex?
}

struct XtreamSeriesDTO: Decodable, Sendable {
    let series_id: Flex?
    let name: Flex?
    let cast: Flex?
    let director: Flex?
    let cover: Flex?
    let plot: Flex?
    let genre: Flex?
    let releaseDate: Flex?
    let release_date: Flex?
    let rating: Flex?
    let backdrop_path: FlexList?
    let category_id: Flex?
    let last_modified: Flex?
}

struct XtreamAccountDTO: Decodable, Sendable {
    struct UserInfo: Decodable, Sendable {
        let auth: Flex?
        let status: Flex?
        let exp_date: Flex?
        let max_connections: Flex?
        let allowed_output_formats: FlexList?
    }
    let user_info: UserInfo?
}

struct XtreamVODInfoDTO: Decodable, Sendable {
    struct Info: Decodable, Sendable {
        let plot: Flex?
        let description: Flex?
        let genre: Flex?
        let releasedate: Flex?
        let release_date: Flex?
        let duration_secs: Flex?
        let backdrop_path: FlexList?
        let movie_image: Flex?
        let cover_big: Flex?
        let rating: Flex?
        let youtube_trailer: Flex?
        let cast: Flex?
        let actors: Flex?
        let director: Flex?
        let country: Flex?
        let age: Flex?
        let mpaa_rating: Flex?
        let tmdb_id: Flex?
    }
    let info: Info?
}

struct XtreamSeriesInfoDTO: Decodable, Sendable {
    struct Season: Decodable, Sendable {
        let season_number: Flex?
        let name: Flex?
    }
    struct Episode: Decodable, Sendable {
        struct Info: Decodable, Sendable {
            let duration_secs: Flex?
            let plot: Flex?
            let movie_image: Flex?
        }
        let id: Flex?
        let episode_num: Flex?
        let title: Flex?
        let container_extension: Flex?
        let season: Flex?
        let info: Info?
    }
    struct SeriesInfo: Decodable, Sendable {
        let plot: Flex?
        let genre: Flex?
        let cover: Flex?
        let backdrop_path: FlexList?
        let releaseDate: Flex?
        let rating: Flex?
        let youtube_trailer: Flex?
        let cast: Flex?
        let director: Flex?
        let tmdb: Flex?
    }

    let seasons: [Season]?
    let info: SeriesInfo?
    let episodes: [String: [Episode]]

    private enum CodingKeys: String, CodingKey { case seasons, info, episodes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seasons = try? c.decode([Season].self, forKey: .seasons)
        info = try? c.decode(SeriesInfo.self, forKey: .info)
        if let d = try? c.decode([String: [Episode]].self, forKey: .episodes) { episodes = d }
        else if let a = try? c.decode([[Episode]].self, forKey: .episodes) {
            var d: [String: [Episode]] = [:]
            for (i, group) in a.enumerated() { d[String(i + 1)] = group }
            episodes = d
        } else { episodes = [:] }
    }
}
