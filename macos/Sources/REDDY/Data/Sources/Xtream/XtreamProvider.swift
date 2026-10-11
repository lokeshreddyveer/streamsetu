import Foundation

final class XtreamProvider: SourceProvider, @unchecked Sendable {
    let source: PlaylistSource
    private let client: XtreamClient
    private let account: XtreamAccount
    private let mapper: XtreamMapper
    private let formats: [String]

    /// Credentials are loaded from the Keychain by the caller (`SourceManager`), never read from the database.
    init(source: PlaylistSource, account: XtreamAccount, http: HTTPClient) {
        self.source = source
        self.account = account
        self.client = XtreamClient(account: account, http: http)
        self.mapper = XtreamMapper(source: source)
        self.formats = source.capabilities.outputFormats
    }

    func validate() async throws -> SourceCapabilities {
        let info = try await client.accountInfo()
        async let live = client.liveCategories()
        async let vod = client.vodCategories()
        async let ser = client.seriesCategories()
        let (l, v, s) = try await (live, vod, ser)
        return SourceCapabilities(live: !l.isEmpty, movies: !v.isEmpty, series: !s.isEmpty, epg: true,
                                  outputFormats: info.allowed_output_formats?.values ?? [])
    }

    private func names(_ dtos: [XtreamCategoryDTO]) -> [String: String] {
        Dictionary(dtos.compactMap { d in d.category_id?.nonEmpty.map { ($0, d.category_name?.nonEmpty.map(CategoryNormalizer.clean) ?? "Category \($0)") } },
                   uniquingKeysWith: { a, _ in a })
    }

    func categories(_ kind: ContentKind) async throws -> [CatalogCategory] { try await categoryFetch(kind).categories }

    func categoryFetch(_ kind: ContentKind) async throws -> CategoryFetch {
        let action: String
        switch kind {
        case .channel: action = "get_live_categories"
        case .movie: action = "get_vod_categories"
        case .series: action = "get_series_categories"
        case .episode: return CategoryFetch(categories: [], providerCount: 0, rejected: [])
        }
        let r = try await client.categoryList(action)
        return mapper.categoryFetch(r.items, kind: kind, listed: r.listed, rejected: r.rejected)
    }

    func channels() -> AsyncThrowingStream<[Channel], Error> {
        .producing { [client, mapper, names] c in
            let cats = names(try await client.liveCategories())
            let all = mapper.channels(try await client.liveStreams(), names: cats)
            for b in all.chunked(into: 2000) { try Task.checkCancellation(); c.yield(b) }
        }
    }

    func movies() -> AsyncThrowingStream<[Movie], Error> {
        .producing { [client, mapper, names] c in
            let cats = names(try await client.vodCategories())
            let all = mapper.movies(try await client.vodStreams(), names: cats)
            for b in all.chunked(into: 2000) { try Task.checkCancellation(); c.yield(b) }
        }
    }

    func series() -> AsyncThrowingStream<[Series], Error> {
        .producing { [client, mapper, names] c in
            let cats = names(try await client.seriesCategories())
            let all = mapper.series(try await client.seriesList(), names: cats)
            for b in all.chunked(into: 2000) { try Task.checkCancellation(); c.yield(b) }
        }
    }

    func movieDetail(_ movie: Movie) async throws -> MovieDetail {
        mapper.movieDetail(try await client.vodInfo(id: movie.providerID))
    }

    func seriesDetail(_ series: Series) async throws -> SeriesDetail {
        mapper.seriesDetail(try await client.seriesInfo(id: series.providerID), for: series)
    }

    func epgLocation() -> URL? {
        if let e = source.epgURL, let u = URL(string: e) { return u }
        return account.epgURL
    }

    /// Xtream's archive address: `/timeshift/<user>/<pass>/<minutes>/<yyyy-MM-dd:HH-mm>/<id>.ts`, with the start in the provider's clock.
    func catchupURL(ref: String, start: Date, durationMinutes: Int, utcOffsetMinutes: Int) throws -> URL? {
        let u = URLUtilities.encode(account.user), p = URLUtilities.encode(account.pass)
        let stamp = Self.catchupStamp(start, utcOffsetMinutes: utcOffsetMinutes)
        let ext = (formats.isEmpty || formats.contains("ts")) ? "ts" : "m3u8"
        guard let url = URL(string: account.base + "/timeshift/\(u)/\(p)/\(max(1, durationMinutes))/\(stamp)/\(ref).\(ext)") else { throw NetworkError.invalidURL }
        return url
    }

    static func catchupStamp(_ date: Date, utcOffsetMinutes: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: utcOffsetMinutes * 60) ?? TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d:%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// Built at playback time so the current credentials/format are always used.
    func streamURL(kind: ContentKind, ref: String) throws -> URL {
        let u = URLUtilities.encode(account.user), p = URLUtilities.encode(account.pass)
        let path: String
        switch kind {
        case .channel:
            // MPEG-TS is played through the local HLS bridge; use HLS only when TS is not offered.
            let ext = (formats.isEmpty || formats.contains("ts")) ? "ts" : "m3u8"
            path = "/live/\(u)/\(p)/\(ref).\(ext)"
        case .movie: path = "/movie/\(u)/\(p)/\(ref)"
        case .episode: path = "/series/\(u)/\(p)/\(ref)"
        case .series: throw SourceError.unsupported("direct series playback")
        }
        guard let url = URL(string: account.base + path) else { throw NetworkError.invalidURL }
        return url
    }
}
