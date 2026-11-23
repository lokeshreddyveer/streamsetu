import Testing
import Foundation
@testable import REDDY

/// The generated manual-checklist data must follow the registry, and the generator must keep its documents out of the repository.
/// Nothing here signs in, loads a page or records an outcome.
@Suite("Service checklist generator") struct ServiceChecklistTests {
    private struct Row: Decodable { let id: String; let availability: String; let externalLinks: String; let presentation: String; let checks: [String]; let defaultOutcomes: [String: String]; let recordedOutcomes: [String: String] }
    private struct Fixture: Decodable { let checkKeys: [String]; let services: [Row] }

    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static var fixtureURL: URL { repo.appendingPathComponent("macos/Tests/REDDYTests/Resources/service-checklist.json") }

    private func fixture() throws -> Fixture { try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixtureURL)) }

    private func python(_ args: [String]) throws -> (status: Int32, out: String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", Self.repo.appendingPathComponent("Scripts/gen-service-checklist.py").path] + args
        p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    @Test func checkKeysAreTheCompatibilityChecks() throws {
        #expect(try fixture().checkKeys == CompatibilityResult.Check.allCases.map(\.rawValue))
    }

    @Test func everyRegistryServiceIsListedWithItsState() throws {
        let f = try fixture()
        #expect(f.services.map(\.id) == ProviderCatalog.all.map(\.id.rawValue))
        for d in ProviderCatalog.all {
            let row = try #require(f.services.first { $0.id == d.id.rawValue })
            #expect(row.availability == d.availability.rawValue && row.externalLinks == d.externalLinks.rawValue)
            #expect(row.presentation == (d.presentation == .embedded ? "embedded" : d.presentation == .integrationUnavailable ? "integrationUnavailable" : "hidden"))
        }
    }

    @Test func embeddedServicesListEveryCheckAndTheRightExtras() throws {
        for row in try fixture().services where row.presentation == "embedded" {
            #expect(Set(CompatibilityResult.Check.allCases.map(\.rawValue)).isSubset(of: Set(row.checks)), "\(row.id)")
            #expect(row.checks.contains("returningPreservesState"), "\(row.id)")
            if row.externalLinks == "blockWithNotice" { #expect(row.checks.contains("blockedLinkNotice") && !row.checks.contains("defaultBrowserActionUnchanged") && !row.checks.contains { $0.lowercased().contains("browser") }, "\(row.id)") }
            else { #expect(row.checks.contains("defaultBrowserActionUnchanged"), "\(row.id)") }
        }
        #expect(try fixture().services.first { $0.id == "youtube" }?.defaultOutcomes["signInCompletes"] == "notApplicable")
    }

    @Test func fixtureRecordsExactlyTheOwnerOutcomesOfTheCatalog() throws {
        for row in try fixture().services {
            let rec = ProviderCatalog.all.first { $0.id.rawValue == row.id }!.capabilities.compatibility.results
            #expect(Dictionary(uniqueKeysWithValues: rec.map { ($0.key.rawValue, $0.value.rawValue) }) == row.recordedOutcomes, "\(row.id)")
        }
    }

    @Test func aDisabledServiceListsOnlyTheErrorScreenAndRegisteredNone() throws {
        let src = try String(contentsOf: Self.repo.appendingPathComponent("Scripts/gen-service-checklist.py"), encoding: .utf8)
        #expect(src.contains("\"disabled\": return [\"errorScreenRetryAndReturn\"]") || src.contains("== \"disabled\": return [\"errorScreenRetryAndReturn\"]"))
        #expect(src.contains("\"registered\": return []"))
    }

    @Test func theFixtureIsCurrentAndTheDocumentsStayOutOfTheRepository() throws {
        let check = try python(["--check", "--json", Self.fixtureURL.path])
        #expect(check.status == 0, "\(check.out)")
        let refused = try python(["--out", Self.repo.appendingPathComponent("docs").path])
        #expect(refused.status == 2)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("svc-checklist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ok = try python(["--out", dir.path])
        #expect(ok.status == 0, "\(ok.out)")
        let checklist = try String(contentsOf: dir.appendingPathComponent("service-checklist.md"), encoding: .utf8)
        let report = try String(contentsOf: dir.appendingPathComponent("compatibility-report.md"), encoding: .utf8)
        for d in ProviderCatalog.all {
            #expect(report.contains(d.displayName))
            if d.availability == .registered { #expect(!checklist.contains(d.displayName), "a held service is not in the manual checklist") } else { #expect(checklist.contains(d.displayName)) }
        }
        // only the owner-entered outcomes recorded in the catalog appear; a service with none (Netflix) starts entirely unchecked
        let blocks = report.components(separatedBy: "\n## ").dropFirst()
        for id in ["netflix"] {
            let b = try #require(blocks.first { $0.contains("(`\(id)`)") })
            #expect(!b.contains(": passed") && !b.contains(": failed"), "\(id)")
        }
        let cr = try #require(blocks.first { $0.contains("(`crunchyroll`)") })
        #expect(cr.contains("video: passed") && cr.contains("catalog: notChecked") && !cr.contains(": failed") && cr.contains("availability: available"))
        let hulu = try #require(blocks.first { $0.contains("(`hulu`)") })
        #expect(hulu.contains("siteLoads: passed | date: 2026-11-22 | note: owner-verified") && hulu.contains("signInPageRenders: notChecked") && !hulu.contains(": failed"))
        let hbo = try #require(blocks.first { $0.contains("(`hbomax`)") })
        #expect(hbo.contains("signInCompletes: passed") && hbo.contains("availability: available") && hbo.contains("build: Release 2.17.12"))
        #expect(report.contains("distributionAuthorization: unresolved"))
    }
}
