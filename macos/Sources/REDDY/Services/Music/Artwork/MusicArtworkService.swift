import Foundation
import MediaPlayer

// Music's own cover pipeline, deliberately separate from the app-wide artwork code. One download per address is shared by every size (stored at pixel
// buckets), covers are downsampled while decoding, and a row that scrolls away cancels its request. Every network call goes through MusicHTTP.

/// Which addresses may be fetched, and how an address is normalised first.
enum MusicArtworkPolicy {
    /// A file URL as is; https as is; plain http upgraded to https; everything else (and private-network hosts) refused.
    static func validate(_ address: String) -> URL? {
        guard let u = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = u.scheme?.lowercased() else { return nil }
        if scheme == "file" { return u.isFileURL ? u : nil }
        guard scheme == "https" || scheme == "http", let host = u.host, !host.isEmpty, !MusicNetworkPolicy.isPrivateHost(host) else { return nil }
        guard scheme == "http" else { return u }
        var c = URLComponents(url: u, resolvingAgainstBaseURL: false)
        c?.scheme = "https"
        if c?.port == 80 { c?.port = nil }
        return c?.url
    }

}

/// Owns the caches and the network. Everything that mutates lives here; views reach it through the main-actor facade.
actor MusicArtworkStore {
    /// How much disk the picture cache may hold before the oldest pictures go.
    nonisolated static let defaultDiskCap = 200 * 1024 * 1024
    /// How long a failed address is not asked again: short, so a transient failure is not permanent (the cover view retries after it).
    static let failureTTL: TimeInterval = 30
    struct Key: Hashable, Sendable { let url: String; let bucket: Int }
    private struct Flight { let id: UUID; var waiters: Int; let task: Task<MusicDecodedImage?, Never> }

    nonisolated let memory: MusicArtworkMemory
    private var disk: MusicArtworkDisk
    private let http: MusicHTTP
    private let now: @Sendable () -> Date
    private let timeout: TimeInterval
    private let maxDownload: Int
    private let negativeTTL: TimeInterval
    private var flights: [Key: Flight] = [:]
    private var failures: [String: Date] = [:]

    init(directory: URL, http: MusicHTTP = MusicHTTP(), diskCapBytes: Int = MusicArtworkStore.defaultDiskCap, memoryCostLimit: Int = 64 * 1024 * 1024,
         timeout: TimeInterval = 15, maxDownloadBytes: Int = 10 * 1024 * 1024, negativeTTL: TimeInterval = MusicArtworkStore.failureTTL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.memory = MusicArtworkMemory(costLimit: memoryCostLimit)
        self.disk = MusicArtworkDisk(directory: directory, capBytes: diskCapBytes, now: now)
        self.http = http; self.now = now; self.timeout = timeout; self.maxDownload = maxDownloadBytes; self.negativeTTL = negativeTTL
    }

    /// The cover at the bucket for `pixels`, or nil when it is refused, missing, too big or undecodable. Concurrent calls for the same cover share one request.
    func load(_ address: String, targetPixelSize pixels: Int) async -> MusicDecodedImage? {
        guard let url = MusicArtworkPolicy.validate(address) else { return nil }
        let key = Key(url: url.absoluteString, bucket: MusicArtworkBuckets.bucket(forPixels: pixels))
        if let hit = memory.image(url: key.url, bucket: key.bucket) { return hit }
        if let until = failures[key.url] {
            if until > now() { return nil }
            failures[key.url] = nil
        }
        let flight: Flight
        if var f = flights[key] {
            f.waiters += 1; flights[key] = f; flight = f
        } else {
            let id = UUID()
            let task = Task { [self] () -> MusicDecodedImage? in
                let r = await run(key, url: url)
                finish(key, id: id)
                return r
            }
            flight = Flight(id: id, waiters: 1, task: task)
            flights[key] = flight
        }
        return await withTaskCancellationHandler {
            await flight.task.value
        } onCancel: {
            Task { await self.release(key, id: flight.id) }
        }
    }

    private func release(_ key: Key, id: UUID) {
        guard var f = flights[key], f.id == id else { return }
        f.waiters -= 1
        if f.waiters <= 0 { f.task.cancel(); flights[key] = nil } else { flights[key] = f }
    }

    private func finish(_ key: Key, id: UUID) {
        if flights[key]?.id == id { flights[key] = nil }
    }

    private func run(_ key: Key, url: URL) async -> MusicDecodedImage? {
        let name = MusicArtworkBuckets.fileName(url: key.url, bucket: key.bucket)
        if !url.isFileURL, let stored = disk.read(name), let img = await MusicArtworkCodec.decode(stored, maxPixel: key.bucket) {
            memory.insert(img, url: key.url, bucket: key.bucket)
            return img
        }
        do {
            let data = url.isFileURL ? try readFile(url) : try await download(url)
            try Task.checkCancellation()
            // The video host answers a missing size with a grey 120 x 90 picture that loads without an error: that is a miss, not a cover.
            if MusicArtworkPlaceholder.isMissing(address: key.url, data: data) { throw MusicArtworkError.undecodable }
            guard let img = await MusicArtworkCodec.decode(data, maxPixel: key.bucket) else { throw MusicArtworkError.undecodable }
            try Task.checkCancellation()
            memory.insert(img, url: key.url, bucket: key.bucket)
            if !url.isFileURL, let encoded = MusicArtworkCodec.encode(img.cg) { disk.write(encoded, name: name) }
            return img
        } catch {
            if !Task.isCancelled && !(error is CancellationError) { failures[key.url] = now().addingTimeInterval(negativeTTL) }
            return nil
        }
    }

    private func readFile(_ url: URL) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maxDownload else { throw MusicArtworkError.tooLarge }
        return try Data(contentsOf: url)
    }

    private func download(_ url: URL) async throws -> Data {
        let http = self.http, limit = maxDownload, seconds = timeout
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let d = try await http.get(url)
                guard d.count <= limit else { throw MusicArtworkError.tooLarge }
                return d
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MusicArtworkError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw MusicArtworkError.timeout }
            return first
        }
    }

    func bytesUsed() -> Int { disk.bytesUsed() }

    func failureIsCached(_ address: String) -> Bool {
        guard let u = MusicArtworkPolicy.validate(address), let until = failures[u.absoluteString] else { return false }
        return until > now()
    }

    /// Privacy wipe: memory, disk and remembered failures. Requests already in flight finish but are not special-cased.
    func clear() {
        memory.removeAll(); disk.clear(); failures.removeAll()
    }
}

enum MusicArtworkError: Error { case tooLarge, timeout, undecodable }

/// What views and the player talk to.
@MainActor
final class MusicArtworkService {
    static let shared = MusicArtworkService(store: MusicArtworkStore(directory: MusicArtworkService.defaultDirectory))

    nonisolated static var defaultDirectory: URL { MusicStorage.subfolder("Artwork") }

    let store: MusicArtworkStore
    private var prefetchTask: Task<Void, Never>?
    private let pressure: MusicArtworkMemoryPressure

    init(store: MusicArtworkStore) { self.store = store; self.pressure = MusicArtworkMemoryPressure(memory: store.memory) }

    /// The cover for `address` at about `targetPixelSize` pixels on the long side (rounded up to a bucket). Nil means "show nothing".
    func load(_ address: String?, targetPixelSize: Int) async -> MusicDecodedImage? {
        guard let address else { return nil }
        return await store.load(address, targetPixelSize: targetPixelSize)
    }

    /// A memory-cache hit with no waiting, so a cover that was already shown appears on the first frame.
    func cachedImage(_ address: String?, targetPixelSize: Int) -> MusicDecodedImage? {
        guard let address, let u = MusicArtworkPolicy.validate(address) else { return nil }
        return store.memory.image(url: u.absoluteString, bucket: MusicArtworkBuckets.bucket(forPixels: targetPixelSize))
    }

    /// Warms the next few covers one after another (a newer call replaces an older one), at low priority.
    func prefetch(_ addresses: [String], targetPixelSize: Int = 256) {
        prefetchTask?.cancel()
        let list = Array(addresses.prefix(MusicArtworkPrefetcher.maxWindow))
        guard !list.isEmpty else { return }
        let store = self.store
        prefetchTask = Task(priority: .utility) {
            for a in list {
                if Task.isCancelled { return }
                _ = await store.load(a, targetPixelSize: targetPixelSize)
            }
        }
    }

    func clear() async { prefetchTask?.cancel(); MusicArtworkPrefetcher.shared.cancelAll(); await store.clear() }

    /// The disk the picture cache holds now.
    func diskBytes() async -> Int { await store.bytesUsed() }
    var bytesUsed: Int { get async { await store.bytesUsed() } }

    /// The smallest thumbnail that has at least `neededPixels` on its width, else the largest. Thumbnails with no stated width are used only when nothing states one.
    nonisolated static func pickThumbnail(_ thumbs: [MusicThumbnail], neededPixels: Int) -> String? {
        if let better = MusicCatalogArtwork.upgrade(thumbs, neededPixels: neededPixels) { return better }
        let known = thumbs.filter { $0.width > 0 }.sorted { $0.width < $1.width }
        if let fit = known.first(where: { $0.width >= neededPixels }) ?? known.last { return fit.url }
        return thumbs.last?.url
    }

    // MARK: Now Playing

    /// The cover for the lock screen / Control Center, at 512 px.
    func nowPlayingImage(for thumbs: [MusicThumbnail]) async -> MusicPlatformImage? {
        guard let a = Self.pickThumbnail(thumbs, neededPixels: 512), let img = await load(a, targetPixelSize: 512) else { return nil }
        return img.platformImage()
    }

    /// Same image wrapped for `MPNowPlayingInfoCenter`.
    func nowPlayingArtwork(for thumbs: [MusicThumbnail]) async -> MPMediaItemArtwork? {
        guard let image = await nowPlayingImage(for: thumbs) else { return nil }
        final class Holder: @unchecked Sendable { let image: MusicPlatformImage; init(_ i: MusicPlatformImage) { image = i } }
        let holder = Holder(image)
        return MPMediaItemArtwork(boundsSize: image.size) { _ in holder.image }
    }
}
