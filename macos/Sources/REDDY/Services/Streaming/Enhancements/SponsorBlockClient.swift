import CryptoKit
import Foundation

/// A stretch of a video that people marked (start and end in seconds).
struct SponsorSpan: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var category: String
    var uuid: String
}

enum SponsorVideoID {
    /// A YouTube video identifier: 11 characters of letters, digits, "-" and "_".
    static func valid(_ id: String) -> Bool {
        id.count == 11 && id.unicodeScalars.allSatisfy { ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) || $0 == "-" || $0 == "_" }
    }

    /// The first four hex characters of the identifier's SHA-256: the only thing about the video that is ever sent. Many thousands of videos share any one prefix.
    static func hashPrefix(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(2).map { String(format: "%02x", $0) }.joined()
    }
}

/// Where the marked segments of a video come from. Replaced in tests, so nothing touches the network.
protocol SponsorSegmentsFetching: Sendable {
    /// The segments of this video: [] when there are none, nil when the service could not be asked or its answer could not be used.
    func segments(forVideoID id: String) async -> [SponsorSpan]?
}

/// The one place the sponsor skipping uses the network. It is reached only from the page message handler, which has already checked that the
/// enhancement is on, agreed to, not restricted (kids or locked) and that the message came from the YouTube page. It asks by the FIRST FOUR
/// CHARACTERS of a hash of the video identifier, never the identifier, over https, to one fixed host, with no cookies, no cache, no account
/// and no headers beyond a JSON accept, and it keeps nothing about the request. Every failure is silent.
struct SponsorBlockClient: SponsorSegmentsFetching {
    static let host = "sponsor.ajay.app"
    static let categories = ["sponsor"]

    /// How a request is made; replaced in tests.
    var transport: @Sendable (URL) async throws -> (Data, Int) = SponsorBlockClient.send

    /// The request for a video's segments. Only the hash prefix is in it.
    static func requestURL(videoID: String) -> URL? {
        guard SponsorVideoID.valid(videoID) else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = host
        parts.path = "/api/skipSegments/" + SponsorVideoID.hashPrefix(videoID)
        let list = (try? String(data: JSONEncoder().encode(categories), encoding: .utf8)) ?? "[\"sponsor\"]"
        parts.queryItems = [URLQueryItem(name: "categories", value: list), URLQueryItem(name: "actionTypes", value: "[\"skip\"]")]
        return parts.url
    }

    func segments(forVideoID id: String) async -> [SponsorSpan]? {
        guard let url = Self.requestURL(videoID: id) else { return nil }
        do {
            let (data, status) = try await transport(url)
            if status == 404 { return [] }
            guard status == 200, data.count <= 1_000_000 else { return nil }
            return Self.parse(data, videoID: id)
        } catch {
            return nil
        }
    }

    /// The answer holds the segments of every video that shares the prefix; only this video's are taken, and every number and word in them is checked.
    static func parse(_ data: Data, videoID: String) -> [SponsorSpan]? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        guard let mine = list.first(where: { ($0["videoID"] as? String) == videoID }), let raw = mine["segments"] as? [[String: Any]] else { return [] }
        var out: [SponsorSpan] = []
        for item in raw {
            guard let pair = item["segment"] as? [Any], pair.count == 2, let start = (pair[0] as? NSNumber)?.doubleValue, let end = (pair[1] as? NSNumber)?.doubleValue,
                  start.isFinite, end.isFinite, start >= 0, end > start, end - start >= 0.5, end <= 86_400,
                  let category = item["category"] as? String, categories.contains(category),
                  let uuid = item["UUID"] as? String, uuid.count <= 100 else { continue }
            if let action = item["actionType"] as? String, action != "skip" { continue }
            out.append(SponsorSpan(start: start, end: end, category: category, uuid: uuid))
        }
        out.sort { $0.start < $1.start }
        // Overlapping segments become one, so a skip never lands inside another.
        var merged: [SponsorSpan] = []
        for segment in out {
            if var last = merged.last, segment.start < last.end { last.end = max(last.end, segment.end); merged[merged.count - 1] = last } else { merged.append(segment) }
        }
        return Array(merged.prefix(100))
    }

    private static func send(_ url: URL) async throws -> (Data, Int) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: SameHostOnly(url.host ?? ""), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// A redirect to another website is refused.
    private final class SameHostOnly: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let host: String
        init(_ host: String) { self.host = host }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url?.host == host && request.url?.scheme == "https" ? request : nil)
        }
    }
}
