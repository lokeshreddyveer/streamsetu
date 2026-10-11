import Foundation
import CryptoKit

/// M3U playlists, remote or imported from a file. Parsed incrementally from disk; secrets come from the Keychain.
final class M3UProvider: SourceProvider, @unchecked Sendable {
    let source: PlaylistSource
    private let http: HTTPClient
    private let credentials: CredentialStore
    private let localFile: URL?
    private let lock = NSLock()
    private var loaded: Loaded?

    struct Loaded: Sendable {
        var channels: [Channel]
        var movies: [Movie]
        var categories: [CatalogCategory]
        var epgURLs: [String]
        var skipped: Int
    }

    private let headers: SourceHeaders

    init(source: PlaylistSource, http: HTTPClient, credentials: CredentialStore, localFile: URL? = nil, headers: SourceHeaders = SourceHeaders()) {
        self.headers = headers
        self.source = source; self.http = http; self.credentials = credentials; self.localFile = localFile
    }

    func validate() async throws -> SourceCapabilities {
        let l = try await load()
        return SourceCapabilities(live: !l.channels.isEmpty, movies: !l.movies.isEmpty, series: false,
                                  epg: !l.epgURLs.isEmpty || source.epgURL != nil)
    }

    func categories(_ kind: ContentKind) async throws -> [CatalogCategory] {
        try await load().categories.filter { $0.kind == kind }
    }

    func channels() -> AsyncThrowingStream<[Channel], Error> {
        .producing { [self] c in
            for batch in try await load().channels.chunked(into: 2000) { try Task.checkCancellation(); c.yield(batch) }
        }
    }

    func movies() -> AsyncThrowingStream<[Movie], Error> {
        .producing { [self] c in
            for batch in try await load().movies.chunked(into: 2000) { try Task.checkCancellation(); c.yield(batch) }
        }
    }

    func epgLocation() -> URL? {
        if let e = source.epgURL, let u = URL(string: e) { return u }
        return lock.withLock { loaded?.epgURLs.first.flatMap(URL.init(string:)) }
    }

    func streamURL(kind: ContentKind, ref: String) throws -> URL {
        guard let u = URL(string: ref), SourceURLValidator.isPlayableScheme(u) else { throw SourceError.invalidResponse("Invalid stream address") }
        return u
    }

    // MARK: loading

    func load() async throws -> Loaded {
        let cached = lock.withLock { loaded }
        if let cached { return cached }

        let fileURL: URL
        var temp: URL?
        var baseURL: URL?
        if let localFile {
            fileURL = localFile
        } else {
            guard let ref = source.credentialRef, let secret = try credentials.load(ref: ref)?.url ?? Optional(source.baseURL),
                  let url = URL(string: secret) else { throw SourceError.credentialsMissing }
            baseURL = url
            do {
                var request = http.builder.get(url)
                headers.apply(to: &request)
                let r = try await http.downloadWithRetry(request, maxBytes: http.config.maxPlaylistBytes)
                guard let f = r.fileURL else { throw SourceError.invalidResponse("Empty response") }
                fileURL = f; temp = f
            } catch let e as NetworkError { throw SourceError.network(e) }
        }
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }

        let result = try await Task.detached(priority: .utility) { [source] in
            try Self.parse(file: fileURL, base: baseURL, source: source)
        }.value
        lock.withLock { loaded = result }
        return result
    }

    static func parse(file: URL, base: URL?, source: PlaylistSource) throws -> Loaded {
        let fh = try FileHandle(forReadingFrom: file)
        defer { try? fh.close() }
        let head = try fh.read(upToCount: 16 * 1024) ?? Data()
        try fh.seek(toOffset: 0)

        // A JSON playlist (or an HDHomeRun lineup) is converted to M3U text first and read the usual way.
        if JSONPlaylist.looksLikeJSON(head) {
            guard let converted = try JSONPlaylist.convert(file: file) else { throw SourceError.invalidResponse("This JSON file isn't a playlist: no entries with a stream address.") }
            defer { try? FileManager.default.removeItem(at: converted) }
            return try parse(file: converted, base: base, source: source)
        }

        switch M3UValidator.detect(head: head) {
        case .invalid: throw SourceError.invalidResponse("This doesn't look like an M3U playlist.")
        case .hlsManifest:
            // A single stream rather than a catalog: expose it as one channel.
            let name = base?.deletingPathExtension().lastPathComponent ?? file.deletingPathExtension().lastPathComponent
            let url = base?.absoluteString ?? ""
            var used: [String: Int] = [:]
            let ch = makeChannel(M3UEntry(name: name.isEmpty ? "Stream" : name, url: url), source: source, order: 0, used: &used)
            return Loaded(channels: url.isEmpty ? [] : [ch], movies: [], categories: [], epgURLs: [], skipped: 0)
        case .catalog: break
        }

        var parser = M3UStreamParser()
        var channels: [Channel] = [], movies: [Movie] = []
        var used: [String: Int] = [:]
        var skipped = 0
        var categoryNames: [String: (kind: ContentKind, name: String)] = [:]
        var order = 0

        func consume(_ e: M3UEntry) {
            guard let v = M3UValidator.validate(e, base: base), !MetadataNormalizer.isSeparator(v.name) else { skipped += 1; return }
            let isMovie = URL(string: v.url)?.path.contains("/movie/") ?? false
            if isMovie {
                let m = makeMovie(v, source: source, used: &used)
                if let cid = m.categoryID, let cn = m.categoryName { categoryNames[cid] = (.movie, cn) }
                movies.append(m)
            } else if URL(string: v.url)?.path.contains("/series/") ?? false {
                skipped += 1   // episode lists need a structured source (Xtream); not guessed from flat M3U
            } else {
                let c = makeChannel(v, source: source, order: order, used: &used)
                order += 1
                if let cid = c.categoryID, let cn = c.categoryName { categoryNames[cid] = (.channel, cn) }
                channels.append(c)
            }
        }

        while let chunk = try fh.read(upToCount: 256 * 1024), !chunk.isEmpty {
            parser.feed(chunk, emit: consume)
            try Task.checkCancellation()
        }
        parser.finish(emit: consume)

        let cats = categoryNames.map { id, v in
            CatalogCategory(id: id, sourceID: source.id, kind: v.kind, providerID: v.name, name: v.name, sortOrder: 0)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .enumerated().map { var c = $1; c.sortOrder = $0; return c }
        return Loaded(channels: channels, movies: movies, categories: cats, epgURLs: parser.header.epgURLs,
                      skipped: skipped + parser.skippedLines)
    }

    // MARK: mapping

    /// Stable id from tvg-id + normalized name + group (not the URL, which may carry a rotating token).
    static func providerID(_ e: M3UEntry, used: inout [String: Int]) -> String {
        let key = "\(e.tvgID ?? "")|\(MetadataNormalizer.normalize(e.name))|\(MetadataNormalizer.normalize(e.groupTitle ?? ""))"
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let n = used[digest, default: 0]
        used[digest] = n + 1
        return n == 0 ? digest : "\(digest)-\(n)"
    }

    static func categoryFor(_ e: M3UEntry, source: PlaylistSource, kind: ContentKind) -> (id: String, name: String)? {
        guard let g = e.groupTitle else { return nil }
        let name = CategoryNormalizer.clean(g)
        // M3U has no category ids, so the group title *as written* is the identity. Normalizing it would silently merge
        // "News" and "NEWS", or "UK | Sports" and "UK - Sports", into one folder.
        return (CatalogCategory.makeID(source: source.id, kind: kind, provider: name), name)
    }

    static func makeChannel(_ e: M3UEntry, source: PlaylistSource, order: Int, used: inout [String: Int]) -> Channel {
        let pid = providerID(e, used: &used)
        let name = MetadataNormalizer.cleanDisplay(e.name)
        let norm = MetadataNormalizer.normalize(name)
        let cat = categoryFor(e, source: source, kind: .channel)
        return Channel(id: ItemID.make(source: source.id, kind: .channel, provider: pid), sourceID: source.id, providerID: pid,
                       name: name, normalizedName: norm, categoryID: cat?.id, categoryName: cat?.name, logoURL: e.logo,
                       epgID: e.tvgID, language: e.language, country: e.country ?? CategoryNormalizer.countryPrefix(name),
                       resolutionHint: MetadataNormalizer.qualityLabel(norm), sortOrder: order, streamRef: e.url, groupKey: nil)
    }

    static func makeMovie(_ e: M3UEntry, source: PlaylistSource, used: inout [String: Int]) -> Movie {
        let pid = providerID(e, used: &used)
        let title = MetadataNormalizer.cleanDisplay(e.name)
        let cat = categoryFor(e, source: source, kind: .movie)
        return Movie(id: ItemID.make(source: source.id, kind: .movie, provider: pid), sourceID: source.id, providerID: pid,
                     title: title, normalizedTitle: MetadataNormalizer.normalize(title), overview: nil, posterURL: e.logo,
                     backdropURL: nil, releaseYear: MetadataNormalizer.year(from: title), durationSeconds: nil, genre: nil,
                     rating: nil, categoryID: cat?.id, categoryName: cat?.name, streamRef: e.url, addedAt: nil, detailFetchedAt: nil)
    }
}
