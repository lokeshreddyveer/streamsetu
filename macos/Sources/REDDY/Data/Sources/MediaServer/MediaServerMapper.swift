import Foundation

/// Turns Jellyfin and Emby JSON into catalog entries. Pure functions, so they are tested without a server.
struct MediaServerMapper: Sendable {
    let source: PlaylistSource
    let base: String          // server address including any /emby prefix, no trailing slash

    func image(_ id: String, _ kind: String = "Primary", height: Int = 450) -> String { "\(base)/Items/\(id)/Images/\(kind)?maxHeight=\(height)" }

    func year(_ d: [String: Any]) -> Int? { (d["ProductionYear"] as? Int) ?? (d["PremiereDate"] as? String).flatMap { Int($0.prefix(4)) } }

    func rating(_ d: [String: Any]) -> String? { (d["CommunityRating"] as? Double).map { String(format: "%.1f", $0) } }

    func seconds(_ d: [String: Any]) -> Double? { (d["RunTimeTicks"] as? Double).map { $0 / 10_000_000 } ?? (d["RunTimeTicks"] as? Int).map { Double($0) / 10_000_000 } }

    func category(_ d: [String: Any], kind: ContentKind) -> (id: String, name: String) {
        let g = ((d["Genres"] as? [String])?.first).flatMap { $0.isEmpty ? nil : $0 } ?? (kind == .movie ? "Movies" : "Series")
        return (CatalogCategory.makeID(source: source.id, kind: kind, provider: g), g)
    }

    func movies(_ items: [[String: Any]]) -> [Movie] {
        items.compactMap { d in
            guard let pid = d["Id"] as? String, let raw = d["Name"] as? String, !raw.isEmpty else { return nil }
            let title = MetadataNormalizer.cleanDisplay(raw)
            let cat = category(d, kind: .movie)
            let ext = (d["Container"] as? String).flatMap { $0.split(separator: ",").first.map(String.init) } ?? "mp4"
            return Movie(id: ItemID.make(source: source.id, kind: .movie, provider: pid), sourceID: source.id, providerID: pid,
                         title: title, normalizedTitle: MetadataNormalizer.normalize(title), overview: d["Overview"] as? String,
                         posterURL: (d["ImageTags"] as? [String: Any])?["Primary"] != nil ? image(pid) : nil,
                         backdropURL: ((d["BackdropImageTags"] as? [Any])?.isEmpty == false) ? image(pid, "Backdrop", height: 720) : nil,
                         releaseYear: year(d), durationSeconds: seconds(d), genre: (d["Genres"] as? [String])?.first, rating: rating(d),
                         categoryID: cat.id, categoryName: cat.name, streamRef: "\(pid).\(ext)",
                         addedAt: (d["DateCreated"] as? String).flatMap(MediaServerDate.parse),
                         detailFetchedAt: nil)
        }
    }

    func series(_ items: [[String: Any]]) -> [Series] {
        items.compactMap { d in
            guard let pid = d["Id"] as? String, let raw = d["Name"] as? String, !raw.isEmpty else { return nil }
            let title = MetadataNormalizer.cleanDisplay(raw)
            let cat = category(d, kind: .series)
            return Series(id: ItemID.make(source: source.id, kind: .series, provider: pid), sourceID: source.id, providerID: pid,
                          title: title, normalizedTitle: MetadataNormalizer.normalize(title), overview: d["Overview"] as? String,
                          posterURL: (d["ImageTags"] as? [String: Any])?["Primary"] != nil ? image(pid) : nil,
                          backdropURL: ((d["BackdropImageTags"] as? [Any])?.isEmpty == false) ? image(pid, "Backdrop", height: 720) : nil,
                          genre: (d["Genres"] as? [String])?.first, releaseYear: year(d), rating: rating(d),
                          categoryID: cat.id, categoryName: cat.name,
                          addedAt: (d["DateCreated"] as? String).flatMap(MediaServerDate.parse),
                          lastMetadataRefresh: nil)
        }
    }

    func categories(_ list: [(id: String, name: String)], kind: ContentKind) -> [CatalogCategory] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .enumerated().map { CatalogCategory(id: $1.id, sourceID: source.id, kind: kind, providerID: $1.name, name: $1.name, sortOrder: $0) }
    }

    func episodes(_ items: [[String: Any]], series: Series) -> (seasons: [Season], episodes: [Episode]) {
        var eps: [Episode] = [], numbers = Set<Int>()
        for (i, d) in items.enumerated() {
            guard let epid = d["Id"] as? String else { continue }
            let sn = (d["ParentIndexNumber"] as? Int) ?? 1
            numbers.insert(sn)
            let n = (d["IndexNumber"] as? Int) ?? (i + 1)
            let ext = (d["Container"] as? String).flatMap { $0.split(separator: ",").first.map(String.init) } ?? "mp4"
            eps.append(Episode(id: ItemID.make(source: source.id, kind: .episode, provider: epid), seriesID: series.id, seasonID: seasonID(series.id, sn),
                               seasonNumber: sn, providerEpisodeID: epid, episodeNumber: n,
                               title: (d["Name"] as? String).map(MetadataNormalizer.cleanDisplay) ?? "Episode \(n)", overview: d["Overview"] as? String,
                               imageURL: (d["ImageTags"] as? [String: Any])?["Primary"] != nil ? image(epid, height: 300) : nil,
                               durationSeconds: seconds(d), streamRef: "\(epid).\(ext)"))
        }
        eps.sort { ($0.seasonNumber, $0.episodeNumber) < ($1.seasonNumber, $1.episodeNumber) }
        return (numbers.sorted().map { Season(id: seasonID(series.id, $0), seriesID: series.id, number: $0, name: nil) }, eps)
    }

    func extras(_ d: [String: Any]) -> ProviderExtras? {
        let people = (d["People"] as? [[String: Any]]) ?? []
        let cast = people.filter { ($0["Type"] as? String) == "Actor" }.compactMap { $0["Name"] as? String }
        let directors = people.filter { ($0["Type"] as? String) == "Director" }.compactMap { $0["Name"] as? String }
        let trailer = ((d["RemoteTrailers"] as? [[String: Any]])?.compactMap { $0["Url"] as? String }.first).flatMap { ProviderExtras.youTubeKey($0) }
        let tmdb = ((d["ProviderIds"] as? [String: Any])?["Tmdb"] as? String).flatMap { Int($0) }
        let e = ProviderExtras(trailerKey: trailer, cast: Array(cast.prefix(15)), directors: directors, country: nil,
                               ageRating: d["OfficialRating"] as? String, tmdbID: tmdb)
        return e.isEmpty && e.tmdbID == nil ? nil : e
    }

    private func seasonID(_ seriesID: String, _ n: Int) -> String { "\(seriesID)|season|\(n)" }
}

enum MediaServerDate {
    /// "2024-05-01T10:20:30.1234567Z": servers send up to seven fractional digits, which the formatter reads as milliseconds.
    static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s.split(separator: ".").first.map { String($0) + "Z" } ?? s) ?? f.date(from: s)
    }
}
