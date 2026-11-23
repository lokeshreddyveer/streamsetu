import Foundation
@testable import REDDY

enum GuideFixtures {
    static var root: URL {
        var u = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 { if FileManager.default.fileExists(atPath: u.appendingPathComponent("epg/fixtures").path) { return u.appendingPathComponent("epg/fixtures") }; u = u.deletingLastPathComponent() }
        fatalError("epg/fixtures not found")
    }
    static func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }
    static func json(_ name: String) throws -> [String: Any] { try JSONSerialization.jsonObject(with: data(name)) as! [String: Any] }

    static func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    /// Reads a fixture document with the window wide open.
    static func read(_ name: String, window: ClosedRange<Date>? = nil, mode: GuideTimeZoneMode = .automatic, limits: GuideLimits = .standard) throws -> (stats: GuideReadStats, channels: [GuideChannelRecord], programmes: [GuideProgramme]) {
        var ch: [GuideChannelRecord] = [], pr: [GuideProgramme] = []
        let w = window ?? Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 4_000_000_000)
        let s = try XMLTVFileStream(file: url(name)).read(window: w, timeZone: mode, limits: limits, onChannel: { ch.append($0) }, onBatch: { pr += $0 })
        return (s, ch, pr)
    }

    static func tempDB() throws -> DatabaseManager {
        try DatabaseManager(path: FileManager.default.temporaryDirectory.appendingPathComponent("guide-hub-\(UUID().uuidString).sqlite").path)
    }
}
