import Foundation

struct ChannelQuery: Sendable {
    var sourceID: UUID?
    var categoryID: String?
    var favoritesOnly = false
    var search = ""
    /// Show one row per group of quality variants (HD/FHD/…). Search always shows every match.
    var collapseVariants = true
    var includeHidden = false
    var onlyWithGuide = false
    /// Newest first by the time the channel was first imported.
    var recentlyAdded = false
    /// Sort by name instead of the provider's own order.
    var sortAlphabetically = false
    var ids: [String]?
    var limit: Int?
    var offset = 0
}

enum VODSort: String, Sendable, CaseIterable, Identifiable {
    case recentlyAdded = "Recently Added", title = "Title", titleDescending = "Title Z–A", year = "Year", yearOldest = "Year (oldest)"
    case rating = "Rating", durationShortest = "Duration (shortest)", durationLongest = "Duration (longest)"
    var id: String { rawValue }
}

/// How much of a catalog carries each sortable fact. Used to offer only the sort orders the data can really support.
struct VODMetadataCoverage: Sendable, Equatable {
    var total = 0, rated = 0, withYear = 0, withDuration = 0

    private func supports(_ n: Int) -> Bool { total > 0 && n >= min(total, 5) && Double(n) / Double(total) >= 0.2 }
    var supportsRating: Bool { supports(rated) }
    var supportsYear: Bool { supports(withYear) }
    var supportsDuration: Bool { supports(withDuration) }
}

enum WatchFilter: String, Sendable { case started, watched }

struct VODQuery: Sendable {
    var sourceID: UUID?
    var categoryID: String?
    var favoritesOnly = false
    var search = ""
    var sort: VODSort = .recentlyAdded
    var year: Int?
    /// Titles never played (a series counts as played once any episode was). Used by the Unwatched lists.
    var unwatchedOnly = false
    /// Titles the provider added in the last N days. Titles with no added date are left out rather than guessed.
    var addedWithinDays: Int?
    /// Series that gained an episode the person has not played yet (see NewEpisodeService). Not meaningful for movies.
    var newEpisodesOnly = false
    /// The language a title is marked with ("(Telugu)" in the title, or the folder is named after it), the picture quality it names, and the lowest provider rating.
    var language: String?
    var quality: String?
    var minRating: Double?
    /// A release decade such as 2010 (2010 to 2019).
    var decade: Int?
    /// Titles played to the end, or started and not finished. A series is watched when every episode is.
    var watch: WatchFilter?
    var includeHidden = false
    var ids: [String]?
    var limit: Int?
    var offset = 0
}

struct CatalogCounts: Sendable, Equatable {
    var channels = 0, movies = 0, series = 0
}

struct SyncScopeState: Sendable, Hashable {
    let scope: String
    var lastSuccess: Date?
    var lastAttempt: Date?
    var etag: String?
    var lastModified: String?
    var itemCount: Int
    var error: String?
}

protocol CatalogRepository: Sendable {
    func sources() throws -> [PlaylistSource]
    func source(id: UUID) throws -> PlaylistSource?
    func save(source: PlaylistSource) throws
    func deleteSource(id: UUID) throws
    func setEnabled(_ enabled: Bool, sourceID: UUID) throws
    func updateSyncStatus(sourceID: UUID, status: String, lastSync: Date?) throws
    func saveCapabilities(_ c: SourceCapabilities, sourceID: UUID) throws

    func syncStates(sourceID: UUID) throws -> [SyncScopeState]
    func recordSync(sourceID: UUID, scope: String, success: Bool, itemCount: Int?, etag: String?, lastModified: String?, error: String?) throws

    func categories(sourceID: UUID?, kind: ContentKind, includeHidden: Bool) throws -> [CatalogCategory]
    func channels(_ q: ChannelQuery) throws -> [Channel]
    func channel(id: String) throws -> Channel?
    func variants(ofChannel id: String) throws -> [(variant: Channel, label: String)]
    func movies(_ q: VODQuery) throws -> [Movie]
    func movie(id: String) throws -> Movie?
    func series(_ q: VODQuery) throws -> [Series]
    func seriesItem(id: String) throws -> Series?
    func seasons(seriesID: String) throws -> [Season]
    func episodes(seriesID: String) throws -> [Episode]
    func episode(id: String) throws -> Episode?
    func recordCategoryStats(sourceID: UUID, kind: ContentKind, fetch: CategoryFetch, reconcile: CategoryReconcile) throws
    func categoryStats(sourceID: UUID) throws -> [CategoryStatsRow]
    /// Rows in the categories table for one source and type, regardless of hidden/enabled filters.
    func storedCategoryCount(sourceID: UUID, kind: ContentKind) throws -> Int
    /// Items that belong to no category, for the interface's "Uncategorized" folder.
    func uncategorizedCount(sourceID: UUID?, kind: ContentKind) throws -> Int
    /// Episodes whose title contains `term`. Only episodes already downloaded (series that were opened) exist locally.
    func searchEpisodes(term: String, sourceID: UUID?, limit: Int) throws -> [Episode]
    /// Folders (categories) whose name contains every word of `term`, across enabled playlists.
    func searchCategories(term: String, limit: Int) throws -> [CatalogCategory]
    /// Counts of rated / dated / timed items for sorting, from the index (movies or series; sourceID nil = every enabled playlist).
    func metadataCoverage(kind: ContentKind, sourceID: UUID?) throws -> VODMetadataCoverage
    func counts(sourceID: UUID?) throws -> CatalogCounts
    /// Number of titles a query would return (ignores limit/offset), for "1,234 titles" labels.
    func countMovies(_ q: VODQuery) throws -> Int
    func countSeries(_ q: VODQuery) throws -> Int
    func genres(kind: ContentKind) throws -> [String]
    func years(kind: ContentKind) throws -> [Int]
    /// Every channel including hidden ones and quality variants, for the Command Center.
    func allChannelsForManagement(sourceID: UUID?) throws -> [Channel]
}
