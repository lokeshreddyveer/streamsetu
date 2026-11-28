import Foundation

// Similarity and recommendations from the two services whose accounts Music already holds: Last.fm (similar tracks and artists, tags) and ListenBrainz
// (collaborative-filtering recommendations by recording MBID, plus a metadata lookup to name them). Read-only: nothing here submits a listen, so Private listening
// cannot leak through it. Each answer is a plain candidate; turning candidates into songs that can actually play is done elsewhere, on the person's own sources.

struct MusicSimilarCandidate: Hashable, Sendable {
    enum Origin: String, Sendable { case lastFMTrack, lastFMArtist, lastFMTag, listenBrainz }
    var title: String?
    var artist: String
    var mbid: String?
    /// 0...1 where the service gives one (Last.fm "match"); ListenBrainz scores are rescaled against the best of the batch.
    var score: Double
    var origin: Origin
    /// First release year when the service says so (ListenBrainz does), for a decade filter.
    var year: Int? = nil
}

struct MusicTagWeight: Hashable, Sendable { var name: String; var count: Int }

enum MusicSimilarityParsers {
    /// Last.fm sends a list as a JSON array, but a list of one as a bare object.
    private static func list(_ any: Any?) -> [[String: Any]] {
        if let a = any as? [[String: Any]] { return a }
        if let o = any as? [String: Any] { return [o] }
        return []
    }

    private static func text(_ any: Any?) -> String? {
        if let s = any as? String, !s.isEmpty { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private static func number(_ any: Any?) -> Double {
        if let d = any as? Double { return d }
        if let s = any as? String, let d = Double(s) { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        return 0
    }

    private static func artistName(_ any: Any?) -> String? {
        if let s = any as? String { return s.isEmpty ? nil : s }
        if let o = any as? [String: Any] { return text(o["name"]) ?? text(o["#text"]) }
        return nil
    }

    static func similarTracks(_ j: [String: Any]) -> [MusicSimilarCandidate] {
        list((j["similartracks"] as? [String: Any])?["track"]).compactMap { t in
            guard let title = text(t["name"]), let artist = artistName(t["artist"]) else { return nil }
            return MusicSimilarCandidate(title: title, artist: artist, mbid: text(t["mbid"]), score: min(1, max(0, number(t["match"]))), origin: .lastFMTrack)
        }
    }

    static func similarArtists(_ j: [String: Any]) -> [MusicSimilarCandidate] {
        list((j["similarartists"] as? [String: Any])?["artist"]).compactMap { a in
            guard let name = text(a["name"]) else { return nil }
            return MusicSimilarCandidate(title: nil, artist: name, mbid: text(a["mbid"]), score: min(1, max(0, number(a["match"]))), origin: .lastFMArtist)
        }
    }

    static func topTags(_ j: [String: Any]) -> [MusicTagWeight] {
        list((j["toptags"] as? [String: Any])?["tag"]).compactMap { t in
            guard let n = text(t["name"]) else { return nil }
            return MusicTagWeight(name: n, count: Int(number(t["count"])))
        }
    }

    /// The tracks of a tag, best first (the service orders by tag count, so rank stands in for a score).
    static func tagTopTracks(_ j: [String: Any]) -> [MusicSimilarCandidate] {
        let rows = list((j["tracks"] as? [String: Any])?["track"])
        return rows.enumerated().compactMap { i, t in
            guard let title = text(t["name"]), let artist = artistName(t["artist"]) else { return nil }
            return MusicSimilarCandidate(title: title, artist: artist, mbid: text(t["mbid"]), score: max(0.1, 1 - Double(i) / Double(max(1, rows.count))), origin: .lastFMTag)
        }
    }

    /// ListenBrainz `payload.mbids[]` with scores, rescaled so the best is 1.
    static func recommendations(_ j: [String: Any]) -> [(mbid: String, score: Double)] {
        let rows = list((j["payload"] as? [String: Any])?["mbids"])
        let raw = rows.compactMap { r -> (String, Double)? in text(r["recording_mbid"]).map { ($0, number(r["score"])) } }
        let top = raw.map(\.1).max() ?? 0
        return raw.map { ($0.0, top > 0 ? $0.1 / top : 0.5) }
    }

    /// ListenBrainz `/1/metadata/recording` keyed by recording MBID.
    static func recordingNames(_ j: [String: Any]) -> [String: (title: String, artist: String, year: Int?)] {
        var out: [String: (String, String, Int?)] = [:]
        for (mbid, v) in j {
            guard let o = v as? [String: Any] else { continue }
            let rec = o["recording"] as? [String: Any]
            let artist = ((o["artist"] as? [String: Any])?["name"] as? String) ?? ((rec?["artist"] as? [String: Any])?["name"] as? String) ?? (o["artist_credit_name"] as? String)
            let title = (rec?["name"] as? String) ?? (o["recording_name"] as? String) ?? (o["title"] as? String)
            let year = (rec?["first_release_date"] as? String).flatMap { Int($0.prefix(4)) }
            if let title, let artist, !title.isEmpty, !artist.isEmpty { out[mbid] = (title, artist, year) }
        }
        return out
    }
}

/// A service that fails or refuses is left alone for a while (like Navidrome's per-agent cooldown), so one bad hour does not slow every screen.
actor MusicSourceCooldown {
    static let shared = MusicSourceCooldown()
    private var until: [String: Date] = [:]
    func allowed(_ source: String, now: Date = Date()) -> Bool { (until[source] ?? .distantPast) <= now }
    func fail(_ source: String, seconds: TimeInterval = 600, now: Date = Date()) { until[source] = now.addingTimeInterval(seconds) }
    func reset() { until = [:] }
}

struct LastFMReadClient: Sendable {
    /// Last.fm error codes: 6 "not found" (retry by name), 29 and 11/16 "slow down or try later", 10/26 key refused.
    static let notFound = 6
    static func isCoolingError(_ code: Int) -> Bool { [11, 16, 29, 10, 26].contains(code) }

    var client = LastFMClient()
    var key: @Sendable () -> String? = { LastFMClient().appKeys()?.key ?? BuiltInLastFM.apiKey() }

    var isAvailable: Bool { key() != nil }

    private func get(_ method: String, _ params: [String: String]) async throws -> [String: Any] {
        guard let k = key() else { throw ScrobbleSendError.signedOut }
        var all = params
        all["method"] = method; all["api_key"] = k; all["format"] = "json"
        var c = URLComponents(); c.queryItems = all.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = URL(string: client.endpoint.absoluteString + "?" + (c.percentEncodedQuery ?? "")) else { throw ScrobbleSendError.network("bad address") }
        let reply = try await ScrobbleHTTP.send(client.http, url: url, method: "GET")
        let obj = (try? JSONSerialization.jsonObject(with: reply.data)) as? [String: Any]
        if let obj, let code = obj["error"] as? Int { throw LastFMAPIError(code: code, message: (obj["message"] as? String) ?? "error \(code)") }
        guard (200..<300).contains(reply.status), let obj else { throw ScrobbleSendError.network("HTTP \(reply.status)") }
        return obj
    }

    /// Asks by MusicBrainz id first and, when Last.fm does not know that id or returns nothing, again by name: an id is missing far more often than the music.
    private func withNameFallback(_ method: String, primary: [String: String], fallback: [String: String]?, parse: ([String: Any]) -> [MusicSimilarCandidate]) async throws -> [MusicSimilarCandidate] {
        var attempts = [primary]
        if let fallback { attempts.append(fallback) }
        var last: Error?
        for (i, params) in attempts.enumerated() {
            do {
                let got = parse(try await get(method, params))
                if !got.isEmpty || i == attempts.count - 1 { return got }
            } catch let e as LastFMAPIError where e.code == Self.notFound && i < attempts.count - 1 { last = e; continue }
            catch { throw error }
        }
        if let last { throw last }
        return []
    }

    func similarTracks(artist: String, title: String, mbid: String?, limit: Int = 30) async throws -> [MusicSimilarCandidate] {
        let byName = ["artist": artist, "track": title, "autocorrect": "1", "limit": String(limit)]
        let primary = mbid.map { ["mbid": $0, "autocorrect": "1", "limit": String(limit)] } ?? byName
        return try await withNameFallback("track.getSimilar", primary: primary, fallback: mbid == nil ? nil : byName, parse: MusicSimilarityParsers.similarTracks)
    }

    func similarArtists(name: String, mbid: String?, limit: Int = 20) async throws -> [MusicSimilarCandidate] {
        let byName = ["artist": name, "autocorrect": "1", "limit": String(limit)]
        let primary = mbid.map { ["mbid": $0, "autocorrect": "1", "limit": String(limit)] } ?? byName
        return try await withNameFallback("artist.getSimilar", primary: primary, fallback: mbid == nil ? nil : byName, parse: MusicSimilarityParsers.similarArtists)
    }

    func trackTags(artist: String, title: String) async throws -> [MusicTagWeight] {
        MusicSimilarityParsers.topTags(try await get("track.getTopTags", ["artist": artist, "track": title, "autocorrect": "1"]))
    }

    func artistTags(name: String) async throws -> [MusicTagWeight] {
        MusicSimilarityParsers.topTags(try await get("artist.getTopTags", ["artist": name, "autocorrect": "1"]))
    }

    func tagTracks(_ tag: String, limit: Int = 30) async throws -> [MusicSimilarCandidate] {
        MusicSimilarityParsers.tagTopTracks(try await get("tag.getTopTracks", ["tag": tag, "limit": String(limit)]))
    }
}

struct ListenBrainzReadClient: Sendable {
    var client = ListenBrainzClient()

    var user: String? { client.username }
    var isAvailable: Bool { client.isConnected && (client.username?.isEmpty == false) }

    /// The person's own collaborative-filtering recommendations. An empty list is a normal answer: ListenBrainz answers 204 until it has generated some (a new
    /// account, too few listens), so a sparse history simply has none yet.
    func recommendations(count: Int = 25) async throws -> [(mbid: String, score: Double)] {
        guard let user, !user.isEmpty else { return [] }
        let enc = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? user
        let url = ListenBrainzClient.endpoint(client.root, "cf/recommendation/user/\(enc)/recording?count=\(count)")
        let reply = try await ScrobbleHTTP.send(client.http, url: url, method: "GET")
        if reply.status == 204 || reply.status == 404 { return [] }
        guard (200..<300).contains(reply.status), let obj = (try? JSONSerialization.jsonObject(with: reply.data)) as? [String: Any] else { throw ScrobbleSendError.network("HTTP \(reply.status)") }
        return MusicSimilarityParsers.recommendations(obj)
    }

    func recordingNames(_ mbids: [String]) async throws -> [String: (title: String, artist: String, year: Int?)] {
        guard !mbids.isEmpty else { return [:] }
        let url = ListenBrainzClient.endpoint(client.root, "metadata/recording/?recording_mbids=" + mbids.prefix(25).joined(separator: ",") + "&inc=artist")
        let reply = try await ScrobbleHTTP.send(client.http, url: url, method: "GET")
        guard (200..<300).contains(reply.status), let obj = (try? JSONSerialization.jsonObject(with: reply.data)) as? [String: Any] else { throw ScrobbleSendError.network("HTTP \(reply.status)") }
        return MusicSimilarityParsers.recordingNames(obj)
    }

    func candidates(count: Int = 25) async throws -> [MusicSimilarCandidate] {
        let recs = try await recommendations(count: count)
        let names = try await recordingNames(recs.map(\.mbid))
        return recs.compactMap { r in names[r.mbid].map { MusicSimilarCandidate(title: $0.title, artist: $0.artist, mbid: r.mbid, score: r.score, origin: .listenBrainz, year: $0.year) } }
    }
}
