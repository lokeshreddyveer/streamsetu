import SwiftUI
import Observation

enum GuideScope: Hashable {
    case withGuide, favorites
    case category(String)
}

@MainActor @Observable
final class GuideViewModel {
    var scope: GuideScope = .withGuide
    var channels: [Channel] = []
    var windowStart: Date = GuideViewModel.snap(Date().addingTimeInterval(-30 * 60))
    var hours: Double = 3
    var programs: [String: [EPGProgram]] = [:]
    var trackWidth: CGFloat = 800
    var loading = false
    var sourceID: UUID?
    var coverage: (channels: Int, programs: Int, mapped: Int, lastUpdate: Date?)?

    // Programmes are read for the rows on screen and a few beside them, in batches: one query for many channels, never one per row. The grid keeps showing what it had while the
    // next window loads, and an answer that arrives after the window moved is thrown away (see `generation`).
    /// Rows asked for in one query.
    static let batchSize = 60
    /// Rows read beyond the visible ones, so a slow scroll finds them ready.
    static let prefetchAhead = 12, prefetchBehind = 4
    /// How long rows appearing together wait before one query is made for all of them.
    static let gather: Duration = .milliseconds(80)
    /// How programmes are read. The screens point this at the guide database; tests point it at a counter.
    var fetch: (@Sendable (_ channelIDs: [String], _ from: Date, _ to: Date) async -> [String: [EPGProgram]])?
    private var visible = Set<String>()
    private var pending = Set<String>()
    private var inFlight = Set<String>()
    private var loadedBucket: [String: Int] = [:]
    private var indexByID: [String: Int] = [:]
    /// Raised when the time window moves to a new bucket or the channel list is replaced; a read that started before is discarded.
    private(set) var generation = 0
    /// How many programme queries have been made (for tests and for the measurements).
    private(set) var queryCount = 0
    private var flushTask: Task<Void, Never>?

    /// Floors to the previous half hour of *local* time, so zones with odd offsets and DST days still land on :00/:30.
    static func snap(_ d: Date, calendar cal: Calendar = .current) -> Date {
        var c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        c.minute = (c.minute ?? 0) < 30 ? 0 : 30
        return cal.date(from: c) ?? d
    }

    /// 18:00 local on the day `offset` days from `now`. Built from calendar components, never by adding 18 × 3600 seconds,
    /// which is an hour off on the two days a year the clocks change.
    static func evening(daysFromNow offset: Int, now: Date = Date(), calendar cal: Calendar = .current) -> Date {
        let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)) ?? now
        return cal.date(bySettingHour: 18, minute: 0, second: 0, of: day) ?? day
    }

    var windowEnd: Date { windowStart.addingTimeInterval(hours * 3600) }
    /// Rows refetch when this changes (every 2 hours of horizontal travel), not on every scroll tick.
    var bucket: Int { Int(windowStart.timeIntervalSince1970 / 7200) }
    var secondsPerPoint: Double { hours * 3600 / max(1, Double(trackWidth)) }

    func x(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(windowStart) / (hours * 3600)) * trackWidth
    }

    func reload(_ c: AppContainer) async {
        loading = channels.isEmpty
        let s = scope, sid = sourceID
        let list = await Task.detached { () -> [Channel] in
            switch s {
            case .withGuide: return (try? c.catalog.channels(ChannelQuery(sourceID: sid, collapseVariants: true, onlyWithGuide: true))) ?? []
            case .favorites: return (try? c.catalog.channels(ChannelQuery(sourceID: sid, favoritesOnly: true, collapseVariants: false))) ?? []
            case .category(let id): return (try? c.catalog.channels(ChannelQuery(sourceID: sid, categoryID: id, collapseVariants: true, onlyWithGuide: true))) ?? []
            }
        }.value
        useChannels(list)
        loading = false
        fetch = { ids, from, to in await Task.detached { (try? c.epgRepo.programs(channelIDs: ids, from: from, to: to)) ?? [:] }.value }
        if let sid { coverage = try? c.epgRepo.guideCoverage(sourceID: sid) }
    }

    /// Replaces the channel list. What is already loaded stays on screen until the new rows are read.
    func useChannels(_ list: [Channel]) {
        channels = list
        indexByID = Dictionary(list.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        generation += 1
        pending.removeAll(); loadedBucket = [:]
        for id in visible where indexByID[id] != nil { queue(around: id) }
    }

    /// A row came on screen: it, and the rows beside it, are read in the next batch.
    func rowAppeared(_ id: String) { visible.insert(id); queue(around: id) }
    func rowDisappeared(_ id: String) { visible.remove(id); pending.remove(id) }

    /// The time window moved to another two-hour bucket: what is on screen is read again, in one batch, and the old answers are not trusted.
    func windowMoved() {
        generation += 1
        loadedBucket = [:]; pending.removeAll()
        for id in visible { queue(around: id) }
    }

    private func queue(around id: String) {
        guard let i = indexByID[id] else { return }
        let lo = max(0, i - Self.prefetchBehind), hi = min(channels.count - 1, i + Self.prefetchAhead)
        guard lo <= hi else { return }
        for j in lo...hi {
            let cid = channels[j].id
            if loadedBucket[cid] != bucket, !inFlight.contains(cid) { pending.insert(cid) }
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.gather)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// The rows on screen and the few beside them: what is worth reading now.
    private func neighbourhood() -> Set<String> {
        var out = Set<String>()
        for id in visible {
            guard let i = indexByID[id] else { continue }
            let lo = max(0, i - Self.prefetchBehind), hi = min(channels.count - 1, i + Self.prefetchAhead)
            if lo <= hi { for j in lo...hi { out.insert(channels[j].id) } }
        }
        return out
    }

    /// One query for the pending rows, those on screen first. Rows that were wanted only as read-ahead for a row that has since left the screen are dropped.
    func flush() async {
        pending.formIntersection(neighbourhood())
        guard let fetch, !pending.isEmpty else { return }
        let ordered = pending.sorted { (visible.contains($0) ? 0 : 1, indexByID[$0] ?? 0) < (visible.contains($1) ? 0 : 1, indexByID[$1] ?? 0) }
        let ids = Array(ordered.prefix(Self.batchSize))
        pending.subtract(ids); inFlight.formUnion(ids)
        let gen = generation, b = bucket
        let from = windowStart.addingTimeInterval(-4 * 3600), to = windowStart.addingTimeInterval(hours * 3600 + 5 * 3600)
        queryCount += 1
        let found = await fetch(ids, from, to)
        inFlight.subtract(ids)
        guard gen == generation else { return }              // the window moved or the list changed while this was being read: the answer is for something no longer shown
        for id in ids { programs[id] = found[id] ?? []; loadedBucket[id] = b }
        if !pending.isEmpty { scheduleFlush() }
    }

    func shift(hours h: Double) { windowStart = windowStart.addingTimeInterval(h * 3600) }
    func scroll(points: CGFloat) { windowStart = windowStart.addingTimeInterval(-Double(points) * secondsPerPoint) }
    func jumpToNow() { withAnimation(AnimationTokens.standard) { windowStart = Self.snap(Date().addingTimeInterval(-30 * 60)) } }

    func jump(toDay offset: Int) {
        if offset == 0 { jumpToNow(); return }
        withAnimation(AnimationTokens.standard) { windowStart = Self.evening(daysFromNow: offset) }
    }

    var dayLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(windowStart) { return "Today" }
        if cal.isDateInTomorrow(windowStart) { return "Tomorrow" }
        if cal.isDateInYesterday(windowStart) { return "Yesterday" }
        return windowStart.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
}
