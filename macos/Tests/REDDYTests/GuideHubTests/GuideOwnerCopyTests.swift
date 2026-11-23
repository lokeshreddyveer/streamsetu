import Testing
import Foundation
@testable import REDDY

/// Runs only when GUIDE_OWNER_COPY points at a copy of a library database. Prints counts only: never addresses, logins or names. Uses the public channel database (public files, no login).
@Suite("Guide hub: library copy dry run") struct GuideOwnerCopyTests {
    @Test func enrichmentDryRunOnACopy() async throws {
        guard let path = ProcessInfo.processInfo.environment["GUIDE_OWNER_COPY"] else { return }
        let db = try DatabaseManager(path: path)
        func n(_ sql: String) -> Int { (try? db.read { try $0.scalarInt(sql) }) ?? -1 }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iptvorg-copy-\(UUID().uuidString)")
        let database = IPTVOrgDatabase(directory: dir, fetcher: HTTPGuideFileFetcher(http: HTTPClient()))
        try await database.refresh(force: true)
        let index = try await database.loadIndex()
        let before = (channels: n("SELECT COUNT(*) FROM channels WHERE is_primary=1"), noLogo: n("SELECT COUNT(*) FROM channels WHERE is_primary=1 AND (logo_url IS NULL OR logo_url='')"), noCountry: n("SELECT COUNT(*) FROM channels WHERE is_primary=1 AND (country IS NULL OR country='')"), noLang: n("SELECT COUNT(*) FROM channels WHERE is_primary=1 AND (language IS NULL OR language='')"))
        let t0 = Date()
        let r = try ChannelEnrichmentService(db: db).apply(index: index)
        let secs = Date().timeIntervalSince(t0)
        print("GUIDEHUB-COPY index \(index.count) records, \(index.blocked.count) blocked; library \(before.channels) channels (no logo \(before.noLogo), no country \(before.noCountry), no language \(before.noLang))")
        print("GUIDEHUB-COPY enrichment: considered \(r.considered), skipped restricted \(r.skippedRestricted), matched \(r.matched), logos gained \(r.logosGained), genres \(r.genresGained), countries \(r.countriesGained), languages \(r.languagesGained) in \(String(format: "%.1f", secs)) s")
        print("GUIDEHUB-COPY guide: epg channels \(n("SELECT COUNT(*) FROM epg_channels")), epg programmes \(n("SELECT COUNT(*) FROM epg_programs")), mapped \(n("SELECT COUNT(*) FROM epg_channel_mappings")), v25 sources \(n("SELECT COUNT(*) FROM guide_sources"))")
        let m = try GuideSettingsModel.load(db: db)
        print("GUIDEHUB-COPY settings rows \(m.rows.count), worst level \(m.worst.rawValue), summaries \(m.rows.map(\.summary))")
        let d = try SQLiteGuideRepository(db: db).diagnostics()
        for x in d { print("GUIDEHUB-COPY diagnostics: kind \(x.kind.rawValue) channels \(x.channelsInFile) stored programmes \(x.storedProgrammes) findings \(GuideDiagnosisAdvisor.findings(x, now: Date()).map(\.key))") }
    }
}
