import Foundation

struct XMLTVChannel: Sendable, Hashable {
    let id: String
    var displayNames: [String]
    var icon: String?
}

struct XMLTVProgramme: Sendable, Hashable {
    let channel: String
    let start: Date
    let stop: Date
    let title: String
    var subtitle: String?
    var description: String?
    var category: String?
    var icon: String?
}

enum XMLTVMapper {
    /// "20260101120000 +0100" (or without zone = UTC) -> Date. Timestamps are stored in UTC.
    static func parseTime(_ s: String) -> Date? {
        let u = Array(s.utf8)
        guard u.count >= 12, u[0..<12].allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        func n(_ a: Int, _ l: Int) -> Int { (a..<a + l).reduce(0) { $0 * 10 + Int(u[$1]) - 48 } }
        let y = n(0, 4), mo = n(4, 2), d = n(6, 2), h = n(8, 2), mi = n(10, 2)
        let se = u.count >= 14 && u[12] >= 48 && u[12] <= 57 && u[13] >= 48 && u[13] <= 57 ? n(12, 2) : 0
        guard (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, se < 61 else { return nil }
        var off = 0
        let zone = s.dropFirst(u.count >= 14 ? 14 : 12).trimmingCharacters(in: .whitespaces)
        if zone.count >= 5, let sign = zone.first, sign == "+" || sign == "-",
           let hh = Int(zone.dropFirst().prefix(2)), let mm = Int(zone.dropFirst(3).prefix(2)) {
            off = (hh * 3600 + mm * 60) * (sign == "-" ? -1 : 1)
        }
        let yy = mo <= 2 ? y - 1 : y
        let era = yy / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let secs = (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + se - off
        return Date(timeIntervalSince1970: TimeInterval(secs))
    }
}
