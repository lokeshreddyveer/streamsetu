import Foundation

/// What the person using the app now may see. Passed with every request (never read from shared objects on a background thread) and part of the cache key, so a profile switch or a lock change can
/// never be answered from another person's results.
struct SportsContext: Hashable, Sendable {
    var profileID: String
    /// Folders marked locked are in force (a kids profile, or a PIN that has not been entered).
    var restricting: Bool
    var lockedCategoryIDs: Set<String>
    var hiddenChannelIDs: Set<String>

    /// Why a channel must stay out of every result, or nil when it may be used.
    func restriction(for channel: Channel) -> SportsRestriction? {
        if hiddenChannelIDs.contains(channel.id) { return .hiddenChannel }
        if restricting, let c = channel.categoryID, lockedCategoryIDs.contains(c) { return .lockedFolder }
        return nil
    }
    /// A short stable fingerprint of everything that decides what is visible.
    var fingerprint: String { SportsEventService.hash("\(profileID)|\(restricting)|\(lockedCategoryIDs.sorted().joined(separator: ","))|\(hiddenChannelIDs.sorted().joined(separator: ","))") }
}

/// Builds sports events from the guide of the person's own playlists. Channels are read once and programmes in a few large batches per playlist (never a query per channel or per row), off the main
/// thread, inside a bounded window, and the work stops quietly when something newer replaces it. Each playlist's classified programmes are cached on their own, keyed by that playlist's guide revision,
/// its channel list, the person's profile and restrictions and the window, so another playlist's update never invalidates (or wrongly reuses) them. Only channels the person may see are ever
/// classified, so nothing in the cache is unauthorised. Nothing is written to the database: events are derived and can always be rebuilt.
actor SportsEventService {
    /// How the service reaches the existing channel and guide services; closures so tests need no database.
    struct Inputs: Sendable {
        /// Channels that have a guide (the catalogue already omits locked and hidden ones; the context is applied again here).
        var channels: @Sendable () throws -> [Channel]
        var programmes: @Sendable (_ channelIDs: [String], _ from: Date, _ to: Date) throws -> [String: [EPGProgram]]
        /// Each enabled playlist's guide revision: it changes when that playlist's guide is imported.
        var revisions: @Sendable () throws -> [UUID: String]
    }

    static let maxWindow: TimeInterval = 72 * 3600
    static let batch = 500
    /// Feeds whose programmes start this close together, or overlap, are one event.
    var startTolerance: TimeInterval = 45 * 60
    fileprivate static let cacheLimit = 24

    private let inputs: Inputs
    private var cache: [SourceKey: [Hit]] = [:]
    private var order: [SourceKey] = []
    private var inflight: (context: String, task: Task<[UUID: [Hit]], Error>)?
    /// Bumped whenever the person's context changes or the cache is invalidated: work started before is never published.
    private var generation = 0
    private var latestContext: String?
    /// How many playlists were classified from scratch (the rest came from the cache), for tests.
    private(set) var classifiedSources = 0
    /// How many classified playlist results are held; never more than `cacheLimit`.
    var cachedEntries: Int { cache.count }
    static var cacheCapacity: Int { cacheLimit }

    struct SourceKey: Hashable, Sendable { let source: UUID, revision: String, channels: String, context: String, from: Int, to: Int }
    struct Hit: Sendable { let match: SportsClassifier.Match; let channel: Channel; let programme: EPGProgram }

    init(inputs: Inputs, startTolerance: TimeInterval = 45 * 60) { self.inputs = inputs; self.startTolerance = startTolerance }

    /// Drops everything cached and stops work in flight (a playlist was removed, the guide was rebuilt…).
    func invalidate() { generation += 1; cache.removeAll(); order.removeAll(); inflight?.task.cancel(); inflight = nil }

    /// Call when the profile, the PIN lock or kids mode changes: work for the previous state is cancelled and can never be published.
    func contextDidChange() { generation += 1; inflight?.task.cancel(); inflight = nil }

    /// Events overlapping `window` (limited to 72 hours), for this person.
    func events(in window: DateInterval, context: SportsContext) async throws -> [SportsEvent] {
        let end = min(window.end, window.start.addingTimeInterval(Self.maxWindow))
        let fp = context.fingerprint
        if let latest = latestContext, latest != fp { generation += 1; inflight?.task.cancel(); inflight = nil }       // another person's request replaces the old one
        latestContext = fp
        let myGeneration = generation

        let from = Int(window.start.timeIntervalSince1970 / 900), to = Int((end.timeIntervalSince1970 / 900).rounded(.up))
        let revisions = try inputs.revisions()
        let channels = try inputs.channels().filter { context.restriction(for: $0) == nil }          // restricted channels are removed before anything is built
        let bySource = Dictionary(grouping: channels, by: \.sourceID)

        // which playlists still need classifying
        var keys: [UUID: SourceKey] = [:], missing: [UUID] = []
        for (source, list) in bySource {
            let k = SourceKey(source: source, revision: revisions[source] ?? "none", channels: Self.fingerprint(of: list), context: fp, from: from, to: to)
            keys[source] = k
            if cache[k] == nil { missing.append(source) }
        }
        var fresh: [UUID: [Hit]] = [:]
        if !missing.isEmpty {
            let inputs = self.inputs
            let lower = Date(timeIntervalSince1970: Double(from) * 900), upper = Date(timeIntervalSince1970: Double(to) * 900)
            let work = missing.map { ($0, bySource[$0] ?? []) }
            let task = Task.detached(priority: .utility) { () throws -> [UUID: [Hit]] in
                var out: [UUID: [Hit]] = [:]
                for (source, list) in work { try Task.checkCancellation(); out[source] = try SportsEventService.classify(list, inputs: inputs, from: lower, to: upper) }
                return out
            }
            inflight = (fp, task)
            do {
                fresh = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            } catch { if inflight?.context == fp { inflight = nil }; throw error }
            if inflight?.context == fp { inflight = nil }
            // a different person, a lock change or an invalidation arrived while this ran: nothing from this run is published
            guard generation == myGeneration else { throw CancellationError() }
            classifiedSources += missing.count
            for (source, hits) in fresh { if let k = keys[source] { cache[k] = hits; order.removeAll { $0 == k }; order.append(k) } }
            while order.count > Self.cacheLimit { cache[order.removeFirst()] = nil }
        }
        let all = keys.compactMap { (source, k) in cache[k] ?? fresh[source] }.flatMap { $0 }
        let rev = revisions
        return Self.group(all, revisions: rev, tolerance: startTolerance).filter { $0.end > window.start && $0.start < end }
    }

    private static func fingerprint(of channels: [Channel]) -> String {
        hash(channels.map { "\($0.id)|\($0.epgID ?? "")|\($0.categoryID ?? "")|\($0.name)|\($0.language ?? "")|\($0.resolutionHint ?? "")|\($0.archiveDays)" }.sorted().joined(separator: "\n"))
    }

    // MARK: building

    static func classify(_ channels: [Channel], inputs: Inputs, from: Date, to: Date, fastReject: Bool = true) throws -> [Hit] {
        var byID: [String: Channel] = [:]
        for c in channels { byID[c.id] = c }
        let ids = channels.map(\.id)
        var hits: [Hit] = []
        for start in stride(from: 0, to: ids.count, by: batch) {
            try Task.checkCancellation()
            for (cid, list) in try inputs.programmes(Array(ids[start..<min(start + batch, ids.count)]), from, to) {
                guard let channel = byID[cid] else { continue }
                for p in list where p.end > from && p.start < to && p.end > p.start {
                    if let m = SportsClassifier.classify(title: p.title, subtitle: p.subtitle, description: p.description, category: p.category, channelName: channel.name,
                                                         channelCategory: channel.categoryName, channelLanguage: channel.language, channelQuality: channel.resolutionHint, fastReject: fastReject) {
                        hits.append(Hit(match: m, channel: channel, programme: p))
                    }
                }
            }
        }
        return hits
    }

    /// Feeds of one event: the same sport and identity, a compatible competition, and programmes that overlap or start within the tolerance of each other (across playlists too).
    /// Grouping (which feeds belong together) is separate from identity (the event's id): the id never depends on which feed happens to start earliest.
    static func group(_ hits: [Hit], revisions: [UUID: String], tolerance: TimeInterval) -> [SportsEvent] {
        var buckets: [String: [Hit]] = [:]
        for h in hits { buckets[h.match.identity, default: []].append(h) }
        var events: [SportsEvent] = []
        for (identity, list) in buckets {
            let sorted = list.sorted { ($0.programme.start, $0.channel.id) < ($1.programme.start, $1.channel.id) }
            var clusters: [[Hit]] = []
            for h in sorted {
                if let i = clusters.lastIndex(where: { compatible($0, h, tolerance: tolerance) }) { clusters[i].append(h) } else { clusters.append([h]) }
            }
            // The id comes from facts that survive a feed appearing, disappearing or being corrected by a few minutes: the normalized identity, the calendar day (UTC) of the event's reference time, and
            // which occurrence of that identity on that day it is. The reference time is the middle of the feeds' start times, not the earliest.
            let referenced = clusters.map { c -> (cluster: [Hit], ref: Date, day: Int) in
                let starts = c.map(\.programme.start).sorted(); let ref = starts[(starts.count - 1) / 2]
                return (c, ref, Int((ref.timeIntervalSince1970 / 86_400).rounded(.down)))
            }
            var perDay: [Int: Int] = [:]
            for r in referenced.sorted(by: { ($0.ref, $0.cluster.first!.match.competitionKey ?? "", $0.cluster.first!.channel.id) < ($1.ref, $1.cluster.first!.match.competitionKey ?? "", $1.cluster.first!.channel.id) }) {
                let ordinal = perDay[r.day, default: 0]; perDay[r.day] = ordinal + 1
                events.append(makeEvent(r.cluster, revisions: revisions, id: hash("\(identity)|\(r.day)|\(ordinal)")))
            }
        }
        return events.sorted { ($0.start, $0.title, $0.id) < ($1.start, $1.title, $1.id) }
    }

    private static func compatible(_ cluster: [Hit], _ h: Hit, tolerance: TimeInterval) -> Bool {
        guard let first = cluster.first else { return false }
        // compatible competition: the same, or at least one side does not name one
        let c = cluster.compactMap(\.match.competitionKey).first
        if let a = c, let b = h.match.competitionKey, a != b { return false }
        let start = cluster.map(\.programme.start).min()!, end = cluster.map(\.programme.end).max()!
        let overlaps = h.programme.start < end && h.programme.end > start
        return overlaps || abs(h.programme.start.timeIntervalSince(first.programme.start)) <= tolerance
    }

    private static func makeEvent(_ cluster: [Hit], revisions: [UUID: String], id: String) -> SportsEvent {
        let anchor = cluster.map(\.programme.start).min()!
        var byChannel: [String: Hit] = [:]
        for h in cluster where byChannel[h.channel.id].map({ abs(h.programme.start.timeIntervalSince(anchor)) < abs($0.programme.start.timeIntervalSince(anchor)) }) ?? true { byChannel[h.channel.id] = h }
        let hits = byChannel.values.sorted { (qualityRank($0.match.quality?.value), $1.channel.name, $0.channel.id) > (qualityRank($1.match.quality?.value), $0.channel.name, $1.channel.id) }
        let feeds = hits.map { h in
            SportsFeed(channelID: h.channel.id, sourceID: h.channel.sourceID, channelName: h.channel.name, language: h.match.language?.value, languageSource: h.match.language?.source ?? .unknown,
                       quality: h.match.quality?.value, qualitySource: h.match.quality?.source ?? .unknown, variant: h.match.variant, guideProgrammeID: h.programme.id, catchUp: h.channel.archiveDays > 0, logoURL: h.channel.logoURL)
        }
        let best = cluster.map(\.match).max { $0.confidence < $1.confidence }!
        let end = min(cluster.map(\.programme.end).max()!, anchor.addingTimeInterval(12 * 3600))
        func commonest(_ values: [String]) -> String? { Dictionary(grouping: values, by: { $0 }).max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key }
        let sources = Set(feeds.map(\.sourceID))
        let revision = sources.map { "\($0.uuidString.prefix(8)):\(revisions[$0] ?? "none")" }.sorted().joined(separator: ",")
        return SportsEvent(id: id, sport: best.sport, kind: best.kind, competition: commonest(cluster.compactMap(\.match.competition)), participants: best.participants, stage: best.stage,
                           title: commonest(cluster.map(\.match.title)) ?? best.title, start: anchor, end: end, feeds: feeds, confidence: best.confidence, sourceIDs: sources, guideRevision: revision)
    }

    private static func qualityRank(_ q: String?) -> Int { q.flatMap { ["4K": 4, "FHD": 3, "HD": 2, "SD": 1][$0] } ?? 0 }

    /// FNV-1a: stable across runs and platforms (Swift's own hashing is randomised per launch).
    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

extension SportsEventService {
    /// The service wired to the real channel, guide and playlist repositories. A playlist's revision is its last guide update, so a new import is a new revision for that playlist alone.
    static func standard(catalog: any CatalogRepository, epg: any EPGRepository) -> SportsEventService {
        SportsEventService(inputs: Inputs(
            channels: { var q = ChannelQuery(); q.onlyWithGuide = true; q.collapseVariants = false; q.includeHidden = false; return try catalog.channels(q) },
            programmes: { ids, from, to in try epg.programs(channelIDs: ids, from: from, to: to) },
            revisions: {
                var out: [UUID: String] = [:]
                for s in try catalog.sources() where s.enabled { out[s.id] = "\(Int((try? epg.guideCoverage(sourceID: s.id).lastUpdate?.timeIntervalSince1970) ?? 0))" }
                return out
            }))
    }
}
