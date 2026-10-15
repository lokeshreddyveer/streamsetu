import Foundation

/// Maps Plex Media Server JSON into catalog entries. Pure, so it is tested without a server.
struct PlexMapper: Sendable {
    let source: PlaylistSource
    let base: String
    let token: String

    /// The picture's address, without the token: addresses are stored and shown in places a secret must not reach. The image cache adds the token as a header for this server.
    func art(_ path: String?) -> String? {
        guard let p = path, !p.isEmpty else { return nil }
        return "\(base)\(p)"
    }

    func partKey(_ d: [String: Any]) -> (key: String, ext: String)? {
        guard let part = ((d["Media"] as? [[String: Any]])?.first?["Part"] as? [[String: Any]])?.first, let key = part["key"] as? String else { return nil }
        let ext = (part["container"] as? String) ?? (key as NSString).pathExtension
        return (key, ext.isEmpty ? "mp4" : ext)
    }

    func tags(_ d: [String: Any], _ k: String) -> [String] { ((d[k] as? [[String: Any]]) ?? []).compactMap { $0["tag"] as? String } }

    func category(_ d: [String: Any], kind: ContentKind) -> (id: String, name: String) {
        let g = tags(d, "Genre").first ?? (kind == .movie ? "Movies" : "Series")
        return (CatalogCategory.makeID(source: source.id, kind: kind, provider: g), g)
    }

    func movies(_ items: [[String: Any]]) -> [Movie] {
        items.compactMap { d in
            guard let id = (d["ratingKey"] as? String) ?? (d["ratingKey"] as? Int).map(String.init), let raw = d["title"] as? String, let part = partKey(d) else { return nil }
            let title = MetadataNormalizer.cleanDisplay(raw)
            let cat = category(d, kind: .movie)
            return Movie(id: ItemID.make(source: source.id, kind: .movie, provider: id), sourceID: source.id, providerID: id, title: title,
                         normalizedTitle: MetadataNormalizer.normalize(title), overview: d["summary"] as? String, posterURL: art(d["thumb"] as? String),
                         backdropURL: art(d["art"] as? String), releaseYear: d["year"] as? Int, durationSeconds: (d["duration"] as? Double).map { $0 / 1000 } ?? (d["duration"] as? Int).map { Double($0) / 1000 },
                         genre: tags(d, "Genre").first, rating: (d["rating"] as? Double).map { String(format: "%.1f", $0) }, categoryID: cat.id, categoryName: cat.name,
                         streamRef: part.key, addedAt: (d["addedAt"] as? Int).map { Date(timeIntervalSince1970: Double($0)) }, detailFetchedAt: nil)
        }
    }

    func series(_ items: [[String: Any]]) -> [Series] {
        items.compactMap { d in
            guard let id = (d["ratingKey"] as? String) ?? (d["ratingKey"] as? Int).map(String.init), let raw = d["title"] as? String else { return nil }
            let title = MetadataNormalizer.cleanDisplay(raw)
            let cat = category(d, kind: .series)
            return Series(id: ItemID.make(source: source.id, kind: .series, provider: id), sourceID: source.id, providerID: id, title: title,
                          normalizedTitle: MetadataNormalizer.normalize(title), overview: d["summary"] as? String, posterURL: art(d["thumb"] as? String),
                          backdropURL: art(d["art"] as? String), genre: tags(d, "Genre").first, releaseYear: d["year"] as? Int,
                          rating: (d["rating"] as? Double).map { String(format: "%.1f", $0) }, categoryID: cat.id, categoryName: cat.name,
                          addedAt: (d["addedAt"] as? Int).map { Date(timeIntervalSince1970: Double($0)) }, lastMetadataRefresh: nil)
        }
    }

    func episodes(_ items: [[String: Any]], series: Series, seasonNumber: Int) -> [Episode] {
        items.enumerated().compactMap { i, d in
            guard let id = (d["ratingKey"] as? String) ?? (d["ratingKey"] as? Int).map(String.init), let part = partKey(d) else { return nil }
            let n = (d["index"] as? Int) ?? (i + 1)
            let sn = (d["parentIndex"] as? Int) ?? seasonNumber
            return Episode(id: ItemID.make(source: source.id, kind: .episode, provider: id), seriesID: series.id, seasonID: "\(series.id)|season|\(sn)", seasonNumber: sn,
                           providerEpisodeID: id, episodeNumber: n, title: (d["title"] as? String).map(MetadataNormalizer.cleanDisplay) ?? "Episode \(n)",
                           overview: d["summary"] as? String, imageURL: art(d["thumb"] as? String),
                           durationSeconds: (d["duration"] as? Double).map { $0 / 1000 } ?? (d["duration"] as? Int).map { Double($0) / 1000 }, streamRef: part.key)
        }
    }

    func extras(_ d: [String: Any]) -> ProviderExtras? {
        let tmdb = ((d["Guid"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.first(where: { $0.hasPrefix("tmdb://") }).flatMap { Int($0.dropFirst(7)) }
        let e = ProviderExtras(trailerKey: nil, cast: Array(tags(d, "Role").prefix(15)), directors: tags(d, "Director"), country: tags(d, "Country").first,
                               ageRating: d["contentRating"] as? String, tmdbID: tmdb)
        return e.isEmpty && e.tmdbID == nil ? nil : e
    }
}
