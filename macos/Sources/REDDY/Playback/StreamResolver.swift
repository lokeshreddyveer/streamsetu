import Foundation

/// Turns a catalog item into a playable request at the moment of playback, using the source's current
/// credentials. Short-lived or rotating stream URLs are therefore never stored.
final class StreamResolver: Sendable {
    let catalog: CatalogRepository
    let sources: SourceManager
    let history: HistoryRepository
    /// Where a saved copy of a movie or episode is found, when there is one.
    let localFiles: LocalFiles

    init(catalog: CatalogRepository, sources: SourceManager, history: HistoryRepository, localFiles: LocalFiles = LocalFiles()) {
        self.catalog = catalog; self.sources = sources; self.history = history; self.localFiles = localFiles
    }

    private func provider(_ id: UUID) throws -> SourceProvider {
        guard let s = try catalog.source(id: id) else { throw SourceError.invalidResponse("This source no longer exists.") }
        return try sources.makeProvider(for: s)
    }

    /// The real address behind a `PortalLink`, asked of the portal at this moment.
    func finalURL(for link: URL, sourceID: UUID) async throws -> URL {
        guard let (kind, ref) = PortalLink.parse(link) else { return link }
        return try await provider(sourceID).resolveLink(kind: kind, ref: ref)
    }

    func resolve(channel c: Channel) throws -> PlaybackRequest {
        let url = try provider(c.sourceID).streamURL(kind: .channel, ref: c.streamRef)
        var r = PlaybackRequest(itemID: c.id, kind: .channel, sourceID: c.sourceID, title: c.name, subtitle: c.categoryName,
                                artworkURL: c.logoURL, url: url, isLive: true)
        r.headers = sources.headers(for: c.sourceID, host: url.host).fields
        return r
    }

    /// A past programme of `c` from the provider's archive. Nil when the provider has none for this channel.
    func resolveCatchup(channel c: Channel, program p: EPGProgram, utcOffsetMinutes: Int) throws -> PlaybackRequest? {
        guard c.archiveDays > 0, let url = try provider(c.sourceID).catchupURL(ref: c.streamRef, start: p.start,
                                                                                 durationMinutes: Int((p.end.timeIntervalSince(p.start) / 60).rounded(.up)) + 1,
                                                                                 utcOffsetMinutes: utcOffsetMinutes) else { return nil }
        var r = PlaybackRequest(itemID: "\(c.id)|catchup|\(Int(p.start.timeIntervalSince1970))", kind: .channel, sourceID: c.sourceID,
                                title: "\(c.name) · \(p.title)", subtitle: "Catch-up · " + p.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()),
                                artworkURL: c.logoURL, url: url, isLive: false)
        r.isCatchup = true
        r.headers = sources.headers(for: c.sourceID, host: url.host).fields
        return r
    }

    func resolve(movie m: Movie, resume: Bool = true, allowLocal: Bool = true) throws -> PlaybackRequest {
        if allowLocal, let saved = localFiles.url(for: m.id) {
            var r = PlaybackRequest(itemID: m.id, kind: .movie, sourceID: m.sourceID, title: m.title,
                                    subtitle: [m.releaseYear.map(String.init), "Saved on this device"].compactMap { $0 }.joined(separator: " · "),
                                    artworkURL: m.backdropURL ?? m.posterURL, url: saved, isLive: false)
            if resume, let p = try history.progress(for: m.id), !p.completed { r.startPosition = p.positionSeconds }
            return r
        }
        let url = try provider(m.sourceID).streamURL(kind: .movie, ref: m.streamRef)
        var r = PlaybackRequest(itemID: m.id, kind: .movie, sourceID: m.sourceID, title: m.title,
                                subtitle: [m.releaseYear.map(String.init), m.categoryName].compactMap { $0 }.joined(separator: " · "),
                                artworkURL: m.backdropURL ?? m.posterURL, url: url, isLive: false)
        if resume, let p = try history.progress(for: m.id), !p.completed { r.startPosition = p.positionSeconds }
        r.headers = sources.headers(for: m.sourceID, host: url.host).fields
        return r
    }

    func resolve(episode e: Episode, series: Series, resume: Bool = true, allowLocal: Bool = true) throws -> PlaybackRequest {
        if allowLocal, let saved = localFiles.url(for: e.id) {
            var r = PlaybackRequest(itemID: e.id, kind: .episode, sourceID: series.sourceID, title: series.title,
                                    subtitle: "S\(e.seasonNumber) E\(e.episodeNumber) · \(e.title)", artworkURL: e.imageURL ?? series.backdropURL ?? series.posterURL,
                                    url: saved, isLive: false, seriesID: series.id)
            if resume, let p = try history.progress(for: e.id), !p.completed { r.startPosition = p.positionSeconds }
            return r
        }
        let url = try provider(series.sourceID).streamURL(kind: .episode, ref: e.streamRef)
        var r = PlaybackRequest(itemID: e.id, kind: .episode, sourceID: series.sourceID, title: series.title,
                                subtitle: "S\(e.seasonNumber) E\(e.episodeNumber) · \(e.title)",
                                artworkURL: e.imageURL ?? series.backdropURL ?? series.posterURL, url: url, isLive: false, seriesID: series.id)
        if resume, let p = try history.progress(for: e.id), !p.completed { r.startPosition = p.positionSeconds }
        r.headers = sources.headers(for: series.sourceID, host: url.host).fields
        return r
    }
}
