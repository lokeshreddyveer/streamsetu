import SwiftUI
import Observation
#if os(macOS)
import AppKit
#endif

// The pure rules behind Music's lists and pages (selection, sorting, filtering, columns, suggestions, scroll memory, release grouping) and the
// few small views that carry them. Everything that is not a view is plain values so it can be tested without a screen.

// MARK: - multi-select

/// Which rows of a track list are picked. Cmd-click toggles one, Shift-click picks the span from the last pick, and a plain click toggles
/// only while selecting (otherwise it plays).
struct MusicTrackSelection: Equatable, Sendable {
    private(set) var selected: Set<String> = []
    private(set) var anchor: String?
    private(set) var active = false

    enum Click: Sendable { case plain, command, shift }

    var count: Int { selected.count }
    func contains(_ uid: String) -> Bool { selected.contains(uid) }

    mutating func enter() { active = true }
    mutating func exit() { active = false; selected = []; anchor = nil }
    mutating func clear() { selected = []; anchor = nil }

    mutating func toggle(_ uid: String) {
        active = true
        if selected.contains(uid) { selected.remove(uid) } else { selected.insert(uid) }
        anchor = uid
    }

    /// Picks everything between the last pick and `uid`, in the order shown. With no earlier pick it picks just this row.
    mutating func extend(to uid: String, order: [String]) {
        active = true
        guard let a = anchor, let i = order.firstIndex(of: a), let j = order.firstIndex(of: uid) else { toggle(uid); return }
        for k in min(i, j)...max(i, j) { selected.insert(order[k]) }
    }

    mutating func selectAll(_ order: [String]) { active = true; selected = Set(order); anchor = order.first }

    /// What a click does. True when the selection took it; false means the caller should play the row.
    mutating func click(_ uid: String, order: [String], kind: Click) -> Bool {
        switch kind {
        case .command: toggle(uid); return true
        case .shift: extend(to: uid, order: order); return true
        case .plain:
            guard active else { return false }
            toggle(uid); return true
        }
    }

    /// Drops picks whose rows are gone (a filter, a removal).
    mutating func prune(keeping uids: Set<String>) {
        selected.formIntersection(uids)
        if let a = anchor, !uids.contains(a) { anchor = nil }
    }

    func ordered(_ tracks: [MusicTrack]) -> [MusicTrack] { tracks.filter { selected.contains($0.uid) } }
}

// MARK: - sort and filter

enum MusicTrackSortField: String, CaseIterable, Identifiable, Sendable {
    case original, title, artist, album, duration
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: Localized.string("Playlist order")
        case .title: Localized.string("Title")
        case .artist: Localized.string("Artist")
        case .album: Localized.string("Album")
        case .duration: Localized.string("Length")
        }
    }
}

struct MusicTrackOrdering: Equatable, Sendable {
    var field: MusicTrackSortField = .original
    var ascending = true

    var isDefault: Bool { field == .original && ascending }

    func apply(_ tracks: [MusicTrack]) -> [MusicTrack] {
        if field == .original { return ascending ? tracks : tracks.reversed() }
        let keyed = tracks.enumerated().map { (offset: $0.offset, track: $0.element) }
        let sorted = keyed.sorted { a, b in
            let c = Self.compare(a.track, b.track, by: field)
            if c == .orderedSame { return a.offset < b.offset }
            return ascending ? c == .orderedAscending : c == .orderedDescending
        }
        return sorted.map(\.track)
    }

    private static func compare(_ a: MusicTrack, _ b: MusicTrack, by f: MusicTrackSortField) -> ComparisonResult {
        switch f {
        case .original: return .orderedSame
        case .title: return a.title.localizedStandardCompare(b.title)
        case .artist: return a.artistLine.localizedStandardCompare(b.artistLine)
        case .album: return (a.album?.title ?? "").localizedStandardCompare(b.album?.title ?? "")
        case .duration: return a.durationMs == b.durationMs ? .orderedSame : (a.durationMs < b.durationMs ? .orderedAscending : .orderedDescending)
        }
    }

    var encoded: String { field.rawValue + ":" + (ascending ? "asc" : "desc") }
    init(field: MusicTrackSortField = .original, ascending: Bool = true) { self.field = field; self.ascending = ascending }
    init?(encoded: String) {
        let parts = encoded.split(separator: ":").map(String.init)
        guard parts.count == 2, let f = MusicTrackSortField(rawValue: parts[0]), parts[1] == "asc" || parts[1] == "desc" else { return nil }
        self.init(field: f, ascending: parts[1] == "asc")
    }
}

/// Remembers the sort chosen for each playlist, on this Mac.
enum MusicOrderingMemory {
    static let key = "music.playlistSort"
    static func load(_ listKey: String, defaults: UserDefaults = .standard) -> MusicTrackOrdering {
        let all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return all[listKey].flatMap(MusicTrackOrdering.init(encoded:)) ?? MusicTrackOrdering()
    }
    static func save(_ ordering: MusicTrackOrdering, for listKey: String, defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        if ordering.isDefault { all[listKey] = nil } else { all[listKey] = ordering.encoded }
        if all.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(all, forKey: key) }
    }
}

enum MusicTrackFilter {
    /// Every word typed must appear in the title, an artist name or the album, ignoring case and accents.
    static func apply(_ tracks: [MusicTrack], query: String) -> [MusicTrack] {
        let words = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !words.isEmpty else { return tracks }
        return tracks.filter { t in
            let hay = [t.title, t.artistLine, t.album?.title ?? ""].joined(separator: " ").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            return words.allSatisfy { hay.contains($0) }
        }
    }
}

// MARK: - columns

enum MusicTrackColumn: String, CaseIterable, Identifiable, Sendable {
    case artist, album, duration
    var id: String { rawValue }
    var title: String {
        switch self {
        case .artist: Localized.string("Artist")
        case .album: Localized.string("Album")
        case .duration: Localized.string("Length")
        }
    }
}

/// Which optional columns a track list shows (the title is always there). Without the artist column the artist sits under the title.
struct MusicTrackColumns: Equatable, Sendable {
    var shown: Set<MusicTrackColumn> = [.duration]
    static let key = "music.trackColumns"
    static let standard = MusicTrackColumns()
    /// Below these widths a column drops out by itself, the album first.
    static let albumMinWidth: CGFloat = 640
    static let artistMinWidth: CGFloat = 520

    func has(_ c: MusicTrackColumn) -> Bool { shown.contains(c) }
    func toggled(_ c: MusicTrackColumn) -> MusicTrackColumns {
        var n = self
        if n.shown.contains(c) { n.shown.remove(c) } else { n.shown.insert(c) }
        return n
    }
    func effective(width: CGFloat) -> MusicTrackColumns {
        var n = self
        if width > 0 && width < Self.albumMinWidth { n.shown.remove(.album) }
        if width > 0 && width < Self.artistMinWidth { n.shown.remove(.artist) }
        return n
    }
    static func load(_ defaults: UserDefaults = .standard) -> MusicTrackColumns {
        guard let raw = defaults.stringArray(forKey: key) else { return .standard }
        return MusicTrackColumns(shown: Set(raw.compactMap(MusicTrackColumn.init(rawValue:))))
    }
    func save(_ defaults: UserDefaults = .standard) { defaults.set(shown.map(\.rawValue).sorted(), forKey: Self.key) }
}

// MARK: - scroll memory

/// Where each page was scrolled to, so Back lands where the person left. The oldest entry goes first when there are too many.
struct MusicScrollStore: Equatable, Sendable {
    static let capacity = 40
    private(set) var offsets: [String: Double] = [:]
    private(set) var order: [String] = []

    func offset(for key: String) -> Double? { offsets[key] }

    mutating func record(_ key: String, _ y: Double) {
        // A page at the very top needs nothing restored.
        if y < 1 { offsets[key] = nil; order.removeAll { $0 == key }; return }
        offsets[key] = y
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.capacity { offsets[order.removeFirst()] = nil }
    }

    /// The page is long enough again (its rows have loaded) to scroll to `y`.
    static func canRestore(y: Double, contentHeight: Double, viewport: Double) -> Bool { contentHeight - viewport >= y - 1 }
}

enum MusicScrollKey {
    /// Legacy routes keep their old keys (saved offsets still match); entity routes key on the id and role.
    static func route(_ r: MusicRoute) -> String { r.scrollKey }
    static func section(_ s: MusicSection) -> String { "section:" + s.rawValue }
}

@MainActor @Observable
final class MusicScrollMemory {
    static let shared = MusicScrollMemory()
    @ObservationIgnored private(set) var store = MusicScrollStore()
    func record(_ key: String, _ y: Double) { store.record(key, y) }
    func offset(for key: String) -> Double? { store.offset(for: key) }
}

struct MusicScrollSnapshot: Equatable, Sendable { var y: Double; var content: Double; var viewport: Double }

/// Remembers the scroll position under `key` and shows a back-to-top button on long pages. Needs macOS 15 or later; earlier systems get the plain page.
struct MusicScrollTracking: ViewModifier {
    let key: String
    func body(content: Content) -> some View {
        if #available(macOS 15.0, iOS 18.0, *) { content.modifier(MusicScrollTrackingModern(key: key)) } else { content }
    }
}

@available(macOS 15.0, iOS 18.0, *)
private struct MusicScrollTrackingModern: ViewModifier {
    let key: String
    @State private var position = ScrollPosition()
    @State private var pending: Double?
    @State private var restoreGeneration = 0
    @State private var away = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The button appears after about 400 pt and leaves again below 250 so it does not flicker at the edge.
    static func isAway(y: Double, was: Bool) -> Bool { was ? y > 250 : y > 400 }

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: MusicScrollSnapshot.self) { g in
                MusicScrollSnapshot(y: g.contentOffset.y + g.contentInsets.top, content: g.contentSize.height, viewport: g.containerSize.height)
            } action: { _, s in handle(s) }
            .overlay(alignment: .bottomTrailing) {
                // The animation belongs to the button alone: put on the scroll view it would also animate every offset change that lands in the same update.
                ZStack {
                    if away { MusicBackToTopButton { top() }.padding(.trailing, MusicTokens.assistantReserve + MusicSpace.md).padding(.bottom, MusicPageFrame.bottomInset).transition(.opacity) }
                }
                .animation(reduceMotion ? nil : AnimationTokens.standard, value: away)
            }
            .onAppear { pending = MusicScrollMemory.shared.offset(for: key); restoreGeneration += 1 }
            // The restore is one shot and only for a moment after the page appears: every appearance restarts the expiry, so a stale target can never
            // pull the page back down later, and the person's own scrolling ends it at once.
            .task(id: restoreGeneration) { try? await Task.sleep(for: .seconds(2)); if !Task.isCancelled { pending = nil } }
            .onScrollPhaseChange { _, new in if new == .interacting || new == .decelerating { pending = nil } }
    }

    private func handle(_ s: MusicScrollSnapshot) {
        if let p = pending {
            if MusicScrollStore.canRestore(y: p, contentHeight: s.content, viewport: s.viewport) { position.scrollTo(y: p); pending = nil }
            return
        }
        MusicScrollMemory.shared.record(key, s.y)
        let now = Self.isAway(y: s.y, was: away)
        if now != away { away = now }
    }

    private func top() {
        if reduceMotion { position.scrollTo(edge: .top) } else { withAnimation(AnimationTokens.standard) { position.scrollTo(edge: .top) } }
    }
}

extension View {
    func musicScrollMemory(key: String) -> some View { modifier(MusicScrollTracking(key: key)) }
}

/// The round accent button that returns a long page to its top.
struct MusicBackToTopButton: View {
    let action: () -> Void
    @Environment(\.reddyAccent) private var accent
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.up").font(MusicTokens.iconMedium)
                .foregroundStyle(ColorTokens.onAccent(accent))
                .frame(width: MusicTokens.hitTarget + 8, height: MusicTokens.hitTarget + 8)
                .background(accent.opacity(hovering ? 0.9 : 1), in: Circle())
                .overlay(Circle().strokeBorder(ColorTokens.line))
                .shadow(color: ColorTokens.background.opacity(0.5), radius: 8, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .accessibilityLabel("Back to top").help("Back to top").atlas("control.music.backToTop")
    }
}

// MARK: - what floats above a page (selection bar, jump to now playing)

/// A page hosts one of these; its track lists post the selection bar and the "now playing" pill here, and the page draws them above its scroll view.
@MainActor @Observable
final class MusicPageOverlayHost {
    struct Bar {
        var selected: [MusicTrack]
        var total: Int
        var hiddenByFilter = 0
        var stillLoading = 0
        var onRemove: (() -> Void)?
        var selectAll: () -> Void
        var clear: () -> Void
        var exit: () -> Void
    }
    struct Pill { var above: Bool; var action: () -> Void }
    var bar: Bar?
    var pill: Pill?
}

private struct MusicOverlayHostKey: EnvironmentKey { static var defaultValue: MusicPageOverlayHost? { nil } }
extension EnvironmentValues {
    var musicOverlayHost: MusicPageOverlayHost? {
        get { self[MusicOverlayHostKey.self] }
        set { self[MusicOverlayHostKey.self] = newValue }
    }
}

/// Draws the host's selection bar and now-playing pill over whatever it wraps, and gives its track lists the host.
struct MusicOverlayHostView<Content: View>: View {
    let hub: MusicHub
    @ViewBuilder var content: Content
    @State private var host = MusicPageOverlayHost()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .environment(\.musicOverlayHost, host)
            .overlay(alignment: .bottom) {
                VStack(spacing: Spacing.sm) {
                    if let pill = host.pill, host.bar == nil { MusicNowPlayingPill(above: pill.above, action: pill.action) }
                    if let b = host.bar {
                        MusicSelectionBar(hub: hub, selected: b.selected, total: b.total, hiddenByFilter: b.hiddenByFilter, stillLoading: b.stillLoading,
                                          onRemove: b.onRemove, selectAll: b.selectAll, clear: b.clear, exit: b.exit)
                            .frame(maxWidth: 720).transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, Spacing.lg).padding(.bottom, Spacing.lg)
            }
            .animation(reduceMotion ? nil : AnimationTokens.standard, value: host.bar != nil)
    }
}

/// "Now playing" with an arrow that points to where the row is.
struct MusicNowPlayingPill: View {
    let above: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label { Text("Now playing") } icon: { Image(systemName: above ? "arrow.up" : "arrow.down") }
        }
        .musicButton(.primary, size: .compact)
        .accessibilityLabel("Jump to the song that is playing").atlas("control.music.jumpToPlaying")
    }
}

// MARK: - suggestions (search as you type)

enum MusicSuggestionRow: Equatable, Identifiable, Sendable {
    case search(String)
    /// The typed words with the misspelt ones fixed: "Did you mean ...".
    case correction(String)
    case completion(String)
    case track(MusicTrack)
    var id: String {
        switch self {
        case .search(let s): "search:" + s
        case .correction(let s): "correction:" + s
        case .completion(let s): "completion:" + s
        case .track(let t): "track:" + t.uid
        }
    }
}

enum MusicSuggest {
    static let minimumCharacters = 2
    static let debounce = Duration.milliseconds(300)
    static let maxCompletions = 5
    static let maxTracks = 4

    static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func qualifies(_ typed: String) -> Bool { trimmed(typed).count >= minimumCharacters }
    /// A reply belongs to the text now in the field, not to one typed a moment ago.
    static func isCurrent(reply: String, now: String) -> Bool { trimmed(reply) == trimmed(now) }

    /// Completions in the order a person expects: earlier searches that start with the words, then names from the live results that start with them,
    /// then the ones that only contain them. The typed text itself is never offered back, and repeats are dropped.
    static func completions(typed: String, recents: [String], local: [String] = [], tracks: [MusicTrack]) -> [String] {
        let t = trimmed(typed)
        let n = MusicSearchRanker.normalise(t)
        guard !n.isEmpty else { return [] }
        var starts: [String] = [], contains: [String] = []
        var seen: Set<String> = [n]
        func consider(_ s: String) {
            let c = trimmed(s)
            let k = MusicSearchRanker.normalise(c)
            guard !k.isEmpty, !seen.contains(k) else { return }
            if k.hasPrefix(n) { seen.insert(k); starts.append(c) }
            else if k.contains(n) { seen.insert(k); contains.append(c) }
        }
        for r in recents { consider(r) }
        // Names already seen (library, history, earlier results), matched by start, by word, by sound and after fixing the spelling: ready before any source answers.
        for l in local { let c = trimmed(l); let k = MusicSearchRanker.normalise(c); if !k.isEmpty, !seen.contains(k) { seen.insert(k); starts.append(c) } }
        for tr in tracks { consider(tr.artists.first?.name ?? ""); consider(tr.title) }
        return Array((starts + contains).prefix(maxCompletions))
    }

    /// The dropdown, top to bottom: the exact words first (always), completions, then up to four live songs (one row per recording).
    static func rows(typed: String, completions: [String], tracks: [MusicTrack], correction: String? = nil) -> [MusicSuggestionRow] {
        let t = trimmed(typed)
        guard !t.isEmpty else { return [] }
        var out: [MusicSuggestionRow] = [.search(t)]
        if let c = correction, !c.isEmpty, MusicSearchRanker.normalise(c) != MusicSearchRanker.normalise(t) { out.append(.correction(c)) }
        out += completions.prefix(maxCompletions).map { .completion($0) }
        out += MusicDedupe.tracks(tracks).prefix(maxTracks).map { .track($0) }
        return out
    }

    /// Up and Down move the highlight and wrap; with none highlighted Down picks the first and Up the last.
    static func move(_ current: Int?, by delta: Int, count: Int) -> Int? { MusicPaletteRules.move(current, by: delta, count: count) }
}

// MARK: - top result

enum MusicTopResult {
    /// The single best match across every type. An artist or album whose name fits as well as a song wins the tie, because naming one is how people search for it.
    static func pick(query: String, tracks: [MusicTrack], artists: [MusicArtist], albums: [MusicAlbum], playlists: [MusicPlaylist]) -> MusicSearchResult? {
        MusicSearchScoring.pick(query: query, tracks: tracks, artists: artists, albums: albums, playlists: playlists)
    }
}

// MARK: - releases, discs, durations

enum MusicReleaseKind: Equatable, Sendable {
    case album, single, ep, appearsOn

    static func classify(_ a: MusicAlbum) -> MusicReleaseKind {
        let t = (a.albumType ?? "").lowercased()
        if t.contains("appears") || t.contains("compilation") { return .appearsOn }
        if t.contains("single") { return .single }
        if t == "ep" || t.hasSuffix(" ep") || t.hasPrefix("ep ") { return .ep }
        if t.isEmpty, a.totalTracks == 1 { return .single }
        return .album
    }

    /// Albums, then singles and EPs, then what the artist only appears on. Each keeps its order, and a release that came twice is shown once.
    static func split(_ albums: [MusicAlbum]) -> (albums: [MusicAlbum], singles: [MusicAlbum], appearsOn: [MusicAlbum]) {
        var a: [MusicAlbum] = [], s: [MusicAlbum] = [], o: [MusicAlbum] = []
        var seen = Set<String>()
        for al in albums where seen.insert(al.uid).inserted {
            switch classify(al) { case .album: a.append(al); case .single, .ep: s.append(al); case .appearsOn: o.append(al) }
        }
        return (a, s, o)
    }
}

enum MusicDiscGroups {
    struct Group: Equatable, Sendable { var disc: Int?; var tracks: [MusicTrack] }
    /// One group per disc when the tracks carry disc numbers past 1; otherwise a single group with no heading.
    static func group(_ tracks: [MusicTrack]) -> [Group] {
        guard tracks.contains(where: { ($0.discNumber ?? 1) > 1 }) else { return [Group(disc: nil, tracks: tracks)] }
        var byDisc: [Int: [MusicTrack]] = [:]
        for t in tracks { byDisc[t.discNumber ?? 1, default: []].append(t) }
        return byDisc.keys.sorted().map { Group(disc: $0, tracks: byDisc[$0] ?? []) }
    }
}

enum MusicDurationText {
    /// "48 min", or "1 hr 5 min" from an hour up.
    static func total(ms: Int64) -> String {
        let minutes = Int((max(0, ms) + 30_000) / 60_000)
        if minutes < 60 { return Localized.string("%@ min", "\(max(1, minutes))") }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? Localized.string("%@ hr", "\(h)") : Localized.string("%@ hr", "\(h)") + " " + Localized.string("%@ min", "\(m)")
    }
}

// MARK: - dedupe and playlist membership

enum MusicDedupe {
    /// Keeps the first of each recording (same ISRC, or same title and first artist with matching length).
    static func tracks(_ list: [MusicTrack]) -> [MusicTrack] {
        var out: [MusicTrack] = []
        for t in list where !out.contains(where: { MusicSearchRanker.isSame($0, t) }) { out.append(t) }
        return out
    }
    /// Keeps the first item for each key.
    static func by<T>(_ list: [T], key: (T) -> String) -> [T] {
        var seen = Set<String>()
        return list.filter { seen.insert(key($0)).inserted }
    }
}

/// Which of the person's own playlists hold a song, for the small indicator on a row.
enum MusicPlaylistMembership {
    static func index(_ playlists: [LocalPlaylist]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for p in playlists { for t in p.tracks { out[t.uid, default: []].append(p.name) } }
        return out
    }
}

@MainActor
final class MusicMembershipCache {
    static let shared = MusicMembershipCache()
    private var signature = ""
    private var cached: [String: [String]] = [:]
    func names(for uid: String, in playlists: [LocalPlaylist]) -> [String] {
        let sig = playlists.map { "\($0.id.uuidString)\($0.tracks.count)\($0.name)" }.joined(separator: "|")
        if sig != signature { signature = sig; cached = MusicPlaylistMembership.index(playlists) }
        return cached[uid] ?? []
    }
}

// MARK: - what a card or row stands for, and what it can do

/// An item that can be played, queued, dragged or listed, whichever page it appears on.
enum MusicEntity: Hashable, Sendable {
    case track(MusicTrack), album(MusicAlbum), playlist(MusicPlaylist), artist(MusicArtist)

    var key: String {
        switch self {
        case .track(let t): "track:" + t.uid
        case .album(let a): "album:" + a.uid
        case .playlist(let p): "playlist:" + p.uid
        case .artist(let a): "artist:" + a.uid
        }
    }
    var title: String {
        switch self { case .track(let t): t.title; case .album(let a): a.title; case .playlist(let p): p.name; case .artist(let a): a.name }
    }
    var isLocal: Bool {
        switch self {
        case .track(let t): t.providerID == MusicStatsRules.localProviderID
        case .album(let a): a.providerID == MusicStatsRules.localProviderID
        case .playlist(let p): p.providerID == MusicStatsRules.localProviderID
        case .artist(let a): a.providerID == MusicStatsRules.localProviderID
        }
    }
}

@MainActor
enum MusicEntityActions {
    /// The most pages one entity loads for a Play, Shuffle, Play next or Add to queue (a page is about a hundred songs).
    static let maxPages = 20

    /// Every page of a paged source, following `next` up to `maxPages` and stopping at a page that repeats songs (a source that keeps handing back the same page).
    static func allPages(_ first: MusicPage<MusicTrack>, more: (MusicPagination) async -> MusicPage<MusicTrack>?, maxPages: Int = MusicEntityActions.maxPages) async -> [MusicTrack] {
        var items = first.items
        var seen = Set(items.map(\.uid))
        var next = first.next
        var pages = 1
        while let n = next, pages < maxPages, let page = await more(n) {
            pages += 1
            let fresh = page.items.filter { seen.insert($0.uid).inserted }
            if fresh.isEmpty { break }
            items += fresh
            next = page.next
        }
        return items
    }

    /// The songs behind an entity, fetched from the source it came from. A long playlist or album is read page by page, so Shuffle samples all of it.
    static func tracks(_ e: MusicEntity, hub: MusicHub) async -> [MusicTrack] {
        switch e {
        case .track(let t): return [t]
        case .album(let a):
            guard let source = hub.registry.metadataProvider(id: a.providerID), let first = try? await source.albumTracks(id: a.id, page: nil) else { return [] }
            return await allPages(first) { try? await source.albumTracks(id: a.id, page: $0) }
        case .playlist(let p):
            if p.providerID == MusicStatsRules.localProviderID, let id = UUID(uuidString: p.id) { return hub.library.playlist(id: id)?.tracks ?? [] }
            guard let source = hub.registry.metadataProvider(id: p.providerID), let first = try? await source.playlistTracks(id: p.id, page: nil) else { return [] }
            return await allPages(first) { try? await source.playlistTracks(id: p.id, page: $0) }
        case .artist(let a): return (try? await hub.registry.metadataProvider(id: a.providerID)?.artistTopTracks(id: a.id)) ?? []
        }
    }

    static func play(_ e: MusicEntity, shuffle: Bool = false, hub: MusicHub) async {
        let list = await tracks(e, hub: hub)
        guard !list.isEmpty else { MusicToasts.shared.show(Localized.string("Nothing to play here yet.")); return }
        // The person's own playlist keeps its source id (as the sidebar and the playlist page pass it), so the queue knows where it came from.
        var sourceID: String?
        if case .playlist(let p) = e, p.providerID == MusicStatsRules.localProviderID { sourceID = p.providerID + ":" + p.id }
        if shuffle { hub.playShuffled(list, sourceName: e.title, sourceID: sourceID) } else { hub.play(list, at: 0, sourceName: e.title, sourceID: sourceID) }
    }

    static func startRadio(_ e: MusicEntity, hub: MusicHub) async {
        // A compilation credit is not an artist: nothing to build a radio from.
        if case .artist(let a) = e, MusicCompilationArtist.isCompilation(a.name) { MusicToasts.shared.show(Localized.string("Nothing to play here yet.")); return }
        guard let seed = await tracks(e, hub: hub).first else { MusicToasts.shared.show(Localized.string("Nothing to play here yet.")); return }
        await MusicQueueActions.startRadio(seed, hub: hub)
    }

    static func playNext(_ e: MusicEntity, hub: MusicHub) async {
        let list = await tracks(e, hub: hub)
        guard !list.isEmpty else { return }
        // A room guest cannot edit the queue (the player says so): no success toast then.
        if hub.player.playNext(list, from: e.title) { MusicToasts.shared.success(Localized.string("Playing next.")) }
    }

    static func addToQueue(_ e: MusicEntity, hub: MusicHub) async {
        let list = await tracks(e, hub: hub)
        guard !list.isEmpty else { return }
        if hub.player.enqueue(list, from: e.title) { MusicToasts.shared.success(Localized.string("Added to the queue.")) }
    }

    static func addToPlaylist(_ e: MusicEntity, hub: MusicHub) async {
        let list = await tracks(e, hub: hub)
        guard !list.isEmpty else { return }
        MusicChromeState.shared.addToPlaylist = list
    }

    static func neverPlay(_ e: MusicEntity, hub: MusicHub) {
        switch e {
        case .track(let t):
            let was = hub.library.isBlacklisted(t)
            hub.library.toggleBlacklist(t)
            MusicToasts.shared.show(was ? Localized.string("%@ can play again.", t.title) : Localized.string("%@ will not be played.", t.title))
        case .artist(let a):
            let ref = MusicArtistRef(id: a.id, name: a.name)
            let was = hub.library.isBlacklisted(artist: ref)
            hub.library.toggleBlacklist(artist: ref)
            MusicToasts.shared.show(was ? Localized.string("Unblocked %@.", a.name) : Localized.string("Blocked %@.", a.name))
        default: break
        }
    }

    static func share(_ e: MusicEntity, hub: MusicHub) {
        switch e {
        case .track(let t): MusicChromeState.shared.sharing = .track(t, playing: hub.player.current?.uid == t.uid)
        case .album(let a): MusicChromeState.shared.sharing = .album(a)
        case .playlist(let p): MusicChromeState.shared.sharing = .playlist(p)
        case .artist(let a): MusicChromeState.shared.sharing = .artist(a)
        }
    }

    static func open(_ e: MusicEntity, hub: MusicHub) {
        switch e {
        case .track(let t):
            // "Open" shows the song's page; only with the song pages off (nothing to open) does it play.
            if MusicGraphKeys.pagesOn {
                // The song is written into the graph first, so its page has something to show even for a chart row nobody has played yet.
                Task { @MainActor in
                    await MusicGraphIngest.shared.ingestNow(track: t)
                    hub.open(MusicEntityID.provisional(kind: .recording, providerUID: t.uid))
                }
            } else { hub.play([t], at: 0) }
        case .album(let a): hub.open(.album(a))
        case .playlist(let p):
            if p.providerID == MusicStatsRules.localProviderID, let id = UUID(uuidString: p.id) { hub.open(.localPlaylist(id)) } else { hub.open(.playlist(p)) }
        case .artist(let a): hub.open(.artist(a))
        }
    }

    /// The artist a song, album or card belongs to, when its source named one.
    static func artistRoute(_ e: MusicEntity, hub: MusicHub) -> MusicArtist? {
        switch e {
        case .track(let t): return t.artists.first(where: { MusicCompilationArtist.isUsableArtist($0) }).flatMap { $0.id.isEmpty ? nil : hub.artist(from: $0, providerID: t.providerID) }
        case .album(let a): return a.artists.first(where: { MusicCompilationArtist.isUsableArtist($0) }).flatMap { $0.id.isEmpty ? nil : hub.artist(from: $0, providerID: a.providerID) }
        case .artist(let a): return a
        case .playlist: return nil
        }
    }

    static func albumRoute(_ e: MusicEntity, hub: MusicHub) -> MusicAlbum? {
        switch e {
        case .track(let t): return t.album.flatMap { $0.id.isEmpty ? nil : hub.album(from: $0, providerID: t.providerID) }
        case .album(let a): return a
        default: return nil
        }
    }

    static func toggleSave(_ a: MusicAlbum, hub: MusicHub) {
        let was = hub.library.isSaved(a)
        hub.library.toggleSave(a)
        MusicToasts.shared.success(was ? Localized.string("Removed from Your library.") : Localized.string("Saved to Your library."))
    }

    static func toggleFollow(_ a: MusicArtist, hub: MusicHub) {
        let was = hub.library.isFollowing(a)
        hub.library.toggleFollow(a)
        MusicToasts.shared.success(was ? Localized.string("Unfollowed %@.", a.name) : Localized.string("Following %@.", a.name))
    }

    static func toggleLike(_ t: MusicTrack, hub: MusicHub) {
        let was = hub.library.isLiked(t)
        hub.library.toggleLike(t)
        MusicToasts.shared.success(was ? Localized.string("Removed from Liked Songs.") : Localized.string("Added to Liked Songs."))
    }
}

// MARK: - drag and drop of cards and rows

/// What travels in a drag: enough to find the songs again on drop. It never leaves this app.
struct MusicDragPayload: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case track, album, playlist, artist }
    var kind: Kind
    var providerID: String
    var id: String
    var title: String
    var uid: String { providerID + ":" + id }

    init(kind: Kind, providerID: String, id: String, title: String) { self.kind = kind; self.providerID = providerID; self.id = id; self.title = title }
    init(_ e: MusicEntity) {
        switch e {
        case .track(let t): self.init(kind: .track, providerID: t.providerID, id: t.id, title: t.title)
        case .album(let a): self.init(kind: .album, providerID: a.providerID, id: a.id, title: a.title)
        case .playlist(let p): self.init(kind: .playlist, providerID: p.providerID, id: p.id, title: p.name)
        case .artist(let a): self.init(kind: .artist, providerID: a.providerID, id: a.id, title: a.name)
        }
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }
    static func decode(_ data: Data) -> MusicDragPayload? { try? JSONDecoder().decode(MusicDragPayload.self, from: data) }

    /// The item the drag was started from: a bare song, album, playlist or artist carrying only what the payload knows.
    var entity: MusicEntity {
        switch kind {
        case .track: .track(MusicTrack(id: id, providerID: providerID, title: title, durationMs: 0, artists: []))
        case .album: .album(MusicAlbum(id: id, providerID: providerID, title: title))
        case .playlist: .playlist(MusicPlaylist(id: id, providerID: providerID, name: title))
        case .artist: .artist(MusicArtist(id: id, providerID: providerID, name: title))
        }
    }
}

extension MusicEntity {
    /// The drag item for a card or row. It is visible to this app only, so no other app can read what is being moved.
    func dragProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let data = MusicDragPayload(self).encoded() ?? Data()
        provider.registerDataRepresentation(forTypeIdentifier: MusicDragKind.browseItem.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        provider.suggestedName = title
        return provider
    }
}

/// Carries a main-actor closure into the drop callback, which Swift cannot prove runs on the main actor. The closure is only ever called there.
final class MusicDropBox: @unchecked Sendable {
    let run: @MainActor (MusicDragPayload) -> Void
    init(_ run: @escaping @MainActor (MusicDragPayload) -> Void) { self.run = run }
}

private struct MusicEntityDrop: ViewModifier {
    let hub: MusicHub
    let perform: @MainActor ([MusicTrack]) -> Void
    @State private var targeted = false
    @Environment(\.reddyAccent) private var accent

    func body(content: Content) -> some View {
        content
            .onDrop(of: [MusicDragKind.browseItem.contentType], isTargeted: $targeted) { providers in
                guard let p = providers.first else { return false }
                let hub = hub
                let box = MusicDropBox { payload in
                    Task { @MainActor in
                        let list = await MusicEntityActions.tracks(payload.entity, hub: hub)
                        if !list.isEmpty { perform(list) }
                    }
                }
                p.loadDataRepresentation(forTypeIdentifier: MusicDragKind.browseItem.identifier) { data, _ in
                    guard let data, let payload = MusicDragPayload.decode(data) else { return }
                    Task { @MainActor in box.run(payload) }
                }
                return true
            }
            .overlay { if targeted { RoundedRectangle(cornerRadius: MusicTokens.radiusCard, style: .continuous).strokeBorder(accent, lineWidth: 2).allowsHitTesting(false) } }
    }
}

extension View {
    /// Accepts a card or song dragged from anywhere in Music and hands over its songs.
    func musicDropTracks(hub: MusicHub, perform: @escaping @MainActor ([MusicTrack]) -> Void) -> some View { modifier(MusicEntityDrop(hub: hub, perform: perform)) }
}

// MARK: - keyboard modifiers of a click

enum MusicClickModifiers {
    @MainActor static var current: MusicTrackSelection.Click {
        #if os(macOS)
        let f = NSEvent.modifierFlags
        if f.contains(.shift) { return .shift }
        if f.contains(.command) { return .command }
        #endif
        return .plain
    }
}
