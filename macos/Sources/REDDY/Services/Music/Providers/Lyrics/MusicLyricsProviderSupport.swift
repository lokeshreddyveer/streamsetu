import Foundation

/// A lyrics provider that works from the full request (video id, searched flag, resolved length) instead of just a track.
/// The track form below builds a plain request, so such a provider also works anywhere a `MusicLyricsProvider` is expected.
/// Throwing means ERROR (never cached as a miss); returning nil means a definitive "no lyrics".
protocol MusicLyricsRequestProvider: MusicLyricsProvider {
    /// False while the provider has nothing to talk to (the YouTube source before it is connected). The walk leaves it out.
    var isAvailable: Bool { get }
    func lyrics(for request: MusicLyricsRequest) async throws -> MusicLyrics?
}

extension MusicLyricsRequestProvider {
    var isAvailable: Bool { true }
    func lyrics(for track: MusicTrack) async throws -> MusicLyrics? { try await lyrics(for: MusicLyricsRequest.make(track: track)) }
}

enum MusicLyricsIO {
    static let appURL = "https://github.com/lokeshreddyveerabhadra/streamsetu"

    /// Runs `op` and gives up after `seconds`; a timeout is an error like any other transport failure.
    /// The caller is released at the deadline even when `op` ignores cancellation (a structured group would wait for it): the work is
    /// cancelled and abandoned, its late answer dropped.
    static func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await MusicDeadline.race(seconds: seconds, sleep: { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }, op, onTimeout: MusicError.network("timed out"))
    }

    static func object(_ http: MusicHTTP, _ url: URL, query: [String: String] = [:], headers: [String: String] = [:], timeout: Double) async throws -> Any {
        let data = try await withTimeout(timeout) { try await http.get(url, query: query, headers: headers) }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Any {
        guard let o = try? JSONSerialization.jsonObject(with: data) else { throw MusicError.network("unreadable answer") }
        return o
    }

    /// Same as `parse` but also accepts JSONP such as `callback({...})`.
    static func parseLoose(_ data: Data) throws -> Any {
        if let o = try? JSONSerialization.jsonObject(with: data) { return o }
        guard let s = String(data: data, encoding: .utf8), let a = s.firstIndex(of: "("), let b = s.lastIndex(of: ")"), a < b,
              let inner = String(s[s.index(after: a)..<b]).data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: inner)
        else { throw MusicError.network("unreadable answer") }
        return o
    }

    static func isNotModified(_ e: Error) -> Bool { (e as? MusicError) == .network("HTTP 304") }

    static func seconds(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    static func int64(_ any: Any?) -> Int64? {
        if let n = any as? NSNumber { return n.int64Value }
        if let s = any as? String { return Int64(s) ?? Double(s).map { Int64($0) } }
        return nil
    }

    static func decodeBase64Text(_ s: String) -> String? {
        let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let d = Data(base64Encoded: cleaned), let t = String(data: d, encoding: .utf8) else { return nil }
        return t
    }

}

/// Merges a second parse of the same song into a base list: for every base line with a time, the first line of the other list that
/// starts within 800 ms lends its words, translation and end time, only where the base lacks them.
enum MusicLyricsMux {
    static let window: Int64 = 800

    static func mux(base: [MusicLyricLine], other: [MusicLyricLine]) -> [MusicLyricLine] {
        base.map { line in
            guard let match = other.first(where: { abs($0.timeMs - line.timeMs) <= window }) else { return line }
            var l = line
            if (l.words ?? []).isEmpty, let w = match.words, !w.isEmpty { l.words = w }
            if (l.translation ?? "").isEmpty, let t = match.translation, !t.isEmpty { l.translation = t }
            if l.endMs == nil { l.endMs = match.endMs }
            if (l.romanized ?? "").isEmpty, let r = match.romanized { l.romanized = r; l.romanizedWords = match.romanizedWords }
            if l.voice == nil { l.voice = match.voice }
            return l
        }
    }
}
