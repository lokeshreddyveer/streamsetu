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
