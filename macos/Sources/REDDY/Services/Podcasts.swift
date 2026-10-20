import Foundation

struct PodcastEpisode: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let summary: String
    let audioURL: URL
    let published: Date?
    let duration: TimeInterval?
    /// The id its resume point is kept under (the same as for any file played from an address).
    var itemID: String { LocalMedia.itemID(audioURL.absoluteString) }
}

struct PodcastFeed: Equatable, Sendable {
    var title = ""
    var author = ""
    var artwork: URL?
    var episodes: [PodcastEpisode] = []
}

struct PodcastSubscription: Identifiable, Codable, Equatable, Sendable {
    let feedURL: URL
    var title: String
    var author: String
    var artwork: URL?
    var id: String { feedURL.absoluteString }
}

/// Reads a podcast's RSS feed: the show, and its episodes newest first.
final class PodcastParser: NSObject, XMLParserDelegate {
    private var feed = PodcastFeed()
    private var path: [String] = []
    private var text = ""
    private var inItem = false
    private var item: [String: String] = [:]
    private var enclosure: URL?
    private var itemImage: URL?

    static func parse(_ data: Data) -> PodcastFeed? {
        let p = PodcastParser()
        let x = XMLParser(data: data)
        x.delegate = p
        guard x.parse(), !p.feed.title.isEmpty else { return nil }
        p.feed.episodes.sort { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        return p.feed
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        path.append(name); text = ""
        if name == "item" { inItem = true; item = [:]; enclosure = nil }
        if name == "enclosure", inItem, let s = a["url"], let u = URL(string: s) { enclosure = u }
        if name == "itunes:image", let s = a["href"], let u = URL(string: s), !inItem { feed.artwork = u }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { text += String(decoding: data, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer { path.removeLast() }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem {
            switch name {
            case "title", "description", "itunes:summary", "pubDate", "itunes:duration", "guid": if item[name] == nil || name != "description" { item[name] = value }
            case "item":
                inItem = false
                if let url = enclosure, let title = item["title"], !title.isEmpty {
                    feed.episodes.append(PodcastEpisode(id: item["guid"] ?? url.absoluteString, title: title, summary: Self.plain(item["itunes:summary"] ?? item["description"] ?? ""),
                                                        audioURL: url, published: item["pubDate"].flatMap(Self.date), duration: item["itunes:duration"].flatMap(Self.duration)))
                }
            default: break
            }
        } else if path.count >= 3 && path[path.count - 2] == "channel" || path.count == 2 {
            switch name {
            case "title" where feed.title.isEmpty: feed.title = value
            case "itunes:author" where feed.author.isEmpty: feed.author = value
            case "url" where path.dropLast().last == "image" && feed.artwork == nil: feed.artwork = URL(string: value)
            default: break
            }
        } else if name == "url", path.dropLast().last == "image", feed.artwork == nil { feed.artwork = URL(string: value) }
    }

    /// Show notes come with HTML in them; the list shows plain text.
    static func plain(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n").replacingOccurrences(of: "</p>", with: "\n")
        while let a = out.range(of: "<"), let b = out.range(of: ">", range: a.upperBound..<out.endIndex) { out.removeSubrange(a.lowerBound..<b.upperBound) }
        for (e, c) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] { out = out.replacingOccurrences(of: e, with: c) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func date(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// "1:02:03", "45:10" or a number of seconds.
    static func duration(_ s: String) -> TimeInterval? {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count == s.split(separator: ":").count else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

/// The shows the person follows, kept in preferences, and the ways of finding and reading them.
final class PodcastService: @unchecked Sendable {
    private let defaults: UserDefaults
    private let fetch: @Sendable (URL) async throws -> Data
    private let key = "podcasts.subscriptions"

    init(defaults: UserDefaults, fetch: @escaping @Sendable (URL) async throws -> Data = { url in
        var r = URLRequest(url: url, timeoutInterval: 20); r.setValue("StreamSetu", forHTTPHeaderField: "User-Agent")
        return try await URLSession.shared.data(for: r).0
    }) { self.defaults = defaults; self.fetch = fetch }

    func subscriptions() -> [PodcastSubscription] { defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([PodcastSubscription].self, from: $0) } ?? [] }
    private func save(_ list: [PodcastSubscription]) { defaults.set(try? JSONEncoder().encode(list), forKey: key) }

    func isSubscribed(_ feedURL: URL) -> Bool { subscriptions().contains { $0.feedURL == feedURL } }

    /// Reads the feed at this address.
    func load(_ feedURL: URL) async throws -> PodcastFeed {
        guard let feed = PodcastParser.parse(try await fetch(feedURL)) else { throw PodcastError.notAFeed }
        return feed
    }

    @discardableResult
    func subscribe(_ feedURL: URL) async throws -> PodcastSubscription {
        let feed = try await load(feedURL)
        let sub = PodcastSubscription(feedURL: feedURL, title: feed.title, author: feed.author, artwork: feed.artwork)
        save(subscriptions().filter { $0.feedURL != feedURL } + [sub])
        return sub
    }

    func unsubscribe(_ feedURL: URL) { save(subscriptions().filter { $0.feedURL != feedURL }) }

    /// Shows matching the words, from Apple's public podcast directory.
    func search(_ term: String) async throws -> [PodcastSubscription] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [URLQueryItem(name: "media", value: "podcast"), URLQueryItem(name: "limit", value: "25"), URLQueryItem(name: "term", value: term)]
        return Self.parseSearch(try await fetch(c.url!))
    }

    static func parseSearch(_ data: Data) -> [PodcastSubscription] {
        struct Reply: Decodable { struct R: Decodable { let collectionName: String?; let artistName: String?; let feedUrl: String?; let artworkUrl600: String? }; let results: [R] }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return [] }
        return reply.results.compactMap { r in
            guard let f = r.feedUrl.flatMap(URL.init(string:)), let name = r.collectionName else { return nil }
            return PodcastSubscription(feedURL: f, title: name, author: r.artistName ?? "", artwork: r.artworkUrl600.flatMap(URL.init(string:)))
        }
    }
}

enum PodcastError: Error, LocalizedError {
    case notAFeed
    var errorDescription: String? { "That address is not a podcast feed." }
}
