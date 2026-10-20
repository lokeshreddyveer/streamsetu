import Foundation

/// "Tonight": one list for the evening, put together from what the person already has. What is on or about to start on their favourite channels, what is set to record,
/// the next episode of the series they are watching, and what their guide alerts found.
struct TonightPlan: Equatable {
    struct Show: Equatable, Identifiable {
        let channel: Channel
        let program: EPGProgram
        var id: String { channel.id + "|" + String(program.id) }
    }
    struct Recording: Equatable, Identifiable {
        let id: String
        let title: String
        let channelName: String
        let start: Date
    }
    var onNow: [Show] = []
    var later: [Show] = []
    var recordings: [Recording] = []
    var upNext: [HistoryService.UpNextEntry] = []
    var alerts: [String] = []

    var isEmpty: Bool { onNow.isEmpty && later.isEmpty && recordings.isEmpty && upNext.isEmpty && alerts.isEmpty }

    static func == (a: TonightPlan, b: TonightPlan) -> Bool {
        a.onNow == b.onNow && a.later == b.later && a.recordings == b.recordings && a.upNext.map(\.id) == b.upNext.map(\.id) && a.alerts == b.alerts
    }
}

enum TonightBuilder {
    /// How far ahead "tonight" looks, and how many entries each part keeps, so the page stays a short list and not a second guide.
    static let horizon: TimeInterval = 5 * 3600
    static let maxShows = 8
    static let maxUpNext = 6

    static func build(now: Date, channels: [Channel], programs: [String: [EPGProgram]], recordings: [TonightPlan.Recording],
                      upNext: [HistoryService.UpNextEntry], alerts: [String]) -> TonightPlan {
        var plan = TonightPlan()
        var nowShows: [TonightPlan.Show] = [], laterShows: [TonightPlan.Show] = []
        for ch in channels {
            let list = (programs[ch.id] ?? []).filter { $0.end > now && $0.start < now.addingTimeInterval(horizon) }.sorted { $0.start < $1.start }
            if let live = list.first(where: { $0.isLive(at: now) }) { nowShows.append(.init(channel: ch, program: live)) }
            // the next one that has not started: one per channel, so one busy channel does not fill the list
            if let next = list.first(where: { $0.start > now }) { laterShows.append(.init(channel: ch, program: next)) }
        }
        plan.onNow = Array(nowShows.sorted { $0.program.end < $1.program.end }.prefix(maxShows))
        plan.later = Array(laterShows.sorted { $0.program.start < $1.program.start }.prefix(maxShows))
        plan.recordings = recordings.filter { $0.start > now.addingTimeInterval(-3600) && $0.start < now.addingTimeInterval(24 * 3600) }.sorted { $0.start < $1.start }
        plan.upNext = Array(upNext.prefix(maxUpNext))
        plan.alerts = alerts
        return plan
    }
}
