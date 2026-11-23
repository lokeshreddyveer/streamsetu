import Testing
import Foundation
@testable import REDDY

/// The in-app Open-Source Licenses page (About) says exactly what legal/licenses.md says, including the Sparkle MIT, libmpv, TMDB, fanart.tv, TheTVDB and TVmaze credits.
@Suite("Legal text parity") struct LegalTextParityTests {
    @Test func inAppLicensesMatchTheRepositoryFile() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: repo.appendingPathComponent("legal/licenses.md"), encoding: .utf8)
        func norm(_ s: String) -> String { s.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n") }
        #expect(norm(LegalText.licenses) == norm(file), "legal/licenses.md and LegalText.licenses must say the same thing")
        for credit in ["**Sparkle**", "MIT licence", "**mpv** and **libmpv**", "**The Movie Database (TMDB).**", "**fanart.tv.**", "**TheTVDB.**", "**TVmaze.**"] {
            #expect(LegalText.licenses.contains(credit), "missing credit: \(credit)")
        }
    }

    @Test func theTheTVDBCreditUsesTheLicenceWording() {
        #expect(ServiceCredits.all.first { $0.id == "tvdb" }?.text == "Metadata provided by TheTVDB.com. Please consider adding missing information or subscribing.")
    }
}
