import Foundation

struct EPGProgram: Identifiable, Hashable, Sendable {
    let id: Int64
    let sourceID: UUID
    let xmltvChannelID: String
    let start: Date
    let end: Date
    let title: String
    var subtitle: String?
    var description: String?
    var category: String?
    var imageURL: String?

    func progress(at date: Date = Date()) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / total))
    }

    func isLive(at date: Date = Date()) -> Bool { start <= date && date < end }
}
