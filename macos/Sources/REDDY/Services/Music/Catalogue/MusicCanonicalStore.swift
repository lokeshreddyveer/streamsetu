import Foundation

/// The song-match cache: one canonical identity per song with the catalogue rows it was seen on and its playable copies. JSON on disk under the
/// Music storage root, entries live 30 days (an unmatched song is asked again after a day), at most 5000 entries, wiped with the privacy wipe.
/// Reads are synchronous so the lyrics query builder and the artwork picker can use it without awaiting.
final class MusicCanonicalStore: @unchecked Sendable {
    static let ttl: TimeInterval = 30 * 24 * 3600
    static let unmatchedTTL: TimeInterval = 24 * 3600
    static let maxEntries = 5_000
    static let fileName = "CanonicalTracks.json"
    /// Two recordings with one ISRC are the same song only when their running times are this close.
    static let isrcWindowMs: Int64 = 10_000

    static let shared = MusicCanonicalStore(file: MusicStorage.root.appendingPathComponent("Catalogue", isDirectory: true).appendingPathComponent(fileName))

    private let lock = NSLock()
    private let file: URL
    private let now: () -> Date
    private var entries: [String: MusicCanonicalTrack] = [:]
    private var byUID: [String: String] = [:]
    private var byISRC: [String: [String]] = [:]
    private var byTwin: [String: String] = [:]
    private var byCover: [String: String] = [:]
    private var loaded = false
    private var dirty = false
    private var saveScheduled = false
    private let io = DispatchQueue(label: "music.catalogue.store", qos: .utility)
    private let writeLock = NSLock()

    init(file: URL, now: @escaping () -> Date = { Date() }) { self.file = file; self.now = now }

    // MARK: reading

    var count: Int { lock.withLock { ensureLoaded(); return entries.count } }

    /// The entry for a catalogue or playable row, by its uid, its recording code, or its title and artist.
    func canonical(for track: MusicTrack) -> MusicCanonicalTrack? {
        lock.withLock {
            ensureLoaded()
            if let k = byUID[track.uid] ?? byTwin[track.uid], let e = fresh(k) { return e }
            if let v = track.videoID, let k = byTwin[track.providerID + ":" + v], let e = fresh(k) { return e }
            let wanted = MusicCatalogCanon.make(from: track)
            if let isrc = wanted.isrc, let e = (byISRC[isrc] ?? []).compactMap({ fresh($0) }).first(where: { sameRecording($0, wanted) }) { return e }
            guard let hit = fresh(wanted.key), Self.sameSong(hit, wanted) else { return nil }
            return hit
        }
    }

    /// Two entries with one title-and-artist key are one song only when their running times agree, and a row with no known artist matches nothing by title alone
    /// (two films can each have a different "Tere Bina" with no singer in the graph).
    static func sameSong(_ a: MusicCanonicalTrack, _ b: MusicCanonicalTrack) -> Bool {
        if a.durationMs > 0, b.durationMs > 0 { return abs(a.durationMs - b.durationMs) <= isrcWindowMs }
        return !a.artists.isEmpty && !b.artists.isEmpty
    }

    /// For the lyrics hook, which only has words and maybe a video id.
    func lookup(title: String, artists: String, videoID: String?, isrc: String?) -> MusicCanonicalTrack? {
        lock.withLock {
            ensureLoaded()
            if let v = videoID {
                for pid in ["youtube-music", "ytmusic", "youtube", "piped", "invidious"] { if let k = byTwin[pid + ":" + v], let e = fresh(k) { return e } }
            }
            if let i = MusicISRC.normalize(isrc), let e = (byISRC[i] ?? []).compactMap({ fresh($0) }).first { return e }
            let names = MusicLyricsQueryBuilder.names(artists)
            let probe = MusicCatalogCanon.key(title: title, artists: names, versionTags: MusicCandidateRules.versionTags(title: title).filter { !$0.hasPrefix("lang:") }.sorted())
            return fresh(probe)
        }
    }

    /// A cover the catalogue gave for a song, found by any picture address the playable copy carried.
    func cover(forThumbnail url: String) -> String? {
        lock.withLock {
            ensureLoaded()
            guard let k = byCover[url], let e = fresh(k) else { return nil }
            return e.coverURL
        }
    }

    /// Entry still inside its lifetime, else nil.
    private func fresh(_ key: String) -> MusicCanonicalTrack? {
        guard let e = entries[key] else { return nil }
        return expired(e) ? nil : e
    }

    private func expired(_ e: MusicCanonicalTrack) -> Bool {
        // A matched copy lives 30 days from the day it was last verified (`checkedAt`), however often it is read; an entry never checked falls back to its last write.
        let since = e.isMatched && e.checkedAt.timeIntervalSince1970 > 0 ? e.checkedAt : e.updatedAt
        let age = now().timeIntervalSince(since)
        return age > (e.isMatched ? Self.ttl : Self.unmatchedTTL)
    }

    // MARK: writing

    /// Adds or merges a song. The same ISRC with a close running time and the same version tags is the same song; otherwise the identity key decides.
    @discardableResult
    func put(_ incoming: MusicCanonicalTrack) -> MusicCanonicalTrack {
        lock.withLock {
            ensureLoaded()
            var merged = incoming
            merged.updatedAt = now()
            var key = incoming.key
            if let isrc = incoming.isrc, let other = (byISRC[isrc] ?? []).compactMap({ entries[$0] }).first(where: { sameRecording($0, incoming) }) { key = other.key }
            if let old = entries[key], key != incoming.key || Self.sameSong(old, incoming) {
                merged.key = key
                merged.seenOn = Array(Set(old.seenOn + incoming.seenOn)).sorted()
                if merged.twins.isEmpty, incoming.checkedAt <= old.checkedAt { merged.twins = old.twins; merged.checkedAt = old.checkedAt }
                merged.coverURL = incoming.coverURL ?? old.coverURL
                merged.isrc = incoming.isrc ?? old.isrc
                merged.film = incoming.film ?? old.film
                merged.year = incoming.year ?? old.year
                unindex(old)
            } else if let stale = entries[key] {
                unindex(stale)   // another song under the same title and artist: its copies must not become this song's
            }
            entries[key] = merged
            index(merged)
            trim()
            markDirty()
            return merged
        }
    }

    func clear() {
        lock.withLock {
            entries = [:]; byUID = [:]; byISRC = [:]; byTwin = [:]; byCover = [:]; loaded = true; dirty = false
        }
        writeLock.withLock { try? FileManager.default.removeItem(at: file) }
    }

    /// Writes pending changes now (the app does this on a timer; tests call it).
    func flush() {
        let data: Data? = lock.withLock {
            guard dirty else { return nil }
            dirty = false
            let list = entries.values.sorted { $0.key < $1.key }
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
            return try? enc.encode(list)
        }
        guard let data else { return }
        writeLock.withLock {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    // MARK: internals (lock held)

    private func sameRecording(_ a: MusicCanonicalTrack, _ b: MusicCanonicalTrack) -> Bool {
        guard a.isrc != nil, a.isrc == b.isrc, a.versionTags == b.versionTags else { return false }
        if a.durationMs > 0, b.durationMs > 0 { return abs(a.durationMs - b.durationMs) <= Self.isrcWindowMs }
        return true
    }

    private func index(_ e: MusicCanonicalTrack) {
        for u in e.seenOn { byUID[u] = e.key }
        if let i = e.isrc { byISRC[i, default: []].removeAll { $0 == e.key }; byISRC[i, default: []].append(e.key) }
        for t in e.twins {
            byTwin[t.uid] = e.key
            for th in t.thumbnails { byCover[th.url] = e.key }
        }
    }

    private func unindex(_ e: MusicCanonicalTrack) {
        for u in e.seenOn where byUID[u] == e.key { byUID[u] = nil }
        if let i = e.isrc { byISRC[i]?.removeAll { $0 == e.key } }
        for t in e.twins {
            if byTwin[t.uid] == e.key { byTwin[t.uid] = nil }
            for th in t.thumbnails where byCover[th.url] == e.key { byCover[th.url] = nil }
        }
    }

    private func trim() {
        for (k, e) in entries where expired(e) { unindex(e); entries[k] = nil }
        guard entries.count > Self.maxEntries else { return }
        let drop = entries.values.sorted { $0.updatedAt < $1.updatedAt }.prefix(entries.count - Self.maxEntries)
        for e in drop { unindex(e); entries[e.key] = nil }
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: file) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        guard let list = try? dec.decode([MusicCanonicalTrack].self, from: data) else {
            try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("bad"))
            return
        }
        for e in list { entries[e.key] = e }
        trim()
        for e in entries.values { index(e) }
    }

    private func markDirty() {
        dirty = true
        guard !saveScheduled else { return }
        saveScheduled = true
        io.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.saveScheduled = false }
            self.flush()
        }
    }
}
