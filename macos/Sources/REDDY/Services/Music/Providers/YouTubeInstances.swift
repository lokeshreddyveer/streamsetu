import Foundation

/// Finds public Piped and Invidious servers, checks which ones really hand out audio today, and runs a request against the healthy ones with
/// fallback to the next. Public instances come and go and most are blocked by YouTube's bot check, so a server is only used after a live probe
/// (one stream lookup for a fixed, harmless video) came back with audio. Probe results are kept for 30 minutes; a server that fails during real
/// use is dropped until the next probe round. When no server is healthy the caller gets one clear error instead of waiting on dead hosts.
actor YouTubeInstances {
    enum Kind: String, Sendable { case piped, invidious }

    struct Health: Sendable, Equatable { var url: URL; var latency: Double }

    static let healthTTL: TimeInterval = 30 * 60
    /// When nothing was healthy the answer is remembered only briefly, so a recovered network is noticed soon.
    static let emptyTTL: TimeInterval = 3 * 60
    static let probeVideoID = "dQw4w9WgXcQ"
    static let probeSeconds: TimeInterval = 6
    static let maxCandidates = 24

    private let http: MusicHTTP
    private let fixed: [Kind: [URL]]
    private let now: @Sendable () -> Date
    private var healthy: [Kind: [Health]] = [:]
    private var checkedAt: [Kind: Date] = [:]
    private var inFlight: [Kind: Task<[Health], Never>] = [:]
    /// The person's own servers (settings), tried before any public one.
    let own: MusicOwnInstanceTracker

    /// `fixed` pins a list for a kind and skips discovery and probing (used by tests and by anyone who runs their own server).
    init(http: MusicHTTP = MusicHTTP(), fixed: [Kind: [URL]] = [:], now: @escaping @Sendable () -> Date = { Date() },
         own: MusicOwnInstanceTracker? = nil) {
        self.http = http
        self.fixed = fixed
        self.now = now
        self.own = own ?? MusicOwnInstanceTracker(http: http, now: now)
    }

    /// Last-resort servers, tried only after the directories gave nothing. They are probed like any other candidate.
    static let seeds: [Kind: [String]] = [
        .piped: ["https://pipedapi.kavin.rocks", "https://api.piped.private.coffee", "https://pipedapi.ducks.party"],
        .invidious: ["https://yt.chocolatemoo53.com", "https://inv.nadeko.net", "https://yewtu.be"]
    ]

    static let pipedRegistry = "https://piped-instances.kavin.rocks"
    static let pipedRegistryMirror = "https://raw.githubusercontent.com/TeamPiped/documentation/refs/heads/main/content/docs/public-instances/index.md"
    static let invidiousRegistry = "https://api.invidious.io/instances.json"
    static let invidiousRegistryMirror = "https://raw.githubusercontent.com/iv-org/documentation/master/docs/instances.md"

    func unavailableError(_ kind: Kind) -> MusicError {
        switch kind {
        case .piped: MusicError.network("No public Piped server can provide audio right now (YouTube is blocking them). Other sources are used instead.")
        case .invidious: MusicError.network("No public Invidious server can provide audio right now (YouTube is blocking them). Other sources are used instead.")
        }
    }

    /// Healthy servers, quickest first. Runs a probe round when the last one is older than the cache time.
    func ranked(_ kind: Kind) async -> [URL] {
        if let pinnedURLs = fixed[kind], !pinnedURLs.isEmpty { return pinnedURLs }
        let mine = await own.ready(kind)
        return mine + (await publicRanked(kind)).filter { !mine.contains($0) }
    }

    private func publicRanked(_ kind: Kind) async -> [URL] {
        if let pinnedURLs = fixed[kind], !pinnedURLs.isEmpty { return pinnedURLs }
        return await healthyList(kind).map(\.url)
    }

    /// Status of each own server for this kind (probes the ones with no recent result).
    func ownStatuses(_ kind: Kind) async -> [MusicOwnInstanceStatus] { await own.statuses(kind) }

    /// Runs `op` against healthy instances and returns the first success. Cancellation is passed straight through.
    func perform<T: Sendable>(_ kind: Kind, attempts: Int = 4, _ op: @Sendable (URL) async throws -> T) async throws -> T {
        var lastError: Error = unavailableError(kind)
        if fixed[kind]?.isEmpty ?? true, let own = try await performOwn(kind, op, lastError: &lastError) { return own }
        let list = await publicRanked(kind)
        guard !list.isEmpty else { throw lastError }
        for base in list.prefix(attempts) {
            let start = now()
            do {
                let value = try await op(base)
                record(kind, base, ok: true, seconds: now().timeIntervalSince(start))
                return value
            } catch MusicError.cancelled {
                throw MusicError.cancelled
            } catch is CancellationError {
                throw MusicError.cancelled
            } catch {
                record(kind, base, ok: false, seconds: 0)
                lastError = error
            }
        }
        throw lastError
    }

    /// Forgets every probe result so the next call probes again (a person pressing "retry").
    func invalidate() { healthy = [:]; checkedAt = [:]; let tracker = own; Task { await tracker.reset() } }

    private func record(_ kind: Kind, _ url: URL, ok: Bool, seconds: Double) {
        guard fixed[kind]?.isEmpty ?? true, var list = healthy[kind], let i = list.firstIndex(where: { $0.url == url }) else { return }
        if ok { list[i].latency = list[i].latency * 0.6 + seconds * 0.4 } else { list.remove(at: i) }
        healthy[kind] = list.sorted { $0.latency < $1.latency }
    }

    private func healthyList(_ kind: Kind) async -> [Health] {
        if let at = checkedAt[kind] {
            let ttl = (healthy[kind] ?? []).isEmpty ? Self.emptyTTL : Self.healthTTL
            if now().timeIntervalSince(at) < ttl { return healthy[kind] ?? [] }
        }
        if let running = inFlight[kind] { return await running.value }
        let http = self.http
        let task = Task<[Health], Never> { await Self.discoverHealthy(kind, http: http) }
        inFlight[kind] = task
        let result = await task.value
        inFlight[kind] = nil
        healthy[kind] = result
        checkedAt[kind] = now()
        return result
    }

    // MARK: discovery and probing

    /// Candidates from the live directory, its public mirror and the seeds, probed in parallel; only servers that gave audio are returned.
    static func discoverHealthy(_ kind: Kind, http: MusicHTTP) async -> [Health] {
        let candidates = await candidateList(kind, http: http)
        return await withTaskGroup(of: Health?.self) { group in
            for url in candidates {
                group.addTask {
                    let start = Date()
                    guard let ok = try? await ytmWithTimeout(probeSeconds, { await probe(kind, base: url, http: http) }), ok else { return nil }
                    return Health(url: url, latency: Date().timeIntervalSince(start))
                }
            }
            var out: [Health] = []
            for await h in group { if let h { out.append(h) } }
            return out.sorted { $0.latency < $1.latency }
        }
    }

    static func candidateList(_ kind: Kind, http: MusicHTTP) async -> [URL] {
        async let primary = registry(kind, mirror: false, http: http)
        async let mirror = registry(kind, mirror: true, http: http)
        let seedURLs = (seeds[kind] ?? []).compactMap(httpsURL)
        var seen = Set<String>(), out: [URL] = []
        for u in await primary + (await mirror) + seedURLs where seen.insert(u.absoluteString).inserted { out.append(u) }
        return Array(out.prefix(maxCandidates))
    }

    private static func registry(_ kind: Kind, mirror: Bool, http: MusicHTTP) async -> [URL] {
        let address: String
        switch (kind, mirror) {
        case (.piped, false): address = pipedRegistry
        case (.piped, true): address = pipedRegistryMirror
        case (.invidious, false): address = invidiousRegistry
        case (.invidious, true): address = invidiousRegistryMirror
        }
        guard let url = URL(string: address) else { return [] }
        let query: [String: String] = (kind == .invidious && !mirror) ? ["sort_by": "health"] : [:]
        guard let data = try? await ytmWithTimeout(5, { try await http.get(url, query: query) }) else { return [] }
        if mirror {
            let text = String(decoding: data, as: UTF8.self)
            return kind == .piped ? parsePipedMarkdown(text) : parseInvidiousMarkdown(text)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return kind == .piped ? parsePiped(obj) : parseInvidious(obj)
    }

    /// One stream lookup for a fixed video: the server is healthy only when it answers with at least one audio stream.
    static func probe(_ kind: Kind, base: URL, http: MusicHTTP) async -> Bool {
        switch kind {
        case .piped:
            guard let obj = try? await http.getObject(base.appendingPathComponent("streams").appendingPathComponent(probeVideoID)) else { return false }
            return !PipedProvider.parseStreams(obj).isEmpty
        case .invidious:
            guard let obj = try? await http.getObject(base.appendingPathComponent("api/v1/videos").appendingPathComponent(probeVideoID), query: ["local": "true"]) else { return false }
            return !InvidiousProvider.parseStreams(obj, base: base).isEmpty
        }
    }

    // MARK: registry parsing

    static func parsePiped(_ obj: Any) -> [URL] {
        let rows = (obj as? [[String: Any]]) ?? []
        return rows.compactMap { $0.str("api_url") }.compactMap(httpsURL).prefix(maxCandidates).map { $0 }
    }

    static func parseInvidious(_ obj: Any) -> [URL] {
        let rows = (obj as? [Any]) ?? []
        var out: [URL] = []
        for row in rows {
            guard let pair = row as? [Any], pair.count >= 2, let host = pair[0] as? String, let meta = pair[1] as? [String: Any] else { continue }
            guard (meta["type"] as? String) == "https", (meta["api"] as? Bool) == true, !isOverlayHost(host) else { continue }
            if let u = httpsURL("https://" + host) { out.append(u) }
            if out.count >= maxCandidates { break }
        }
        return out
    }

    /// The Piped documentation's table: "name | API address | location | CDN | users". The API address is the second cell.
    static func parsePipedMarkdown(_ text: String) -> [URL] {
        var out: [URL] = []
        for line in text.split(separator: "\n") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 3, let u = httpsURL(cells[1]), !isOverlayHost(u.host ?? "") else { continue }
            out.append(u)
        }
        return Array(out.prefix(maxCandidates))
    }

    /// The Invidious documentation's list: "* [host](https://host) ...". Yggdrasil, Tor and I2P mirrors are skipped.
    static func parseInvidiousMarkdown(_ text: String) -> [URL] {
        var out: [URL] = []
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("* [") || t.hasPrefix("- ["), let open = t.range(of: "](https://"),
                  let close = t[open.upperBound...].firstIndex(of: ")") else { continue }
            let address = "https://" + t[open.upperBound..<close]
            if let u = httpsURL(address), !isOverlayHost(u.host ?? "") { out.append(u) }
        }
        return Array(out.prefix(maxCandidates))
    }

    private static func isOverlayHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return [".onion", ".i2p", ".ygg", "-ygg.", ".loki"].contains { h.contains($0) } || h.hasSuffix(".b32.i2p")
    }

    static func httpsURL(_ s: String) -> URL? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        guard let u = URL(string: t), u.scheme == "https", u.host != nil else { return nil }
        return u
    }
}

// MARK: shared helpers for every YouTube-family audio provider

struct YouTubeCandidate: Sendable {
    var videoID: String; var title: String; var channel: String?; var durationMs: Int64?; var thumbnail: String?
}

enum YouTubeAudio {
    /// Search text used on every service: the song name and its first artist.
    static func query(for track: MusicTrack) -> String {
        [track.title, track.artists.first?.name].compactMap { $0 }.joined(separator: " ")
    }

    /// Scores candidates against the wanted track and returns the plausible ones, best first.
    static func rank(_ candidates: [YouTubeCandidate], for track: MusicTrack, providerID: String, limit: Int = 6) -> [MusicAudioSource] {
        let names = track.artists.map(\.name)
        var seen = Set<String>()
        let scored: [MusicAudioSource] = candidates.compactMap { c in
            guard !c.videoID.isEmpty, seen.insert(c.videoID).inserted else { return nil }
            let s = MusicTextMatch.score(trackTitle: track.title, artists: names, durationMs: track.durationMs,
                                         candidateTitle: c.title, candidateArtist: c.channel, candidateDurationMs: c.durationMs)
            return MusicAudioSource(id: c.videoID, providerID: providerID, title: c.title, artist: c.channel, album: nil, durationMs: c.durationMs,
                                    thumbnails: c.thumbnail.map { [MusicThumbnail(url: $0)] } ?? [],
                                    externalURL: "https://www.youtube.com/watch?v=\(c.videoID)", confidence: s)
        }
        return Array(scored.filter { $0.confidence >= 0.15 }.sorted { $0.confidence > $1.confidence }.prefix(limit))
    }

    /// Builds a stream from a mime type such as `audio/webm; codecs="opus"`. Returns nil for video or unusable entries.
    static func stream(url: String, mimeType: String, bitrateBps: Int?, sampleRate: Int? = nil, headers: [String: String] = [:]) -> MusicStream? {
        let mime = mimeType.lowercased()
        guard mime.hasPrefix("audio/"), url.hasPrefix("https://") || url.hasPrefix("http://") else { return nil }
        let kind = mime.dropFirst("audio/".count).prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
        let container = kind == "mp4" ? "m4a" : (kind.isEmpty ? "unknown" : kind)
        var codec = "unknown"
        if let r = mime.range(of: "codecs=") {
            let raw = mime[r.upperBound...].replacingOccurrences(of: "\"", with: "").split(separator: ",").first.map(String.init) ?? ""
            let c = raw.trimmingCharacters(in: .whitespaces)
            if c.hasPrefix("mp4a") { codec = "aac" } else if !c.isEmpty { codec = c }
        } else if container == "webm" { codec = "opus" } else if container == "m4a" { codec = "aac" }
        var kbps: Int? = nil
        if let b = bitrateBps, b > 0 { kbps = b >= 1000 ? b / 1000 : b }
        return MusicStream(url: url, codec: codec, container: container, proto: .progressive, bitrate: kbps,
                           sampleRate: sampleRate, headers: headers, expiresAt: expiry(of: url))
    }

    /// Signed media URLs carry `expire=<unix seconds>`.
    static func expiry(of url: String) -> Date? {
        guard let items = URLComponents(string: url)?.queryItems,
              let v = items.first(where: { $0.name == "expire" })?.value, let t = TimeInterval(v) else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    static func sortedByBitrate(_ streams: [MusicStream]) -> [MusicStream] {
        streams.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }
    }

    /// "3:45" or "1:02:03" to milliseconds.
    static func clock(_ s: String) -> Int64? {
        let n = s.split(separator: ":", omittingEmptySubsequences: false).count
        return (2...3).contains(n) ? MusicTime.parseMs(s) : nil
    }

    static func videoID(fromWatchPath path: String) -> String? {
        URLComponents(string: path)?.queryItems?.first { $0.name == "v" }?.value
    }
}
