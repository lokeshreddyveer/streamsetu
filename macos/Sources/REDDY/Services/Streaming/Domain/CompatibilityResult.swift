import Foundation

/// Owner-entered manual check results for one service. Never produced by automation.
struct CompatibilityResult: Equatable, Codable, Sendable {
    enum Check: String, CaseIterable, Codable, Sendable {
        case siteLoads, signInPageRenders, signInCompletes, catalog, video, audio, fullscreen, sessionPersistsAfterRestart, switchingStopsAudio, errorScreenRetryAndReturn
    }
    enum Outcome: String, Codable, Sendable { case notChecked, passed, failed, notApplicable }

    var results: [Check: Outcome]
    var checkedOn: Date?
    var note: String?
    /// "Debug" or "Release": the build the owner tried.
    var build: String

    static let unchecked = CompatibilityResult(results: [:], checkedOn: nil, note: nil, build: "")
    func outcome(_ c: Check) -> Outcome { results[c] ?? .notChecked }
}

extension CompatibilityResult {
    /// An owner-entered record: only the listed checks carry an outcome; every other check stays notChecked.
    static func ownerChecked(on day: String, build: String, passed: [Check], failed: [Check] = [], notApplicable: [Check] = [], note: String) -> CompatibilityResult {
        var r: [Check: Outcome] = [:]
        for c in passed { r[c] = .passed }
        for c in failed { r[c] = .failed }
        for c in notApplicable { r[c] = .notApplicable }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let parts = day.split(separator: "-").compactMap { Int($0) }
        let date = parts.count == 3 ? cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) : nil
        return CompatibilityResult(results: r, checkedOn: date, note: note, build: build)
    }
}
