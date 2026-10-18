import Foundation

/// DTO -> domain entities. Drops invalid records instead of failing the whole import.
struct XtreamMapper: Sendable {
    let source: PlaylistSource

    func categories(_ dtos: [XtreamCategoryDTO], kind: ContentKind) -> [CatalogCategory] { categoryFetch(dtos, kind: kind, listed: dtos.count, rejected: []).categories }

    /// Maps provider categories. An entry without an id is unusable and reported. An entry with an id but no name is kept
    /// under a neutral name, because its items still belong to it. A repeated id keeps its first entry.
    func categoryFetch(_ dtos: [XtreamCategoryDTO], kind: ContentKind, listed: Int, rejected: [String]) -> CategoryFetch {
        var out: [CatalogCategory] = [], seen = Set<String>(), reasons = rejected
        for (i, d) in dtos.enumerated() {
            guard let pid = d.category_id?.nonEmpty else { reasons.append("entry \(i + 1): no category_id"); continue }
            guard seen.insert(pid).inserted else { reasons.append("category_id \(pid): listed twice, kept the first"); continue }
            let raw = d.category_name?.nonEmpty
            let name = raw.map(CategoryNormalizer.clean) ?? "Category \(pid)"
            out.append(CatalogCategory(id: CatalogCategory.makeID(source: source.id, kind: kind, provider: pid), sourceID: source.id,
                                       kind: kind, providerID: pid, name: name, sortOrder: out.count))
        }
        return CategoryFetch(categories: out, providerCount: listed, rejected: reasons)
    }

    /// Days of catch-up a channel offers: 0 unless the provider flags an archive, and then the number it states (at least 1).
    static func archiveDays(flag: Int?, duration: Int?) -> Int {
        guard flag == 1 else { return 0 }
        return min(30, max(1, duration ?? 3))
    }

    func channels(_ dtos: [XtreamLiveDTO], names: [String: String]) -> [Channel] {
        dtos.enumerated().compactMap { i, d in
            guard let pid = d.stream_id?.nonEmpty, let raw = d.name?.nonEmpty else { return nil }
            let name = MetadataNormalizer.cleanDisplay(raw)
            guard !MetadataNormalizer.isSeparator(name) else { return nil }
            let norm = MetadataNormalizer.normalize(name)
            let cid = d.category_id?.nonEmpty
            return Channel(id: ItemID.make(source: source.id, kind: .channel, provider: pid), sourceID: source.id, providerID: pid,
                           name: name, normalizedName: norm,
                           categoryID: cid.map { CatalogCategory.makeID(source: source.id, kind: .channel, provider: $0) },
                           categoryName: cid.map { names[$0] ?? "Category \($0)" }, logoURL: d.stream_icon?.nonEmpty, epgID: d.epg_channel_id?.nonEmpty,
                           language: nil, country: CategoryNormalizer.countryPrefix(name),
                           resolutionHint: MetadataNormalizer.qualityLabel(norm), sortOrder: d.num?.int ?? i, streamRef: pid, groupKey: nil,
                           archiveDays: Self.archiveDays(flag: d.tv_archive?.int, duration: d.tv_archive_duration?.int))
        }
    }

    func movies(_ dtos: [XtreamVODDTO], names: [String: String]) -> [Movie] {
        return dtos.compactMap { d -> Movie? in
            guard let pid = d.stream_id?.nonEmpty, let raw = d.name?.nonEmpty else { return nil }
            let title = MetadataNormalizer.cleanDisplay(raw)
            let cid = d.category_id?.nonEmpty
            let ext = d.container_extension?.nonEmpty ?? "mp4"
            return Movie(id: ItemID.make(source: source.id, kind: .movie, provider: pid), sourceID: source.id, providerID: pid,
                         title: title, normalizedTitle: MetadataNormalizer.normalize(title), overview: nil,
                         posterURL: d.stream_icon?.nonEmpty, backdropURL: nil,
                         releaseYear: d.year?.int ?? MetadataNormalizer.year(from: title), durationSeconds: nil, genre: nil,
                         rating: d.rating?.nonEmpty,
                         categoryID: cid.map { CatalogCategory.makeID(source: source.id, kind: .movie, provider: $0) },
                         categoryName: cid.map { names[$0] ?? "Category \($0)" }, streamRef: "\(pid).\(ext)",
                         addedAt: d.added?.double.map { Date(timeIntervalSince1970: $0) }, detailFetchedAt: nil)
        }
    }

    func series(_ dtos: [XtreamSeriesDTO], names: [String: String]) -> [Series] {
        dtos.compactMap { d in
            guard let pid = d.series_id?.nonEmpty, let raw = d.name?.nonEmpty else { return nil }
            let title = MetadataNormalizer.cleanDisplay(raw)
            let cid = d.category_id?.nonEmpty
            let rel = d.releaseDate?.nonEmpty ?? d.release_date?.nonEmpty
            return Series(id: ItemID.make(source: source.id, kind: .series, provider: pid), sourceID: source.id, providerID: pid,
                          title: title, normalizedTitle: MetadataNormalizer.normalize(title), overview: d.plot?.nonEmpty,
                          posterURL: d.cover?.nonEmpty, backdropURL: d.backdrop_path?.values.first.nilIfEmpty, genre: d.genre?.nonEmpty,
                          releaseYear: rel.flatMap { Int($0.prefix(4)) } ?? MetadataNormalizer.year(from: title), rating: d.rating?.nonEmpty,
                          categoryID: cid.map { CatalogCategory.makeID(source: source.id, kind: .series, provider: $0) },
                          categoryName: cid.map { names[$0] ?? "Category \($0)" },
                          addedAt: d.last_modified?.double.map { Date(timeIntervalSince1970: $0) }, lastMetadataRefresh: nil)
        }
    }

    /// The cast and directors a series list names, by series id.
    func seriesPeople(_ dtos: [XtreamSeriesDTO]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for d in dtos {
            guard let pid = d.series_id?.nonEmpty else { continue }
            let names = ProviderExtras.names(d.cast?.nonEmpty) + ProviderExtras.names(d.director?.nonEmpty)
            if !names.isEmpty { out[ItemID.make(source: source.id, kind: .series, provider: pid)] = names }
        }
        return out
    }

    func movieDetail(_ dto: XtreamVODInfoDTO) -> MovieDetail {
        let i = dto.info
        let rel = i?.releasedate?.nonEmpty ?? i?.release_date?.nonEmpty
        return MovieDetail(overview: i?.plot?.nonEmpty ?? i?.description?.nonEmpty, backdropURL: i?.backdrop_path?.values.first.nilIfEmpty,
                           posterURL: i?.movie_image?.nonEmpty ?? i?.cover_big?.nonEmpty, genre: i?.genre?.nonEmpty,
                           releaseYear: rel.flatMap { Int($0.prefix(4)) }, durationSeconds: i?.duration_secs?.double, rating: i?.rating?.nonEmpty,
                           extras: ProviderExtras.make(trailer: i?.youtube_trailer?.nonEmpty, cast: i?.cast?.nonEmpty ?? i?.actors?.nonEmpty, director: i?.director?.nonEmpty,
                                                       country: i?.country?.nonEmpty, age: i?.age?.nonEmpty ?? i?.mpaa_rating?.nonEmpty, tmdb: i?.tmdb_id?.nonEmpty))
    }

    func seriesDetail(_ dto: XtreamSeriesInfoDTO, for series: Series) -> SeriesDetail {
        var s = series
        if let i = dto.info {
            s.overview = i.plot?.nonEmpty ?? s.overview
            s.genre = i.genre?.nonEmpty ?? s.genre
            s.posterURL = i.cover?.nonEmpty ?? s.posterURL
            s.backdropURL = i.backdrop_path?.values.first.nilIfEmpty ?? s.backdropURL
            s.rating = i.rating?.nonEmpty ?? s.rating
        }
        s.lastMetadataRefresh = Date()
        let extras = ProviderExtras.make(trailer: dto.info?.youtube_trailer?.nonEmpty, cast: dto.info?.cast?.nonEmpty, director: dto.info?.director?.nonEmpty,
                                         country: nil, age: nil, tmdb: dto.info?.tmdb?.nonEmpty)

        var episodes: [Episode] = []
        var seasonNumbers = Set<Int>()
        for (key, list) in dto.episodes {
            for (idx, e) in list.enumerated() {
                guard let epid = e.id?.nonEmpty else { continue }
                let sn = e.season?.int ?? Int(key) ?? 1
                seasonNumbers.insert(sn)
                let ext = e.container_extension?.nonEmpty ?? "mp4"
                episodes.append(Episode(
                    id: ItemID.make(source: source.id, kind: .episode, provider: epid), seriesID: series.id,
                    seasonID: seasonID(series.id, sn), seasonNumber: sn, providerEpisodeID: epid,
                    episodeNumber: e.episode_num?.int ?? (idx + 1),
                    title: e.title?.nonEmpty.map(MetadataNormalizer.cleanDisplay) ?? "Episode \(e.episode_num?.int ?? idx + 1)",
                    overview: e.info?.plot?.nonEmpty, imageURL: e.info?.movie_image?.nonEmpty,
                    durationSeconds: e.info?.duration_secs?.double, streamRef: "\(epid).\(ext)"))
            }
        }
        for sdto in dto.seasons ?? [] { if let n = sdto.season_number?.int { seasonNumbers.insert(n) } }
        let names = Dictionary(uniqueKeysWithValues: (dto.seasons ?? []).compactMap { d in d.season_number?.int.map { ($0, d.name?.nonEmpty) } })
        let seasons = seasonNumbers.sorted().map {
            Season(id: seasonID(series.id, $0), seriesID: series.id, number: $0, name: names[$0] ?? nil)
        }
        episodes.sort { ($0.seasonNumber, $0.episodeNumber) < ($1.seasonNumber, $1.episodeNumber) }   // numeric, never lexicographic
        return SeriesDetail(series: s, seasons: seasons, episodes: episodes, extras: extras)
    }

    private func seasonID(_ seriesID: String, _ n: Int) -> String { "\(seriesID)|season|\(n)" }
}
