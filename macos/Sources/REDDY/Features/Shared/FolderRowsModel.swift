import SwiftUI
import Observation

/// Folders or Grid for Movies, Series and Live TV. Folders is the default; the choice is remembered per profile on this device only (never synced).
enum FolderViewMode: String, Sendable {
    case folders, grid
    static func key(_ kind: ContentKind, profile: String) -> String { "folderView.\(kind.rawValue).\(profile)" }
    static func load(_ kind: ContentKind, profile: String, defaults: UserDefaults = .standard) -> FolderViewMode {
        defaults.string(forKey: key(kind, profile: profile)).flatMap(FolderViewMode.init(rawValue:)) ?? .folders
    }
    static func save(_ mode: FolderViewMode, _ kind: ContentKind, profile: String, defaults: UserDefaults = .standard) { defaults.set(mode.rawValue, forKey: key(kind, profile: profile)) }
}

/// A clean display name for a provider folder: the provider's prefix codes and separators are noise on a row title. The original name is never changed or stored differently.
enum FolderNaming {
    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"^[A-Za-z]{2,3}\s*[|:\-]\s+"#, options: .regularExpression), s.distance(from: s.startIndex, to: r.upperBound) < s.count { s.removeSubrange(r) }
        s = s.replacingOccurrences(of: #"\s*[|]+\s*"#, with: " · ", options: .regularExpression)
        s = s.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ·-:"))
        if s.isEmpty { return raw }
        let letters = s.filter(\.isLetter)
        if !letters.isEmpty, letters.allSatisfy({ $0.isUppercase }) { s = s.capitalized }
        return upperAcronyms(s)
    }

    /// Picture and sound standards are written in capitals whatever case the provider used ("Fhd" -> "FHD", "4k" -> "4K"). Whole words only, so "Shd" or "Hdr" inside a longer word is never touched,
    /// and "CAM" is left alone: it is a quality rank, not a name.
    static let acronyms: Set<String> = ["fhd", "uhd", "hd", "sd", "hdr", "hdr10", "4k", "8k", "2k", "3d", "hevc", "vod", "tv", "uk", "usa", "dts", "ppv"]
    static func upperAcronyms(_ s: String) -> String {
        var out = "", word = ""
        func flush() { out += acronyms.contains(word.lowercased()) ? word.uppercased() : word; word = "" }
        for ch in s { if ch.isLetter || ch.isNumber { word.append(ch) } else { flush(); out.append(ch) } }
        flush()
        return out
    }
}

/// The one quiet line under a tile in a folder row: a short genre, else the year, else nothing. A provider's "genre" is often the folder it came from ("ENGLISH | 4K"), which the row
/// header already says, so anything that repeats the folder, looks like a quality tag or is long is dropped.
enum FolderTileLine {
    static func line(for item: LibraryItem, folder: String) -> String? {
        if let g = item.genre, let first = usableGenre(g, folder: folder) { return first }
        if let y = item.year, !item.title.contains(String(y)) { return String(y) }
        return nil
    }

    static func usableGenre(_ raw: String, folder: String) -> String? {
        guard !raw.contains("|") else { return nil }
        let first = (raw.split(whereSeparator: { ",/;".contains($0) }).first.map(String.init) ?? raw).trimmingCharacters(in: .whitespaces)
        guard !first.isEmpty, first.count <= 22 else { return nil }
        let gw = IdentityKey.words(first), fw = Set(IdentityKey.words(folder))
        guard !gw.isEmpty, !gw.allSatisfy(fw.contains), !gw.contains(where: { FolderNaming.acronyms.contains($0) || ["cam", "fullhd", "1080p", "720p", "2160p"].contains($0) }) else { return nil }
        return first
    }
}

extension FolderRowsModel.Row {
    /// "English · 4K" read aloud as "English 4K".
    var spokenName: String { display.replacingOccurrences(of: " · ", with: " ") }
    /// "(1,058)": shown dim and smaller beside the name.
    var countText: String { "(\(count.formatted()))" }
}

/// The folder list for one kind, paged 20 at a time, with each row's tiles loaded only when the row first appears.
@MainActor @Observable
final class FolderRowsModel {
    struct Row: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let display: String
        let count: Int
        let locked: Bool
        let sourceID: UUID
        /// Live TV only: "favourites" and "recent" rows that lead the list.
        var special: String? = nil
        /// A folder that is locked but open for this session (the PIN was entered): its own titles are listed, not recommendations.
        var sessionUnlocked = false
        /// "All Playlists": the same-named folders of the other playlists, folded into this row. Their titles and channels fill the row's tiles too (the row opens the first one).
        var siblings: [String] = []
        var folderIDs: [String] { [id] + siblings }
    }
    nonisolated static let page = 20
    nonisolated static let tileCount = 12

    let kind: ContentKind
    private(set) var rows: [Row] = []
    private(set) var shown = FolderRowsModel.page
    private(set) var loaded = false
    private(set) var tiles: [String: [LibraryItem]] = [:]
    /// Live TV: the channels of each row in the provider's own order (never shuffled), and what is on now for them.
    private(set) var channelTiles: [String: [Channel]] = [:]
    private(set) var onNow: [String: EPGProgram] = [:]
    private var requested: Set<String> = []
    private var generation = 0
    /// Counts every time the rows' tiles were cleared (a reload finished). A row's loading task is keyed by it, so rows already on screen ask again and refill.
    private(set) var epoch = 0
    private var lastKey: String?
    /// The screen's own reload key when the rows were last read; a returning screen with the same key skips the read.
    var lastReloadKey: String?

    /// Never reused for another model.
    let uid = ScreenModelID.next()
    init(kind: ContentKind) { self.kind = kind; Perf.bump("FolderRowsModel") }

    var visible: [Row] { Array(rows.prefix(shown)) }
    var hasMore: Bool { shown < rows.count }
    func more() { if hasMore { shown = min(rows.count, shown + Self.page) } }
    /// Makes sure the row is among the rendered ones (a saved scroll position can be past the first page) and says whether it exists.
    @discardableResult func reveal(_ id: String) -> Bool {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return false }
        shown = max(shown, min(rows.count, i + 1))
        return true
    }

    /// Pinned (the person's own order) first, then recently opened, then folders named for the preferred language, then the rest in the provider's order. A locked folder keeps its place.
    /// `restrictionKey` names what the rows depend on besides the catalog (restriction revision, profile, playlist). While it stays the same, a reload keeps the tiles already loaded, so a bump that only means "something changed" (a sync, a removed Continue Watching entry) never sends rows back to placeholders or resets their scroll. nil always starts over.
    func reload(_ c: AppContainer, sourceID: UUID?, profile: String, restrictionKey: String? = nil) async {
        generation += 1
        let gen = generation
        let kind = kind, pref = OtherLanguages.preferredName(c.settings.preferredAudioLanguage)?.lowercased()
        let built = await Task.detached { () -> [Row] in
            let cats = (try? c.catalog.categories(sourceID: sourceID, kind: kind, includeHidden: false)) ?? []
            let pinned = Set((try? c.db.read { try $0.query("SELECT category_id FROM folder_order") { $0.string(0) } }) ?? [])
            let recent = c.smartMix.recentFolders(profile: profile)
            let restricting = c.catalog.isRestricting
            var seen = Set<String>()
            var list: [(Row, Int)] = []
            var firstIndex: [String: Int] = [:]
            for (i, cat) in cats.enumerated() {
                let locked = cat.isLocked && restricting
                if cat.itemCount == 0 && !locked { continue }
                // Twin playlists list the same folder twice: one row per name.
                // (a name made only of symbols or emoji has no words: its own spelling is the key, so such folders never collapse into one)
                let w = IdentityKey.words(cat.name).joined(separator: " ")
                let nameKey = w.isEmpty ? "name:" + cat.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : w
                guard seen.insert(nameKey).inserted else {
                    // The twin folder of another playlist: its titles still count towards this row's tiles (an unlocked one only).
                    if !locked, let at = firstIndex[nameKey], list[at].0.sourceID != cat.sourceID, !list[at].0.locked { list[at].0.siblings.append(cat.id) }
                    continue
                }
                firstIndex[nameKey] = list.count
                let rank: Int
                if pinned.contains(cat.id) { rank = 0 }
                else if recent.contains(cat.id) { rank = 1 }
                else if let pref, IdentityKey.words(cat.name).contains(pref) { rank = 2 }
                else { rank = 3 }
                let recentIdx = recent.firstIndex(of: cat.id) ?? 999
                list.append((Row(id: cat.id, name: cat.name, display: FolderNaming.clean(cat.name), count: cat.itemCount, locked: locked, sourceID: cat.sourceID, sessionUnlocked: cat.isLocked && !restricting), rank * 100_000 + (rank == 1 ? recentIdx : i)))
            }
            var out = list.sorted { $0.1 < $1.1 }.map(\.0)
            if kind == .channel {
                var lead: [Row] = []
                let favs = (try? c.catalog.countChannels(ChannelQuery(sourceID: sourceID, favoritesOnly: true, collapseVariants: false))) ?? 0
                if favs > 0 { lead.append(Row(id: "special-favourites", name: "Favourites", display: "Favourites", count: favs, locked: false, sourceID: sourceID ?? UUID(), special: "favourites")) }
                // The row is built from what the (restricted) catalog still returns, so a channel in a locked folder is neither shown nor counted.
                let recentIDs = (try? c.historyRepo.recentIDs(kind: .channel, limit: 12)) ?? []
                let recents = recentIDs.isEmpty ? [] : ((try? c.catalog.channels(ChannelQuery(collapseVariants: false, ids: recentIDs))) ?? []).filter { sourceID == nil || $0.sourceID == sourceID }
                if !recents.isEmpty { lead.append(Row(id: "special-recent", name: "Recently Watched", display: "Recently Watched", count: recents.count, locked: false, sourceID: sourceID ?? UUID(), special: "recent")) }
                out = lead + out
            }
            return out
        }.value
        guard gen == generation else { return }
        let keep = loaded && restrictionKey != nil && restrictionKey == lastKey
        lastKey = restrictionKey
        rows = built; shown = min(max(Self.page, shown), max(Self.page, built.count)); loaded = true
        if !keep { epoch += 1; tiles = [:]; channelTiles = [:]; onNow = [:]; requested = [] }
    }

    func ensureTiles(_ row: Row, _ c: AppContainer, sourceID: UUID?, profile: String) async {
        guard !row.locked, tiles[row.id] == nil, channelTiles[row.id] == nil, requested.insert(row.id).inserted else { return }
        let sp = SmoothSignpost.begin("FolderRowsEnsureTiles"); defer { SmoothSignpost.end(sp, "FolderRowsEnsureTiles") }
        if kind == .channel { await ensureChannels(row, c, sourceID: sourceID); return }
        let kind = kind, lang = c.settings.preferredAudioLanguage
        let ep = epoch
        var items = row.sessionUnlocked ? [] : await c.smartMix.folderItems(profile: profile, sourceID: sourceID, kind: kind, folderName: row.name, preferredLanguage: lang)
        // A row scrolled away cancels this task: nothing is stored, and the row is asked again when it comes back (the engine call is not allowed to turn a cancellation into a result).
        if Task.isCancelled || ep != epoch { requested.remove(row.id); return }
        if items.isEmpty {
            // Identity not ready (or the folder is unlocked for this session): the folder's own newest titles, read through the recommendation view so a title with a restricted copy is never listed.
            items = await Task.detached { () -> [LibraryItem] in
                let view: any CatalogRepository = row.sessionUnlocked ? c.catalog : c.catalog.recommendationView
                var out: [LibraryItem] = []
                for id in row.folderIDs {
                    let q = VODQuery(sourceID: id == row.id ? row.sourceID : nil, categoryID: id, sort: .recentlyAdded, limit: Self.tileCount * 3)
                    out += kind == .series ? ((try? view.series(q)) ?? []).map { .series($0) } : ((try? view.movies(q)) ?? []).map { .movie($0) }
                }
                return out
            }.value
            if Task.isCancelled || ep != epoch { requested.remove(row.id); return }
        }
        tiles[row.id] = Array(FolderTileOrder.preferPosters(Array(items.prefix(Self.tileCount * 3))).prefix(Self.tileCount))
    }
}

/// Posters first: a title without a poster is a grey placeholder, so tiles that have one lead and the others follow only when there are not enough. Order within each group is kept.
enum FolderTileOrder {
    /// A row never starts with grey placeholders: with enough titles that have a poster the others are left out, otherwise they follow the ones that do. Order within each group is kept.
    static func preferPosters(_ items: [LibraryItem], enough: Int = 6) -> [LibraryItem] {
        let with = items.filter(hasPoster)
        return with.count >= enough ? with : with + items.filter { !hasPoster($0) }
    }
    static func hasPoster(_ item: LibraryItem) -> Bool { (item.posterURL?.isEmpty == false) }
}

extension FolderRowsModel {
    /// Live TV tiles: favourites and recent first (their own order), a folder's channels in the provider's order. Guide data is read once for the 12 channels shown.
    func ensureChannels(_ row: Row, _ c: AppContainer, sourceID: UUID?) async {
        let ep = epoch
        let (list, now) = await Task.detached { () -> ([Channel], [String: EPGProgram]) in
            var chans: [Channel]
            switch row.special {
            case "favourites":
                chans = (try? c.catalog.channels(ChannelQuery(sourceID: sourceID, favoritesOnly: true, collapseVariants: false, limit: Self.tileCount))) ?? []
            case "recent":
                let ids = (try? c.historyRepo.recentIDs(kind: .channel, limit: Self.tileCount)) ?? []
                let by = Dictionary(((try? c.catalog.channels(ChannelQuery(collapseVariants: false, ids: ids))) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                chans = ids.compactMap { by[$0] }.filter { sourceID == nil || $0.sourceID == sourceID }
            default:
                chans = []
                for id in row.folderIDs where chans.count < Self.tileCount {
                    chans += (try? c.catalog.channels(ChannelQuery(sourceID: id == row.id ? row.sourceID : nil, categoryID: id, limit: Self.tileCount - chans.count))) ?? []
                }
            }
            let g = (try? c.epgRepo.lookup(channelIDs: chans.map(\.id), at: Date())) ?? [:]
            return (chans, g.compactMapValues { $0.now })
        }.value
        if Task.isCancelled || ep != epoch { requested.remove(row.id); return }          // a lock, hide or reload happened while this was being read: the answer belongs to the old state
        channelTiles[row.id] = list
        for (k, v) in now { onNow[k] = v }
    }
}

/// Where the folder list was scrolled to, kept outside the view so coming back from a folder lands on the same row.
@MainActor final class FolderScrollMemory {
    static let shared = FolderScrollMemory()
    private var top: [String: String] = [:]
    func get(_ key: String) -> String? { top[key] }
    func set(_ key: String, _ id: String?) { top[key] = id }
}
