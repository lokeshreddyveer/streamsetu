import Foundation

struct MusicSkipSegment: Hashable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var category: String
    func contains(_ t: TimeInterval) -> Bool { t >= start && t < end - 0.5 }
}

/// Finds the parts of a YouTube-sourced track that are not music (intros, sponsor reads, silence) through the SponsorBlock community database.
/// Only the first four hex characters of the SHA-256 of the video id are sent, so the server never learns which video is playing.
/// Everything here is best effort: any failure means "no segments".
actor MusicSegmentSkipper {
    static let categories = ["music_offtopic", "intro", "outro", "sponsor", "selfpromo"]
    private static let maxCached = 200

    private let http: MusicHTTP
    private let baseURL: String
    private var cache: [String: [MusicSkipSegment]] = [:]

    init(http: MusicHTTP = MusicHTTP(), baseURL: String = "https://sponsor.ajay.app") {
        self.http = http
        self.baseURL = baseURL
    }

    func segments(forVideoID id: String) async -> [MusicSkipSegment] {
        if let c = cache[id] { return c }
        guard let url = URL(string: baseURL + "/api/skipSegments/" + Self.hashPrefix(id)) else { return [] }
        let cats = "[" + Self.categories.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        var result: [MusicSkipSegment] = []
        if let data = try? await http.get(url, query: ["categories": cats, "actionTypes": "[\"skip\"]"]) {
            result = Self.parse(data, videoID: id)
        }
        if cache.count >= Self.maxCached { cache.removeAll() }
        cache[id] = result
        return result
    }

    /// Convenience for the player: the page URL of a stream or track.
    func segments(forPageURL page: String?) async -> [MusicSkipSegment] {
        guard let id = Self.videoID(from: page) else { return [] }
        return await segments(forVideoID: id)
    }

    // MARK: pure helpers

    /// The app's own SponsorBlock prefix rule, so the two never drift apart.
    nonisolated static func hashPrefix(_ videoID: String) -> String { SponsorVideoID.hashPrefix(videoID) }

    /// The 11 character YouTube id from a watch, short, embed, shorts, live or music.youtube.com link.
    nonisolated static func videoID(from page: String?) -> String? {
        guard let page, let comps = URLComponents(string: page), let host = comps.host?.lowercased() else { return nil }
        func valid(_ s: String?) -> String? {
            guard let s, s.count == 11, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
            return s
        }
        if host == "youtu.be" || host.hasSuffix(".youtu.be") { return valid(comps.path.split(separator: "/").first.map(String.init)) }
        guard host.contains("youtube.com") || host.contains("youtube-nocookie.com") else { return nil }
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, let ok = valid(v) { return ok }
        let parts = comps.path.split(separator: "/").map(String.init)
        if parts.count >= 2, ["embed", "shorts", "live", "v"].contains(parts[0]) { return valid(parts[1]) }
        return nil
    }

    nonisolated static func parse(_ data: Data, videoID: String) -> [MusicSkipSegment] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        var out: [MusicSkipSegment] = []
        for entry in list where (entry["videoID"] as? String) == videoID {
            for seg in (entry["segments"] as? [[String: Any]]) ?? [] {
                if let action = seg["actionType"] as? String, action != "skip" { continue }
                guard let pair = seg["segment"] as? [Any], pair.count == 2,
                      let a = (pair[0] as? NSNumber)?.doubleValue, let b = (pair[1] as? NSNumber)?.doubleValue, b > a else { continue }
                out.append(MusicSkipSegment(start: a, end: b, category: (seg["category"] as? String) ?? ""))
            }
        }
        return out.sorted { $0.start < $1.start }
    }
}
