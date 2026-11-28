import Foundation
import Network

/// The person's choices for animated artwork. Everything that can fetch is off until they switch it on.
enum MusicMotionPrefs {
    static let motionKey = "music.motionArtwork"
    static let cellularKey = "music.motionArtwork.cellular"
    static let coverMotionKey = "music.coverMotion"

    static func isOn(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: motionKey) as? Bool ?? false }
    static func overCellular(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: cellularKey) as? Bool ?? false }
    /// The zero-network slow drift on a cover. It only ever runs while a song plays on screen.
    static func coverMotionOn(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: coverMotionKey) as? Bool ?? true }

    /// A looping clip is read again on every loop of a long song, so on a metered connection it needs its own yes.
    static func mayFetch(enabled: Bool, metered: Bool, cellularAllowed: Bool) -> Bool { enabled && (!metered || cellularAllowed) }

    static func allowedNow() -> Bool { mayFetch(enabled: isOn(), metered: MusicMotionLink.shared.isMetered, cellularAllowed: overCellular()) }
}

/// Whether the connection is metered (mobile data or a hotspot). The system tells it when that changes.
final class MusicMotionLink: @unchecked Sendable {
    static let shared = MusicMotionLink()
    private let lock = NSLock()
    private var metered = false
    private var monitor: NWPathMonitor?

    var isMetered: Bool {
        lock.lock(); defer { lock.unlock() }
        if monitor == nil {
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                self.lock.lock(); self.metered = path.isExpensive; self.lock.unlock()
            }
            m.start(queue: DispatchQueue(label: "app.streamsetu.music.motionlink", qos: .utility))
            monitor = m
        }
        return metered
    }
}

/// Finds and keeps the looping clip for what is playing. Nothing is fetched unless the switch is on. One lookup runs at a time, so a quick run of
/// skips answers from the memory the first one filled.
actor MusicMotionArtworkService {
    static let shared = MusicMotionArtworkService()

    private let providers: [any MusicMotionArtworkProvider]
    private let clips: MusicMotionClipCache
    private let loader: MusicMotionClipLoader
    private let allowed: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private var answers = MusicMotionAnswerCache()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(providers: [any MusicMotionArtworkProvider] = [AppleMotionArtworkProvider()],
         clips: MusicMotionClipCache = MusicMotionClipCache(),
         loader: MusicMotionClipLoader = MusicMotionClipLoader(),
         allowed: @escaping @Sendable () -> Bool = { MusicMotionPrefs.allowedNow() },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.providers = providers; self.clips = clips; self.loader = loader; self.allowed = allowed; self.now = now
    }

    /// What each source sends, for the settings page.
    nonisolated var sourceInfo: [MusicProviderInfo] { providers.map(\.info) }

    func cachedAnswerCount() -> Int { answers.count }

    func clearMemory() { answers.clear() }

    /// The clip found for the query, without downloading it.
    func clip(for query: MusicMotionQuery) async -> MusicMotionClip? {
        guard allowed() else { return nil }
        await acquire()
        defer { release() }
        guard allowed(), !Task.isCancelled else { return nil }
        let key = query.cacheKey
        switch answers.lookup(key, now: now(), knowsAlbum: query.knowsAlbum) {
        case .hit(let clip): return clip
        case .miss: return nil
        case .unknown: break
        }
        var found: MusicMotionClip?
        var failed = false
        for p in providers {
            guard allowed(), !Task.isCancelled else { return nil }
            do {
                if let c = try await p.clip(for: query), query.catalogAlbumID != nil || MusicMotionMatch.matches(c, query: query) { found = c; break }
            } catch is CancellationError { return nil } catch { failed = true }
        }
        // A failure to reach a source is not an answer: only a clean "nothing found" is remembered.
        if found != nil || !failed { answers.store(found, key: key, now: now(), knowsAlbum: query.knowsAlbum) }
        return found
    }

    /// The clip as a file on disk, fetched once and then reused for every loop and every later play. Tries the second rendition once.
    func file(for query: MusicMotionQuery) async -> URL? {
        guard let clip = await clip(for: query) else { return nil }
        for url in [clip.masterURL, clip.fallbackURL].compactMap({ $0 }) {
            guard allowed(), !Task.isCancelled else { return nil }
            if let saved = clips.existing(forKey: url.absoluteString, now: now()) { return saved }
            do {
                let data = try await loader.data(for: url)
                guard allowed(), !Task.isCancelled else { return nil }
                if let saved = clips.store(data, forKey: url.absoluteString, now: now()) { return saved }
            } catch is CancellationError { return nil } catch { continue }
        }
        return nil
    }

    func clearDisk() { clips.clear() }
    nonisolated func diskBytes() -> Int { clips.totalBytes }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}
