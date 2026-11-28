import Foundation
import os

/// The last composed feed, kept on disk so Listen Now paints at once on the next launch and recomposes quietly behind it. It lives in Caches (not
/// backed up, rebuildable, removed by the privacy wipe). Only what the feed itself holds is written: items the person already has or public items.
enum HomeFeedCache {
    // 2: Listen Now no longer holds chart or setup shelves. 3: playlist cards carry the artist they were found for, and no "Latin script" shelf.
    // Older files are not read.
    static let version = 3
    static let maxAge: TimeInterval = 14 * 86_400

    static var folder: URL { MusicStorage.caches.appendingPathComponent("ListenNow", isDirectory: true) }
    static func file(in folder: URL = HomeFeedCache.folder) -> URL { folder.appendingPathComponent("feed-v\(version).json") }

    /// Counts privacy wipes. A save remembers the count it was asked under and writes nothing if a wipe happened since: a feed finished just before "Delete everything"
    /// would otherwise be written after the wipe and come back at the next launch.
    private static let wipes = OSAllocatedUnfairLock(initialState: 0)
    static var wipeEpoch: Int { wipes.withLock { $0 } }
    /// Said at the moment of a wipe, before the files are removed (that happens a little later, off the main thread): saves asked earlier now write nothing.
    static func noteWipe() { wipes.withLock { $0 += 1 } }
    /// Saves and clears take turns: one at a time.
    private static let turn = NSLock()

    static func save(_ feed: HomeFeed, in folder: URL = HomeFeedCache.folder, ifEpoch epoch: Int? = nil) {
        guard feed.composedAt > .distantPast else { return }
        turn.lock(); defer { turn.unlock() }
        if let epoch, epoch != wipeEpoch { return }
        MusicStorage.ensureUnbacked(folder)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(feed) else { return }
        try? data.write(to: file(in: folder), options: .atomic)
    }

    /// The saved feed, or nil when there is none, it cannot be read, or it is older than two weeks.
    static func load(in folder: URL = HomeFeedCache.folder, now: Date = Date()) -> HomeFeed? {
        guard let data = try? Data(contentsOf: file(in: folder)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let feed = try? dec.decode(HomeFeed.self, from: data) else { return nil }
        let age = now.timeIntervalSince(feed.composedAt)
        return age >= 0 && age <= maxAge ? feed : nil
    }

    static func clear(in folder: URL = HomeFeedCache.folder) {
        wipes.withLock { $0 += 1 }
        turn.lock(); defer { turn.unlock() }
        try? FileManager.default.removeItem(at: folder)
    }
}
