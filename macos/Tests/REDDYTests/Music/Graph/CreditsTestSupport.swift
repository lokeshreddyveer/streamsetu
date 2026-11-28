import Foundation
@testable import REDDY

/// Fixtures recorded from the providers' public replies (trimmed), plus one documented sample, under Tests/REDDYTests/Music/Fixtures.
enum CreditsFixtures {
    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
    }
    static func json(_ name: String) -> [String: Any] {
        let data = (try? Data(contentsOf: directory.appendingPathComponent(name))) ?? Data()
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }
    static func songs(_ name: String) -> [[String: Any]] { json(name).array("list") }
    static func credits(_ t: MusicTrack, _ role: MusicCreditRole) -> [MusicCredit] { (t.credits ?? []).filter { $0.role == role } }
    static func names(_ t: MusicTrack, _ role: MusicCreditRole) -> [String] { credits(t, role).map(\.name) }
}
