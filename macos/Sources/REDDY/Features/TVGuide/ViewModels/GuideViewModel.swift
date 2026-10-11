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
        channels = list
        loading = false
        if let sid { coverage = try? c.epgRepo.guideCoverage(sourceID: sid) }
    }

    func loadRow(_ channel: Channel, _ c: AppContainer) async {
        let from = windowStart.addingTimeInterval(-4 * 3600), to = windowStart.addingTimeInterval(hours * 3600 + 5 * 3600)
        let id = channel.id
        let list = await Task.detached { ((try? c.epgRepo.programs(channelIDs: [id], from: from, to: to)) ?? [:])[id] ?? [] }.value
        programs[id] = list
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
