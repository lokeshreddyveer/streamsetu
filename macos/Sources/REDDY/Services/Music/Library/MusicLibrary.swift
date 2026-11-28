import Foundation
import Observation

// The person's own music data: likes, playlists, history, follows, saved albums, blacklist and settings.
// Everything stays on this device. Each collection lives in its own JSON file and settings live in a separate file,
// so wiping or restoring one never touches the other.

enum MusicPlaylistSort: Sendable { case manual, name, newest, oldest, size }

struct MusicImportSummary: Equatable, Sendable {
    var likedAdded = 0, playlistsAdded = 0, playlistTracksAdded = 0, historyAdded = 0
    var artistsAdded = 0, albumsAdded = 0, blacklistAdded = 0
}

/// The backup file shape. It leaves out settings on purpose: those hold device specific data such as folder bookmarks.
private struct MusicLibraryBackup: Codable {
    var schemaVersion: Int = 1
    var exportedAt: Date = Date()
    var liked: [MusicTrack] = []
    var playlists: [LocalPlaylist] = []
    var history: [PlayRecord] = []
    var followedArtists: [MusicArtist] = []
    var savedAlbums: [MusicAlbum] = []
    var blacklist: [String] = []

    init() {}
    private enum CodingKeys: String, CodingKey { case schemaVersion, exportedAt, liked, playlists, history, followedArtists, savedAlbums, blacklist }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date()
        liked = try c.decodeIfPresent([MusicTrack].self, forKey: .liked) ?? []
        playlists = try c.decodeIfPresent([LocalPlaylist].self, forKey: .playlists) ?? []
        history = try c.decodeIfPresent([PlayRecord].self, forKey: .history) ?? []
        followedArtists = try c.decodeIfPresent([MusicArtist].self, forKey: .followedArtists) ?? []
        savedAlbums = try c.decodeIfPresent([MusicAlbum].self, forKey: .savedAlbums) ?? []
        blacklist = try c.decodeIfPresent([String].self, forKey: .blacklist) ?? []
    }
}

@MainActor @Observable
final class MusicLibrary {
    /// Stats need the whole listening history, so the list is allowed to grow far past the old cap.
    static let historyLimit = 50_000
    static let recentLimit = 50

    var settings: MusicSettings { didSet { if settings != oldValue { settingsStore.save(settings) } } }
    /// Goes up by one on every change of the collection next to it. An observed array only says that it changed, not whether; a screen asks these instead of
    /// comparing counts, ends or names (and so also sees a reorder in the middle, which count-and-ends cannot).
    private(set) var likedRevision = 0
    private(set) var playlistsRevision = 0
    private(set) var historyRevision = 0
    private(set) var followedRevision = 0
    private(set) var albumsRevision = 0
    private(set) var additionsRevision = 0

    private(set) var liked: [MusicTrack] { didSet { likedStore.save(liked); likedRevision &+= 1 } }
    private(set) var playlists: [LocalPlaylist] { didSet { playlistsStore.save(playlists); playlistsRevision &+= 1 } }
    private(set) var history: [PlayRecord] { didSet { historyStore.save(history); historyRevision &+= 1 } }
    private(set) var followedArtists: [MusicArtist] { didSet { artistsStore.save(followedArtists); followedRevision &+= 1 } }
    private(set) var savedAlbums: [MusicAlbum] { didSet { albumsStore.save(savedAlbums); albumsRevision &+= 1 } }
    private(set) var blacklist: Set<String> { didSet { blacklistStore.save(blacklist.sorted()) } }
    /// When each like, follow and saved album happened ("kind|key" to the time), kept from now on. Older items have no date; none is invented for them.
    private(set) var additions: [String: Date] { didSet { additionsStore.save(additions); additionsRevision &+= 1 } }

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let settingsStore: MusicJSONStore<MusicSettings>
    @ObservationIgnored private let likedStore: MusicJSONStore<[MusicTrack]>
    @ObservationIgnored private let playlistsStore: MusicJSONStore<[LocalPlaylist]>
    @ObservationIgnored private let historyStore: MusicJSONStore<[PlayRecord]>
    @ObservationIgnored private let artistsStore: MusicJSONStore<[MusicArtist]>
    @ObservationIgnored private let albumsStore: MusicJSONStore<[MusicAlbum]>
    @ObservationIgnored private let blacklistStore: MusicJSONStore<[String]>
    @ObservationIgnored private let additionsStore: MusicJSONStore<[String: Date]>
    @ObservationIgnored private let resumeStore: MusicJSONStore<[String: MusicResumePoint]>
    /// Where each long recording was left (song uid to place), so it carries on from there. Kept per recording and pruned by age and count.
    @ObservationIgnored private var resumePoints: [String: MusicResumePoint] { didSet { resumeStore.save(resumePoints) } }
    /// The person's folders for playlists (a separate file, so a library saved before folders existed loads unchanged).
    @ObservationIgnored lazy var playlistFolders = MusicPlaylistFolderBook(directory: directory)
    /// The person's rule-based smart playlists (their own file; only the rules are stored, the songs are worked out when the list is opened).
    @ObservationIgnored lazy var smartRules = MusicSmartRuleBook(directory: directory)

    init(directory: URL, debounce: Duration = .seconds(1)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func file(_ n: String) -> URL { directory.appendingPathComponent(n + ".json") }
        let settingsStore = MusicJSONStore<MusicSettings>(url: file("settings"), debounce: debounce)
        let likedStore = MusicJSONStore<[MusicTrack]>(url: file("liked"), debounce: debounce)
        let playlistsStore = MusicJSONStore<[LocalPlaylist]>(url: file("playlists"), debounce: debounce)
        let historyStore = MusicJSONStore<[PlayRecord]>(url: file("history"), debounce: debounce)
        let artistsStore = MusicJSONStore<[MusicArtist]>(url: file("artists"), debounce: debounce)
        let albumsStore = MusicJSONStore<[MusicAlbum]>(url: file("albums"), debounce: debounce)
        let blacklistStore = MusicJSONStore<[String]>(url: file("blacklist"), debounce: debounce)
        let additionsStore = MusicJSONStore<[String: Date]>(url: file("additions"), debounce: debounce)
        let resumeStore = MusicJSONStore<[String: MusicResumePoint]>(url: file("resume"), debounce: debounce)
        self.settingsStore = settingsStore; self.likedStore = likedStore; self.playlistsStore = playlistsStore
        self.historyStore = historyStore; self.artistsStore = artistsStore; self.albumsStore = albumsStore
        self.blacklistStore = blacklistStore; self.additionsStore = additionsStore; self.resumeStore = resumeStore

        settings = settingsStore.load() ?? MusicSettings()
        liked = Self.dedupe(likedStore.load() ?? [], key: \.uid)
        playlists = Self.cleanPlaylists(playlistsStore.load() ?? [])
        let hist = (historyStore.load() ?? []).sorted { $0.at > $1.at }
        history = Array(hist.prefix(Self.historyLimit))
        followedArtists = Self.dedupe(artistsStore.load() ?? [], key: \.uid)
        savedAlbums = Self.dedupe(albumsStore.load() ?? [], key: \.uid)
        blacklist = Set(blacklistStore.load() ?? [])
        additions = additionsStore.load() ?? [:]
        resumePoints = MusicResumeRules.pruned(resumeStore.load() ?? [:])
    }

    // MARK: Helpers

    /// Keeps the first item for each key, so the original order is stable.
    static func dedupe<T>(_ items: [T], key: (T) -> String) -> [T] {
        var seen = Set<String>()
        return items.filter { seen.insert(key($0)).inserted }
    }

    private static func cleanPlaylists(_ list: [LocalPlaylist]) -> [LocalPlaylist] {
        var seenIDs = Set<UUID>()
        return list.compactMap { p in
            guard seenIDs.insert(p.id).inserted else { return nil }
            var p = p
            p.tracks = dedupe(p.tracks, key: \.uid)
            return p
        }
    }

    private static func cleanName(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled playlist" : t
    }

    /// Same behaviour as the list `onMove` in SwiftUI, without needing SwiftUI.
    private static func moved<T>(_ items: [T], from source: IndexSet, to destination: Int) -> [T] {
        let valid = source.filter { items.indices.contains($0) }
        guard !valid.isEmpty else { return items }
        let moving = valid.map { items[$0] }
        var rest = items
        for i in valid.reversed() { rest.remove(at: i) }
        let shift = valid.filter { $0 < destination }.count
        let target = min(max(destination - shift, 0), rest.count)
        rest.insert(contentsOf: moving, at: target)
        return rest
    }

    // MARK: Resume points

    /// Where to carry on this recording, or nil when it should start from the beginning.
    func resumePosition(for t: MusicTrack, duration: Double, minMinutes: Int = MusicSeekPrefs.resumeMinutes()) -> Double? {
        MusicResumeRules.resumeAt(resumePoints[t.uid], duration: duration, minMinutes: minMinutes)
    }
    func rememberResume(_ t: MusicTrack, position: Double, duration: Double, minMinutes: Int = MusicSeekPrefs.resumeMinutes()) {
        guard MusicResumeRules.shouldRemember(position: position, duration: duration, minMinutes: minMinutes) else { return }
        resumePoints[t.uid] = MusicResumePoint(position: position, duration: duration, savedAt: Date())
    }
    func forgetResume(_ t: MusicTrack) { if resumePoints[t.uid] != nil { resumePoints[t.uid] = nil } }

    // MARK: Likes

    func isLiked(_ t: MusicTrack) -> Bool { liked.contains { $0.uid == t.uid } }

    /// When something was added, if the time was kept.
    func addedAt(_ kind: MusicAdditionKind, _ key: String) -> Date? { additions[MusicRecentlyAdded.storageKey(kind, key)] }
    private func noteAdded(_ kind: MusicAdditionKind, _ key: String) { additions[MusicRecentlyAdded.storageKey(kind, key)] = Date() }
    private func noteRemoved(_ kind: MusicAdditionKind, _ key: String) { additions[MusicRecentlyAdded.storageKey(kind, key)] = nil }

    func toggleLike(_ t: MusicTrack) {
        if let i = liked.firstIndex(where: { $0.uid == t.uid }) { liked.remove(at: i); noteRemoved(.song, t.uid) } else { liked.insert(t, at: 0); noteAdded(.song, t.uid) }
        Task { await MusicRecommenderRuntime.shared.historyChanged() }
    }

    // MARK: Playlists

    func playlist(id: LocalPlaylist.ID) -> LocalPlaylist? { playlists.first { $0.id == id } }

    @discardableResult
    func createPlaylist(name: String, tracks: [MusicTrack] = []) -> LocalPlaylist {
        let p = LocalPlaylist(name: Self.cleanName(name), tracks: Self.dedupe(tracks, key: \.uid))
        playlists.append(p)
        return p
    }

    func rename(_ id: LocalPlaylist.ID, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = Self.cleanName(name)
    }
    func rename(_ p: LocalPlaylist, to name: String) { rename(p.id, to: name) }

    func delete(_ id: LocalPlaylist.ID) { playlists.removeAll { $0.id == id } }
    func delete(_ p: LocalPlaylist) { delete(p.id) }

    /// Adds tracks the playlist does not already hold. Returns how many were added.
    @discardableResult
    func add(_ tracks: [MusicTrack], to id: LocalPlaylist.ID) -> Int {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return 0 }
        var have = Set(playlists[i].tracks.map(\.uid))
        let fresh = tracks.filter { have.insert($0.uid).inserted }
        guard !fresh.isEmpty else { return 0 }
        playlists[i].tracks.append(contentsOf: fresh)
        return fresh.count
    }

    /// Puts a playlist's songs back exactly as they were (Undo of a removal or a reorder).
    func replaceTracks(_ tracks: [MusicTrack], in id: LocalPlaylist.ID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].tracks = tracks
    }

    func remove(at offsets: IndexSet, from id: LocalPlaylist.ID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        var tracks = playlists[i].tracks
        for o in offsets.sorted(by: >) where tracks.indices.contains(o) { tracks.remove(at: o) }
        playlists[i].tracks = tracks
    }

    func move(from source: IndexSet, to destination: Int, in id: LocalPlaylist.ID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].tracks = Self.moved(playlists[i].tracks, from: source, to: destination)
    }

    /// Reorders the playlists list itself (the manual order is the stored order).
    func movePlaylists(from source: IndexSet, to destination: Int) {
        playlists = Self.moved(playlists, from: source, to: destination)
    }

    func sortedPlaylists(_ sort: MusicPlaylistSort) -> [LocalPlaylist] {
        switch sort {
        case .manual: return playlists
        case .name: return playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .newest: return playlists.sorted { $0.created > $1.created }
        case .oldest: return playlists.sorted { $0.created < $1.created }
        case .size: return playlists.sorted { $0.tracks.count > $1.tracks.count }
        }
    }

    // MARK: History

    func recordPlay(_ t: MusicTrack, playedMs: Int64) {
        history.insert(PlayRecord(track: t, at: Date(), playedMs: max(0, playedMs)), at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }

    /// The history in local day buckets (Today, Yesterday, weekdays, Last week, months). Row indices refer to the full history.
    func historyBuckets(filter: String = "", now: Date = Date(), calendar: Calendar = .current) -> [MusicHistoryBucket] {
        MusicHistoryBuckets.filtered(MusicHistoryBuckets.buckets(history, now: now, calendar: calendar), query: filter)
    }

    /// Unique tracks, newest first.
    var recent: [MusicTrack] {
        var seen = Set<String>()
        var out: [MusicTrack] = []
        for r in history where seen.insert(r.track.uid).inserted {
            out.append(r.track)
            if out.count == Self.recentLimit { break }
        }
        return out
    }

    /// Most played first; ties go to the more recently played track.
    /// Home asks for the top tracks on every redraw and the history can hold 50,000 rows: the ranking is kept until the history changes.
    @ObservationIgnored private var topMemo: (count: Int, first: Date?, tracks: [MusicTrack])?
    private static let topMemoSize = 20

    func topTracks(limit: Int = 20) -> [MusicTrack] {
        guard limit > 0 else { return [] }
        if limit <= Self.topMemoSize, let m = topMemo, m.count == history.count, m.first == history.first?.at { return Array(m.tracks.prefix(limit)) }
        var counts: [String: (n: Int, track: MusicTrack, first: Int)] = [:]
        for (i, r) in history.enumerated() {
            if var e = counts[r.track.uid] { e.n += 1; counts[r.track.uid] = e } else { counts[r.track.uid] = (1, r.track, i) }
        }
        let ranked = counts.values.sorted { $0.n != $1.n ? $0.n > $1.n : $0.first < $1.first }
        let top = ranked.prefix(max(limit, Self.topMemoSize)).map(\.track)
        if limit <= Self.topMemoSize { topMemo = (history.count, history.first?.at, top) }
        return Array(top.prefix(limit))
    }

    // MARK: Follows, saved albums

    func isFollowing(_ a: MusicArtist) -> Bool { followedArtists.contains { $0.uid == a.uid } }
    func toggleFollow(_ a: MusicArtist) {
        if let i = followedArtists.firstIndex(where: { $0.uid == a.uid }) { followedArtists.remove(at: i); noteRemoved(.artist, a.uid) } else { followedArtists.insert(a, at: 0); noteAdded(.artist, a.uid) }
    }

    func isSaved(_ a: MusicAlbum) -> Bool { savedAlbums.contains { $0.uid == a.uid } }
    func toggleSave(_ a: MusicAlbum) {
        if let i = savedAlbums.firstIndex(where: { $0.uid == a.uid }) { savedAlbums.remove(at: i); noteRemoved(.album, a.uid) } else { savedAlbums.insert(a, at: 0); noteAdded(.album, a.uid) }
    }

    // MARK: Blacklist (track uid or artist id)

    // An empty id is nobody: a plain-text credit has none, and a blocked "" would match every such artist (and every local file). It is never stored, and one that an
    // earlier version stored is never matched.
    func isBlacklisted(_ t: MusicTrack) -> Bool {
        blacklist.contains(t.uid) || t.artists.contains { !$0.id.isEmpty && blacklist.contains($0.id) }
    }
    func toggleBlacklist(_ t: MusicTrack) { toggleBlacklistKey(t.uid) }

    func isBlacklisted(artist: MusicArtistRef) -> Bool { !artist.id.isEmpty && blacklist.contains(artist.id) }
    func toggleBlacklist(artist: MusicArtistRef) { toggleBlacklistKey(artist.id) }

    private func toggleBlacklistKey(_ key: String) {
        guard !key.isEmpty else { return }
        if blacklist.contains(key) { blacklist.remove(key) } else { blacklist.insert(key) }
    }

    // MARK: Backup

    /// A readable JSON backup of the person's own library. Settings are not included.
    func exportJSON() -> Data {
        var b = MusicLibraryBackup()
        b.liked = liked; b.playlists = playlists; b.history = history
        b.followedArtists = followedArtists; b.savedAlbums = savedAlbums; b.blacklist = blacklist.sorted()
        let enc = MusicJSONCoding.makeEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? enc.encode(b)) ?? Data()
    }

    /// Merges a backup into the library. Nothing already here is removed or replaced.
    @discardableResult
    func importJSON(_ data: Data) throws -> MusicImportSummary {
        let b = try MusicJSONCoding.makeDecoder().decode(MusicLibraryBackup.self, from: data)
        var s = MusicImportSummary()

        let haveLiked = Set(liked.map(\.uid))
        let newLiked = Self.dedupe(b.liked, key: \.uid).filter { !haveLiked.contains($0.uid) }
        if !newLiked.isEmpty { liked.append(contentsOf: newLiked); s.likedAdded = newLiked.count; for t in newLiked { noteAdded(.song, t.uid) } }

        for incoming in Self.cleanPlaylists(b.playlists) {
            if let i = playlists.firstIndex(where: { $0.id == incoming.id }) {
                s.playlistTracksAdded += add(incoming.tracks, to: playlists[i].id)
            } else {
                playlists.append(incoming)
                s.playlistsAdded += 1
                s.playlistTracksAdded += incoming.tracks.count
            }
        }

        var seen = Set(history.map { "\($0.track.uid)|\($0.at.timeIntervalSince1970.rounded())" })
        let newHistory = b.history.filter { seen.insert("\($0.track.uid)|\($0.at.timeIntervalSince1970.rounded())").inserted }
        if !newHistory.isEmpty {
            let merged = (history + newHistory).sorted { $0.at > $1.at }
            history = Array(merged.prefix(Self.historyLimit))
            s.historyAdded = newHistory.count
        }

        let haveArtists = Set(followedArtists.map(\.uid))
        let newArtists = Self.dedupe(b.followedArtists, key: \.uid).filter { !haveArtists.contains($0.uid) }
        if !newArtists.isEmpty { followedArtists.append(contentsOf: newArtists); s.artistsAdded = newArtists.count; for a in newArtists { noteAdded(.artist, a.uid) } }

        let haveAlbums = Set(savedAlbums.map(\.uid))
        let newAlbums = Self.dedupe(b.savedAlbums, key: \.uid).filter { !haveAlbums.contains($0.uid) }
        if !newAlbums.isEmpty { savedAlbums.append(contentsOf: newAlbums); s.albumsAdded = newAlbums.count; for a in newAlbums { noteAdded(.album, a.uid) } }

        let newBlocked = Set(b.blacklist).subtracting(blacklist)
        if !newBlocked.isEmpty { blacklist.formUnion(newBlocked); s.blacklistAdded = newBlocked.count }
        return s
    }

    // MARK: Persistence control

    /// Writes everything queued right now. Used before quitting and by tests.
    func flush() {
        settingsStore.flush(); likedStore.flush(); playlistsStore.flush(); historyStore.flush()
        artistsStore.flush(); albumsStore.flush(); blacklistStore.flush(); additionsStore.flush(); resumeStore.flush()
    }

    /// Privacy wipe: deletes every file and empties memory. `keepSettings` leaves the settings file alone.
    func clearAll(keepSettings: Bool = false) {
        liked = []; playlists = []; history = []; followedArtists = []; savedAlbums = []; blacklist = []
        if !keepSettings { settings = MusicSettings() }
        likedStore.delete(); playlistsStore.delete(); historyStore.delete()
        artistsStore.delete(); albumsStore.delete(); blacklistStore.delete()
        additions = [:]; additionsStore.delete()   // the dates things were added go with them
        if !keepSettings { settingsStore.delete() }
    }
}
