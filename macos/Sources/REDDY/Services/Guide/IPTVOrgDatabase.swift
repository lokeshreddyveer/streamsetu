import Foundation

// The public channel database (iptv-org, Unlicense): static JSON files. Whole files are downloaded and matched locally; no per-channel request, no identifier, no library content ever leaves the device.
// Licence rules enforced here: the block list is applied FAIL CLOSED (no block list, no enrichment); a blocked, closed or adult record is never matched; logos are third-party images and are only ever URLs.

struct IPTVOrgChannel: Sendable, Equatable, Decodable {
    var id: String
    var name: String
    var altNames: [String]
    var country: String?
    var categories: [String]
    var isNSFW: Bool
    var closed: String?
    enum CodingKeys: String, CodingKey { case id, name, country, categories, closed; case altNames = "alt_names"; case isNSFW = "is_nsfw" }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        altNames = try c.decodeIfPresent([String].self, forKey: .altNames) ?? []
        country = try c.decodeIfPresent(String.self, forKey: .country)
        categories = try c.decodeIfPresent([String].self, forKey: .categories) ?? []
        isNSFW = try c.decodeIfPresent(Bool.self, forKey: .isNSFW) ?? false
        closed = try c.decodeIfPresent(String.self, forKey: .closed)
    }
    init(id: String, name: String, altNames: [String] = [], country: String? = nil, categories: [String] = [], isNSFW: Bool = false, closed: String? = nil) {
        self.id = id; self.name = name; self.altNames = altNames; self.country = country; self.categories = categories; self.isNSFW = isNSFW; self.closed = closed
    }
}

struct IPTVOrgLogo: Sendable, Equatable, Decodable {
    var channel: String
    var url: String
    var width: Int
    var height: Int
    var format: String?
    var tags: [String]
    enum CodingKeys: String, CodingKey { case channel, url, width, height, format, tags }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        channel = try c.decode(String.self, forKey: .channel)
        url = try c.decode(String.self, forKey: .url)
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        format = try c.decodeIfPresent(String.self, forKey: .format)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
    init(channel: String, url: String, width: Int, height: Int, format: String? = nil, tags: [String] = []) {
        self.channel = channel; self.url = url; self.width = width; self.height = height; self.format = format; self.tags = tags
    }
}

struct IPTVOrgFeed: Sendable, Equatable, Decodable {
    var channel: String
    var isMain: Bool
    var languages: [String]
    var timezones: [String]
    enum CodingKeys: String, CodingKey { case channel, languages, timezones; case isMain = "is_main" }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        channel = try c.decode(String.self, forKey: .channel)
        isMain = try c.decodeIfPresent(Bool.self, forKey: .isMain) ?? false
        languages = try c.decodeIfPresent([String].self, forKey: .languages) ?? []
        timezones = try c.decodeIfPresent([String].self, forKey: .timezones) ?? []
    }
    init(channel: String, isMain: Bool, languages: [String], timezones: [String]) { self.channel = channel; self.isMain = isMain; self.languages = languages; self.timezones = timezones }
}

private struct BlockEntry: Decodable { var channel: String }

enum IPTVOrgError: Error, Equatable, LocalizedError {
    case blocklistUnavailable, databaseUnavailable
    case rateLimited, breakerOpen, notEnabled
    var errorDescription: String? {
        switch self {
        case .blocklistUnavailable: "The public channel database's block list could not be loaded, so nothing was matched."
        case .databaseUnavailable: "The public channel database has not been downloaded yet."
        case .rateLimited: "The public channel database was refreshed recently; it is checked once a day."
        case .breakerOpen: "The public channel database is not answering; it will be tried again later."
        case .notEnabled: "The public channel database is switched off."
        }
    }
}

/// The in-memory index. Built only through `build`, which refuses to build without a readable block list.
struct IPTVOrgIndex: Sendable {
    let channels: [String: IPTVOrgChannel]
    let blocked: Set<String>
    private let byName: [String: [String]]          // normalised name or alternative name -> ids
    private let logos: [String: [IPTVOrgLogo]]
    private let feeds: [String: [IPTVOrgFeed]]

    /// `blocklist` nil or not decodable as the list -> throws (fail closed). An empty list is not accepted either: the real list has hundreds of entries, so an empty one means a broken download.
    static func build(channels: [IPTVOrgChannel], blocklist: Data?, logos: [IPTVOrgLogo] = [], feeds: [IPTVOrgFeed] = []) throws -> IPTVOrgIndex {
        guard let blocklist, let entries = try? JSONDecoder().decode([BlockEntry].self, from: blocklist), !entries.isEmpty else { throw IPTVOrgError.blocklistUnavailable }
        let blocked = Set(entries.map { $0.channel })
        var byID: [String: IPTVOrgChannel] = [:]
        var byName: [String: [String]] = [:]
        for c in channels where !blocked.contains(c.id) {
            byID[c.id] = c
            var seen = Set<String>()
            for n in [c.name] + c.altNames {
                let k = ChannelNormalizer.name(n).key
                if !k.isEmpty, seen.insert(k).inserted { byName[k, default: []].append(c.id) }
            }
        }
        var logoMap: [String: [IPTVOrgLogo]] = [:]
        for l in logos where byID[l.channel] != nil { logoMap[l.channel, default: []].append(l) }
        var feedMap: [String: [IPTVOrgFeed]] = [:]
        for f in feeds where byID[f.channel] != nil { feedMap[f.channel, default: []].append(f) }
        return IPTVOrgIndex(channels: byID, blocked: blocked, byName: byName, logos: logoMap, feeds: feedMap)
    }

    func ids(forName key: String) -> [String] { byName[key] ?? [] }
    func logos(for id: String) -> [IPTVOrgLogo] { logos[id] ?? [] }
    func feeds(for id: String) -> [IPTVOrgFeed] { feeds[id] ?? [] }
    var count: Int { channels.count }
}

struct IPTVOrgEnrichment: Sendable, Equatable {
    var dbID: String
    var country: String?
    var languages: [String]
    var categories: [String]
    var timezones: [String]
    var logoURL: String?
    var matchedBy: String       // "id", "name+country", "name"
    var confidence: Double
}

/// Matches a library channel against the index. Order: (a) tvg id equals the database id, (b) the normalised name equals a database name or alternative name (name only: no country or language filter, first usable record wins). Closed, blocked and adult records and restricted channels are never matched.
enum IPTVOrgEnricher {
    static func match(name: String, tvgID: String?, country: String?, restricted: Bool, index: IPTVOrgIndex) -> IPTVOrgEnrichment? {
        if restricted { return nil }
        func usable(_ id: String) -> IPTVOrgChannel? {
            guard !index.blocked.contains(id), let c = index.channels[id], !c.isNSFW, c.closed == nil, !c.categories.contains("xxx") else { return nil }
            return c
        }
        if let tvg = tvgID?.trimmingCharacters(in: .whitespaces), !tvg.isEmpty {
            let base = tvg.split(separator: "@").first.map(String.init) ?? tvg
            if index.blocked.contains(base) { return nil }
            if let c = usable(base) { return make(c, "id", 0.95, index) }
        }
        let key = ChannelNormalizer.name(name)
        guard !key.isEmpty else { return nil }
        let ids = index.ids(forName: key.key)
        guard !ids.isEmpty else { return nil }
        // Name only (owner policy): no country or language filter, the first usable record in database order wins; a record with a logo is preferred over one without.
        let cands = ids.compactMap(usable)
        guard let first = cands.first else { return nil }
        let pick = cands.first(where: { bestLogo(index.logos(for: $0.id)) != nil }) ?? first
        return make(pick, "name", 0.65, index)
    }

    private static func make(_ c: IPTVOrgChannel, _ by: String, _ conf: Double, _ index: IPTVOrgIndex) -> IPTVOrgEnrichment {
        let feeds = index.feeds(for: c.id)
        let main = feeds.first(where: { $0.isMain }) ?? feeds.first
        return IPTVOrgEnrichment(dbID: c.id, country: c.country, languages: main?.languages ?? [], categories: c.categories, timezones: main?.timezones ?? [],
                                 logoURL: bestLogo(index.logos(for: c.id))?.url, matchedBy: by, confidence: conf)
    }

    /// Current logo (no "old" tag), at least 128 px wide, https only; PNG or WebP first, then the larger one.
    static func bestLogo(_ logos: [IPTVOrgLogo]) -> IPTVOrgLogo? {
        let ok = logos.filter { $0.url.hasPrefix("https://") && !$0.tags.contains("old") && $0.width >= 128 }
        func rank(_ l: IPTVOrgLogo) -> Int { switch l.format?.uppercased() { case "PNG", "WEBP": 0; case "SVG": 2; default: 1 } }
        return ok.min { (rank($0), -$0.width) < (rank($1), -$1.width) }
    }
}
