import Foundation

// One guide-adapter system: provider guides, user-added XMLTV addresses and permitted public indexes all implement `EPGSource`.
// An adapter only chooses where the bytes come from and which decoder reads them; the import pipeline (limits, window, batches, atomic switch, diagnostics) is shared.

enum GuideSourceKind: String, Sendable, CaseIterable { case provider, userXMLTV, publicIndex, starlite }

enum GuideCapability: String, Sendable, Hashable { case programmes, channelList, icons, categories, languages, timezones }

/// How times without a zone offset are read. A time that carries an offset is always converted with that offset.
enum GuideTimeZoneMode: Sendable, Equatable, Hashable {
    case automatic                 // offsets as written; no offset means UTC (the XMLTV rule)
    case utc                       // same as automatic for parsing, kept as an explicit choice
    case local(zoneID: String)     // feeds that omit the offset but are really local time of this IANA zone (DST aware)

    init(stored: String?, zone: String?) {
        switch stored {
        case "utc": self = .utc
        case "local": self = zone.map { .local(zoneID: $0) } ?? .automatic
        default: self = .automatic
        }
    }
    var storedValue: String { switch self { case .automatic: "auto"; case .utc: "utc"; case .local: "local" } }
}

/// The most a guide may be. Mirrors the Android `GuideLimits`.
struct GuideLimits: Sendable, Equatable {
    var maxWireBytes: Int64 = 250_000_000
    var maxUnpackedBytes: Int64 = GzipInflater.maxOutput
    var maxChannels = 60_000
    var maxProgrammes = 3_000_000
    var maxSeconds: TimeInterval = 15 * 60
    static let standard = GuideLimits()
}

struct GuideValidators: Sendable, Equatable {
    var etag: String?
    var lastModified: String?
}

struct GuideFetched: Sendable {
    /// Document ready to read (plain or gzip); nil when the server said "not modified" or the adapter has nothing to read. The caller deletes it.
    let file: URL?
    let validators: GuideValidators
    let status: Int
    let bytes: Int64
    var notModified: Bool { status == 304 }
}

/// What may be shown about a source. The host only, never the full address.
struct GuideSourceInfo: Sendable, Equatable {
    var name: String
    var host: String?
    var kind: GuideSourceKind
    /// Key into the credits table (Settings and About only). nil for the person's own guides.
    var creditKey: String?
    var consentText: String?
}

struct GuideChannelRecord: Sendable, Hashable {
    let id: String
    var displayNames: [String]
    var icon: String?
    var lang: String?
    var countryHint: String?
}

struct GuideProgramme: Sendable, Hashable {
    let channel: String
    let start: Date
    let stop: Date
    let title: String
    var subtitle: String?
    var description: String?
    var category: String?
    var icon: String?
    var lang: String?
    var episodeNum: String?
    var date: String?
    var rating: String?
}

/// What a read of one document found, including everything it skipped and why. This is what makes an empty guide explainable.
struct GuideReadStats: Sendable, Equatable {
    var channels = 0
    var programmesSeen = 0
    var programmesKept = 0
    var droppedPast = 0
    var droppedFuture = 0
    var droppedInvalid = 0
    var truncated = false
    /// Earliest start and latest stop of every well-formed programme in the document, window or not.
    var firstStart: Date?
    var lastStop: Date?
}

enum GuideReadError: Error, Equatable, LocalizedError {
    case unreadable, tooManyChannels, tooManyProgrammes, timedOut, notAGuide
    var errorDescription: String? {
        switch self {
        case .unreadable: "The guide file could not be read."
        case .tooManyChannels: "The guide lists far more channels than a guide should, so it was not imported."
        case .tooManyProgrammes: "The guide holds far more programmes than a guide should, so it was not imported."
        case .timedOut: "Reading the guide took too long and was stopped."
        case .notAGuide: "The file is not a programme guide."
        }
    }
}

/// A decoded document. `read` streams: channels one by one, programmes in bounded batches.
protocol GuideStream: Sendable {
    func read(window: ClosedRange<Date>, timeZone: GuideTimeZoneMode, limits: GuideLimits,
              onChannel: @escaping (GuideChannelRecord) -> Void, onBatch: @escaping ([GuideProgramme]) throws -> Void) throws -> GuideReadStats
}

struct GuideBudget: Sendable, Equatable {
    var limits: GuideLimits = .standard
    /// Mobile data saver: refuse documents larger than this when set.
    var maxBytesOnConstrainedNetwork: Int64? = nil
}

protocol EPGSource: Sendable {
    /// "provider:<sourceId>", "user:<uuid>", "iptvorg-db", "starlite".
    var id: String { get }
    var kind: GuideSourceKind { get }
    var capabilities: Set<GuideCapability> { get }
    /// Lower wins on conflict (provider 10, user 20, public 30).
    var priority: Int { get }
    func describe() -> GuideSourceInfo
    func fetch(since: GuideValidators?, budget: GuideBudget) async throws -> GuideFetched
    func open(_ fetched: GuideFetched) throws -> any GuideStream
}

extension GuideSourceKind {
    var defaultPriority: Int { switch self { case .provider: 10; case .userXMLTV: 20; case .publicIndex, .starlite: 30 } }
    /// Fewest hours between automatic refreshes (per-host limits of the design: public index once a day, Starlite 3 h, user guides 1 h).
    var minRefreshHours: Int { switch self { case .publicIndex: 24; case .starlite: 3; case .userXMLTV: 1; case .provider: 1 } }
    var defaultRefreshHours: Int { switch self { case .publicIndex: 24; case .starlite: 3; case .userXMLTV, .provider: 6 } }
}
