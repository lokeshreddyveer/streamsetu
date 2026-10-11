import Testing
import Foundation
@testable import REDDY

/// Runs the category pipeline's read side against a COPY of a real library database.
///   cp ~/Library/Application\ Support/Reddy/Database/reddy.sqlite* /tmp/copy/ && REDDY_DB_COPY=/tmp/copy/reddy.sqlite Scripts/run-tests.sh RealLibrary
/// The copy is migrated to the current schema, so this also proves the migration on real data. Nothing is written to the original.
@Suite("Real library (opt-in)", .enabled(if: ProcessInfo.processInfo.environment["REDDY_DB_COPY"] != nil))
@MainActor struct RealLibraryTests {
    @Test func categoryCountsAtEveryStage() throws {
        let path = ProcessInfo.processInfo.environment["REDDY_DB_COPY"]!
        let c = try AppContainer(databasePath: path, credentials: InMemoryCredentialStore())
        let sources = try c.catalog.sources()
        #expect(!sources.isEmpty)
        for s in sources {
            print("SOURCE", s.name, s.type.rawValue)
            for k in [ContentKind.channel, .movie, .series] {
                let stored = try c.catalog.storedCategoryCount(sourceID: s.id, kind: k)
                let returned = try c.catalog.categories(sourceID: s.id, kind: k, includeHidden: false)
                let empty = returned.filter { $0.itemCount == 0 }.count
                let unc = try c.catalog.uncategorizedCount(sourceID: s.id, kind: k)
                let oldDisplay = SidebarModel.folders(returned, hideEmpty: true).count
                let newDisplay = SidebarModel.folders(returned, hideEmpty: false, uncategorized: unc).count
                print("  \(k.rawValue): stored \(stored) · returned \(returned.count) · empty \(empty) · uncategorized items \(unc) · displayed (hide empty) \(oldDisplay) · displayed (default) \(newDisplay)")
                #expect(returned.count == stored, "nothing is lost between the table and the repository")
                #expect(Set(SidebarModel.folders(returned, hideEmpty: false).map(\.id)).count == returned.count, "unique row identities")
            }
            let ver = try c.db.read { try $0.scalarInt("PRAGMA user_version") }
            print("  schema version:", ver)
            #expect(ver == DatabaseMigrator.latestVersion)
        }
    }
}
