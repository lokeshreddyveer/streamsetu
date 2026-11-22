import Foundation
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

/// Memory + disk image cache. Images are validated, downsampled to the size the UI actually needs, stored on disk,
/// and de-duplicated while in flight. Failures are remembered briefly so a dead logo URL is not retried per scroll.
actor ImageCache {
    private let policy: CachePolicy
    private let http: HTTPClient
    private let headers: @Sendable (URL) -> [String: String]
    private let root: URL
    private let memory = NSCache<NSString, CGImageBox>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private var failures: [String: Date] = [:]
    private var running = 0
    private var waiters: [(host: String, continuation: CheckedContinuation<Void, Never>)] = []
    private var perHost: [String: Int] = [:]
    private var writesSinceTrim = 0

    final class CGImageBox { let image: CGImage; init(_ i: CGImage) { image = i } }

    init(root: URL, policy: CachePolicy = .default, http: HTTPClient, headers: @escaping @Sendable (URL) -> [String: String] = { _ in [:] }) {
        self.root = root; self.policy = policy; self.http = http; self.headers = headers
        memory.totalCostLimit = policy.memoryLimitBytes
        StorageService.ensure(root)
    }

    func image(for url: URL, kind: ArtworkKind) async -> CGImage? {
        guard url.scheme == "http" || url.scheme == "https" else { return nil }      // never local files via remote metadata
        let key = Self.key(url, kind)
        if let hit = memory.object(forKey: key as NSString) { return hit.image }
        if let t = failures[key], Date().timeIntervalSince(t) < policy.failureBackoff { return nil }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<CGImage?, Never> { [self] in
            if let disk = loadFromDisk(key: key, kind: kind) { store(disk, key: key); return disk }
            // One layer of retrying, here: each attempt takes a slot only while it runs (never while it waits to try again), and the client itself does not retry on top of it.
            let host = url.host?.lowercased() ?? ""
            var found: CGImage?
            attempts: for attempt in 0...policy.retryDelays.count {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(policy.retryDelays[attempt - 1] * 1_000_000_000))
                    if Task.isCancelled { break }
                }
                await acquire(host: host)
                let outcome = await downloadOnce(url, kind: kind, key: key)
                release(host: host)
                switch outcome {
                case .image(let i): found = i; break attempts
                case .permanent: break attempts
                case .transient: continue
                }
            }
            guard !Task.isCancelled, let img = found else { fail(key); return nil }
            store(img, key: key)
            return img
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    func clear() {
        memory.removeAllObjects()
        CacheCleaner(root: root, limit: 0).clearAll()
    }

    /// Under memory pressure: drop the pictures held in memory (they reload from disk when needed) and forget remembered failures.
    func relieveMemory() { memory.removeAllObjects(); failures.removeAll() }

    /// Removes the pictures for these addresses from memory and from disk (every kind: poster, backdrop, logo, still), and forgets any download under way for them.
    /// The file name is derived from the address, so nothing has to be scanned. Returns how many files were deleted.
    @discardableResult
    func evict(urls: [String]) -> Int {
        var deleted = 0
        for s in urls {
            guard let url = URL(string: s) else { continue }
            for kind in ArtworkKind.allCases {
                let key = Self.key(url, kind)
                memory.removeObject(forKey: key as NSString)
                failures[key] = nil
                inFlight[key]?.cancel(); inFlight[key] = nil
                let file = root.appendingPathComponent(kind.rawValue, isDirectory: true).appendingPathComponent(key + ".img")
                if (try? FileManager.default.removeItem(at: file)) != nil { deleted += 1 }
            }
        }
        return deleted
    }

    /// Whether a picture for this address is held in memory or on disk (for tests and the privacy sweep).
    func holds(_ url: URL, kind: ArtworkKind) -> Bool {
        let key = Self.key(url, kind)
        if memory.object(forKey: key as NSString) != nil { return true }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(kind.rawValue, isDirectory: true).appendingPathComponent(key + ".img").path)
    }

    func trimDisk() { CacheCleaner(root: root, limit: policy.diskLimitBytes).trim() }

    // MARK: internals

    private func fail(_ key: String) { failures[key] = Date() }

    private func store(_ img: CGImage, key: String) {
        memory.setObject(CGImageBox(img), forKey: key as NSString, cost: img.bytesPerRow * img.height)
    }

    private func canRun(_ host: String) -> Bool { running < policy.maxConcurrentDownloads && perHost[host, default: 0] < policy.maxPerHost }

    func acquire(host: String) async {
        if canRun(host) { running += 1; perHost[host, default: 0] += 1; return }
        await withCheckedContinuation { waiters.append((host, $0)) }
    }

    func release(host: String) {
        running -= 1
        perHost[host, default: 0] -= 1
        var i = 0
        while i < waiters.count {
            let w = waiters[i]
            if canRun(w.host) { waiters.remove(at: i); running += 1; perHost[w.host, default: 0] += 1; w.continuation.resume() } else { i += 1 }
        }
    }

    nonisolated static func key(_ url: URL, _ kind: ArtworkKind) -> String {
        SHA256.hash(data: Data("\(kind.rawValue)|\(url.absoluteString)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(_ key: String, _ kind: ArtworkKind) -> URL {
        StorageService.ensure(root.appendingPathComponent(kind.rawValue, isDirectory: true)).appendingPathComponent(key + ".img")
    }

    private func loadFromDisk(key: String, kind: ArtworkKind) -> CGImage? {
        let f = fileURL(key, kind)
        guard let data = try? Data(contentsOf: f, options: .mappedIfSafe), let img = Self.decode(data, maxPixel: kind.maxPixel, policy: policy) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)     // LRU touch
        return img
    }

    private enum Outcome { case image(CGImage), permanent, transient }

    private func downloadOnce(_ url: URL, kind: ArtworkKind, key: String) async -> Outcome {
        do {
            var request = http.builder.get(url)
            request.timeoutInterval = policy.attemptTimeout
            for (name, value) in headers(url) { request.setValue(value, forHTTPHeaderField: name) }
            let data = try await http.data(request, maxBytes: http.config.maxImageBytes, retry: .none)
            guard let img = Self.decode(data, maxPixel: kind.maxPixel, policy: policy) else { return .permanent }          // not an image: no point asking again
            if let encoded = Self.encode(img) { try? encoded.write(to: fileURL(key, kind), options: .atomic) }
            writesSinceTrim += 1
            if writesSinceTrim >= 200 { writesSinceTrim = 0; trimDisk() }
            return .image(img)
        } catch {
            return Self.isPermanent(error) ? .permanent : .transient
        }
    }

    /// A failure that asking again cannot fix: the picture is not there, or the address is refused.
    nonisolated static func isPermanent(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let e = error as? NetworkError else { return false }
        switch e {
        case .http(let status, _): return (400..<500).contains(status) && status != 408 && status != 429
        case .invalidURL, .tooLarge, .cancelled, .unreadable: return true
        default: return false
        }
    }

    /// Validates and downsamples in one step; never decodes more pixels than needed.
    static func decode(_ data: Data, maxPixel: Int, policy: CachePolicy = .default) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0, CGImageSourceGetStatus(src) == .statusComplete,
              let type = CGImageSourceGetType(src), UTType(type as String)?.conforms(to: .image) == true,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w * h <= policy.maxPixels else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel, kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func encode(_ img: CGImage) -> Data? {
        let alpha: Bool = { switch img.alphaInfo { case .none, .noneSkipFirst, .noneSkipLast: false; default: true } }()
        let type = alpha ? UTType.png : UTType.jpeg
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
