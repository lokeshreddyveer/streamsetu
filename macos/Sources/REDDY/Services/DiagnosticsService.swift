import Foundation

final class DiagnosticsService: @unchecked Sendable {
    private let db: DatabaseManager
    private let catalog: CatalogRepository
    private let lock = NSLock()
    private var recentErrors: [String] = []

    init(db: DatabaseManager, catalog: CatalogRepository) { self.db = db; self.catalog = catalog }

    /// Errors are stored redacted and capped, so a diagnostics export never contains logins or tokens.
    func record(_ message: String) {
        lock.withLock {
            recentErrors.append("\(ISO8601DateFormatter().string(from: Date())) \(CredentialRedactor.redact(message))")
            if recentErrors.count > 100 { recentErrors.removeFirst(recentErrors.count - 100) }
        }
    }

    /// A sanitized report. Passwords, tokens and stream addresses never appear: sources are shown by host only, and the
    /// whole text is passed through `CredentialRedactor` before it is returned.
    func report(playback: String? = nil, engines: [String] = []) -> String {
        var lines: [String] = []
        let info = Bundle.main.infoDictionary
        lines.append("StreamSetu \(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "0"))")
        lines.append("\(Self.platformName) \(ProcessInfo.processInfo.operatingSystemVersionString) · \(Self.architecture)")
        lines.append("Generated \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("PLAYBACK")
        lines += engines.map { "  " + $0 }
        #if os(macOS) || STREAMSETU_MPV
        let mpv = MPVLibrary.shared
        lines.append("  MPV engine: \(mpv.isAvailable ? "available" : "not available")\(mpv.loadError.map { " (\($0))" } ?? "")")
        #endif
        if let playback { lines.append("  Current: \(playback)") }
        lines.append("")
        lines.append("DATABASE")
        let c = (try? catalog.counts(sourceID: nil)) ?? CatalogCounts()
        lines.append("  Catalog: \(c.channels) channels, \(c.movies) movies, \(c.series) series")
        lines.append("  Schema v\((try? db.read { try $0.scalarInt("PRAGMA user_version") }) ?? -1), \(StorageService.shared.formatBytes(StorageService.shared.databaseSize()))")
        if let h = try? IndexHealthMonitor(db: db).check() {
            lines.append("  Index health: \(h.healthy ? "OK" : "needs repair") (integrity: \(h.integrityMessage), search docs: \(h.searchDocs)/\(h.catalogItems), orphans: \(h.orphanedSearchDocs))")
        }
        lines.append("")
        lines.append("PLAYLISTS")
        for s in (try? catalog.sources()) ?? [] {
            let host = URL(string: s.baseURL)?.host ?? "local"
            lines.append("  \"\(s.name)\" [\(s.type.rawValue)] host \(host) — \(s.enabled ? "enabled" : "disabled"), \(s.syncStatus), last sync: \(s.lastSync.map { $0.formatted() } ?? "never")")
            for st in (try? catalog.syncStates(sourceID: s.id)) ?? [] {
                lines.append("    \(st.scope): \(st.itemCount) items, ok: \(st.lastSuccess.map { $0.formatted() } ?? "never")\(st.error.map { ", error: \($0)" } ?? "")")
            }
            for r in (try? catalog.categoryStats(sourceID: s.id)) ?? [] {
                lines.append("    \(r.kind.rawValue) folders: provider \(r.providerCount), parsed \(r.parsedCount), rejected \(r.rejectedCount), stored \((try? catalog.storedCategoryCount(sourceID: s.id, kind: r.kind)) ?? 0)")
            }
            let consistency = CatalogOverviewService.consistency(catalog: catalog, source: s)
            lines.append("    catalog consistency: \(consistency.consistent ? "OK" : consistency.details.joined(separator: "; "))")
        }
        lines.append("")
        lines.append("SYNC DURATIONS (latest)")
        let jobs: [(String, Double, String)] = (try? db.read { c in
            try c.query("SELECT state, finished_at - started_at, source_id FROM sync_jobs WHERE finished_at IS NOT NULL ORDER BY started_at DESC LIMIT 8") { ($0.string(0), $0.double(1), $0.string(2)) }
        }) ?? []
        if jobs.isEmpty { lines.append("  none recorded") }
        for j in jobs { lines.append("  \(j.0): \(String(format: "%.1f", j.1)) s") }
        lines.append("")
        lines.append("PLAYBACK OUTCOMES (latest 50 sessions)")
        let outcomes: [(String, Int)] = (try? db.read { c in
            try c.query("SELECT COALESCE(outcome,'unknown'), COUNT(*) FROM (SELECT outcome FROM playback_sessions ORDER BY id DESC LIMIT 50) GROUP BY 1 ORDER BY 2 DESC") { ($0.string(0), $0.int(1)) }
        }) ?? []
        if outcomes.isEmpty { lines.append("  none recorded") }
        for o in outcomes { lines.append("  \(o.0): \(o.1)") }
        let codes: [(String, Int)] = (try? db.read { c in
            try c.query("SELECT error, COUNT(*) FROM (SELECT error FROM playback_sessions WHERE error IS NOT NULL AND error != '' ORDER BY id DESC LIMIT 50) GROUP BY 1 ORDER BY 2 DESC LIMIT 8") { ($0.string(0), $0.int(1)) }
        }) ?? []
        for e in codes { lines.append("  error \"\(e.0)\": \(e.1)") }
        let errs = lock.withLock { recentErrors }
        lines.append("")
        lines.append("RECENT ERRORS (\(errs.count))")
        if errs.isEmpty { lines.append("  none this session") }
        else {
            var categories: [String: Int] = [:]
            for e in errs { categories[Self.category(of: e), default: 0] += 1 }
            for (k, v) in categories.sorted(by: { $0.value > $1.value }) { lines.append("  \(k): \(v)") }
            lines += errs.suffix(15).map { "  " + $0 }
        }
        lines.append("")
        lines.append("RECENT PLAYBACK LOG (newest last)")
        let log = PlaybackLog.shared.tail(lines: 120)
        lines += log.isEmpty ? ["  empty"] : log.map { "  " + $0 }
        return CredentialRedactor.redact(lines.joined(separator: "\n"))
    }

    static var platformName: String {
        #if os(macOS)
        "macOS"
        #else
        "iOS"
        #endif
    }

    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    static func category(of message: String) -> String {
        let m = message.lowercased()
        if m.contains("timeout") || m.contains("timed out") { return "timeout" }
        if m.contains("401") || m.contains("403") || m.contains("auth") || m.contains("login") || m.contains("credential") { return "authentication" }
        if m.contains("network") || m.contains("offline") || m.contains("connection") || m.contains("host") { return "network" }
        if m.contains("format") || m.contains("codec") || m.contains("unsupported") { return "format" }
        if m.contains("database") || m.contains("sqlite") { return "database" }
        return "other"
    }
}
