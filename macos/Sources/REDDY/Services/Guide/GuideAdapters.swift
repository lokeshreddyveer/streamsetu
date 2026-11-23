import Foundation

/// A provider guide (the playlist's own XMLTV / Xtream `xmltv.php`) or a guide address the person added. Both read XMLTV; only the id, priority and credit differ.
struct XMLTVURLSource: EPGSource {
    let id: String
    let kind: GuideSourceKind
    let name: String
    let url: URL
    let priority: Int
    let fetcher: any GuideFileFetching
    var capabilities: Set<GuideCapability> { [.programmes, .channelList, .icons, .categories, .languages, .timezones] }

    func describe() -> GuideSourceInfo { GuideSourceInfo(name: name, host: url.host, kind: kind, creditKey: nil, consentText: nil) }

    func fetch(since: GuideValidators?, budget: GuideBudget) async throws -> GuideFetched {
        guard url.scheme == "https" || url.scheme == "http" else { throw NetworkError.unreadable }
        let r = try await fetcher.get(url, etag: since?.etag, lastModified: since?.lastModified, maxBytes: min(budget.limits.maxWireBytes, budget.maxBytesOnConstrainedNetwork ?? .max))
        return r
    }
    func open(_ f: GuideFetched) throws -> any GuideStream {
        guard let file = f.file else { throw GuideReadError.unreadable }
        return XMLTVFileStream(file: file)
    }
}

/// The public channel database as a guide source: channels, logos, categories, languages; never programmes.
final class IPTVOrgIndexSource: EPGSource, @unchecked Sendable {
    let id = "iptvorg-db"
    let kind = GuideSourceKind.publicIndex
    let priority = GuideSourceKind.publicIndex.defaultPriority
    var capabilities: Set<GuideCapability> { [.channelList, .icons, .categories, .languages, .timezones] }
    private let database: IPTVOrgDatabase
    private let loaded = LockedBox<IPTVOrgIndex?>(nil)
    init(database: IPTVOrgDatabase) { self.database = database }

    func describe() -> GuideSourceInfo {
        GuideSourceInfo(name: "Public channel database", host: "iptv-org.github.io", kind: .publicIndex, creditKey: "iptvorg",
                        consentText: "Downloads about 20 MB once a day to fill missing logos, countries and categories. Nothing from your library is sent.")
    }
    func fetch(since: GuideValidators?, budget: GuideBudget) async throws -> GuideFetched {
        try await database.refresh()
        loaded.value = try await database.loadIndex()      // throws when the block list is missing: fail closed
        return GuideFetched(file: nil, validators: GuideValidators(), status: 200, bytes: 0)
    }
    func open(_ f: GuideFetched) throws -> any GuideStream {
        guard let index = loaded.value else { throw IPTVOrgError.blocklistUnavailable }
        return IPTVOrgChannelStream(index: index)
    }
}

struct IPTVOrgChannelStream: GuideStream {
    let index: IPTVOrgIndex
    func read(window: ClosedRange<Date>, timeZone: GuideTimeZoneMode, limits: GuideLimits, onChannel: @escaping (GuideChannelRecord) -> Void,
              onBatch: @escaping ([GuideProgramme]) throws -> Void) throws -> GuideReadStats {
        var s = GuideReadStats()
        for c in index.channels.values.sorted(by: { $0.id < $1.id }) where !c.isNSFW && c.closed == nil {
            s.channels += 1
            if s.channels > limits.maxChannels { throw GuideReadError.tooManyChannels }
            onChannel(GuideChannelRecord(id: c.id, displayNames: [c.name] + c.altNames, icon: IPTVOrgEnricher.bestLogo(index.logos(for: c.id))?.url, lang: nil, countryHint: c.country))
        }
        return s
    }
}

/// Builds the adapters from the registry rows. A source whose address cannot be resolved (a provider without a guide address, a secret that is gone) is simply absent.
struct GuideSourceRegistry: Sendable {
    typealias URLResolver = @Sendable (SQLiteGuideRepository.SourceRow) -> URL?
    private(set) var sources: [any EPGSource]

    init(rows: [SQLiteGuideRepository.SourceRow], fetcher: any GuideFileFetching, resolveURL: URLResolver, publicIndex: IPTVOrgIndexSource? = nil) {
        var list: [any EPGSource] = []
        for r in rows where r.enabled {
            switch r.kind {
            case .provider, .userXMLTV:
                guard let u = resolveURL(r) else { continue }
                list.append(XMLTVURLSource(id: r.id, kind: r.kind, name: r.name, url: u, priority: r.priority, fetcher: fetcher))
            case .publicIndex:
                if let publicIndex { list.append(publicIndex) }      // exists only when the person switched it on
            case .starlite: break                                    // adapter arrives with the schedule decoder
            }
        }
        sources = list.sorted { $0.priority != $1.priority ? $0.priority < $1.priority : $0.id < $1.id }
    }
    func source(_ id: String) -> (any EPGSource)? { sources.first { $0.id == id } }
}
