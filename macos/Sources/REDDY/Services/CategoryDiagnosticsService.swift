import Foundation

/// One row of the category check: how many folders each stage of the pipeline has for a source and content type.
struct CategoryDiagnosticRow: Identifiable, Sendable, Equatable {
    let kind: ContentKind
    /// Entries the provider listed. nil until a sync or a live check has run.
    var provider: Int?
    var parsed: Int?
    var rejected: Int
    var rejectedReasons: [String]
    /// Rows in the database.
    var stored: Int
    /// What the repository hands to the interface (hidden folders left out).
    var returned: Int
    /// Folders the sidebar lists, after the "hide empty folders" setting, including Uncategorized.
    var displayed: Int
    var uncategorizedItems: Int
    var note: String?
    var origin: String
    var id: ContentKind { kind }

    var title: String { switch kind { case .channel: "Live TV"; case .movie: "Movies"; case .series: "Series"; case .episode: "Episodes" } }

    /// Folders the provider defined that the app is not showing, other than ones hidden by the user or empty by choice.
    var unexplainedGap: Int? { provider.map { max(0, $0 - rejected - stored) } }
}

/// Compares the pipeline stage by stage so a missing folder can be traced to the stage that lost it.
final class CategoryDiagnosticsService: Sendable {
    let catalog: CatalogRepository
    let sources: SourceManager

    init(catalog: CatalogRepository, sources: SourceManager) { self.catalog = catalog; self.sources = sources }

    private static let kinds: [ContentKind] = [.channel, .movie, .series]

    /// From the numbers recorded by the last sync, plus live counts from the database.
    func report(sourceID: UUID, hideEmpty: Bool) throws -> [CategoryDiagnosticRow] {
        let stats = Dictionary(uniqueKeysWithValues: try catalog.categoryStats(sourceID: sourceID).map { ($0.kind, $0) })
        return try Self.kinds.map { k in
            let s = stats[k]
            return try row(sourceID: sourceID, kind: k, hideEmpty: hideEmpty, provider: s?.providerCount, parsed: s?.parsedCount,
                           rejected: s?.rejectedCount ?? 0, reasons: s?.rejectedReasons ?? [], note: s?.reconcile.note,
                           origin: s.map { "last sync, \($0.syncedAt.formatted(date: .abbreviated, time: .shortened))" } ?? "not synced yet")
        }
    }

    /// Asks the provider again (read-only; nothing is stored) and compares with what is stored.
    func liveCheck(source: PlaylistSource, hideEmpty: Bool) async throws -> [CategoryDiagnosticRow] {
        let provider = try sources.makeProvider(for: source)
        var rows: [CategoryDiagnosticRow] = []
        for k in Self.kinds {
            let f = try await provider.categoryFetch(k)
            rows.append(try row(sourceID: source.id, kind: k, hideEmpty: hideEmpty, provider: f.providerCount, parsed: f.parsedCount,
                                rejected: f.rejected.count, reasons: f.rejected, note: nil, origin: "live check just now"))
        }
        return rows
    }

    private func row(sourceID: UUID, kind: ContentKind, hideEmpty: Bool, provider: Int?, parsed: Int?, rejected: Int, reasons: [String], note: String?, origin: String) throws -> CategoryDiagnosticRow {
        let returned = try catalog.categories(sourceID: sourceID, kind: kind, includeHidden: false)
        let uncategorized = try catalog.uncategorizedCount(sourceID: sourceID, kind: kind)
        let shown = SidebarModel.folders(returned, hideEmpty: hideEmpty, uncategorized: uncategorized)
        return CategoryDiagnosticRow(kind: kind, provider: provider, parsed: parsed, rejected: rejected, rejectedReasons: reasons,
                                     stored: try catalog.storedCategoryCount(sourceID: sourceID, kind: kind), returned: returned.count,
                                     displayed: shown.count, uncategorizedItems: uncategorized, note: note, origin: origin)
    }

    /// Plain text for copying into a bug report. Contains counts and reasons only: no addresses, no logins.
    static func text(_ rows: [CategoryDiagnosticRow], playlist: String) -> String {
        var out = "Category check · \(playlist)\n"
        for r in rows {
            out += "\n\(r.title) (\(r.origin))\n"
            out += "  Provider: \(r.provider.map(String.init) ?? "–")   Parsed: \(r.parsed.map(String.init) ?? "–")   Rejected: \(r.rejected)\n"
            out += "  Stored: \(r.stored)   Returned: \(r.returned)   Displayed: \(r.displayed)   Uncategorized items: \(r.uncategorizedItems)\n"
            for reason in r.rejectedReasons.prefix(10) { out += "  rejected – \(reason)\n" }
            if let n = r.note { out += "  note – \(n)\n" }
        }
        return out
    }
}
