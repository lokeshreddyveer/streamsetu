import Foundation
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

/// Memory + disk image cache. Images are validated, downsampled to the size the UI actually needs, stored on disk,
/// and de-duplicated while in flight. Failures are remembered briefly so a dead logo URL is not retried per scroll.
actor ImageCache {
    private let policy: CachePolicy
    private let http: HTTPClient
    private let root: URL
    private let memory = NSCache<NSString, CGImageBox>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private var failures: [String: Date] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var writesSinceTrim = 0

    final class CGImageBox { let image: CGImage; init(_ i: CGImage) { image = i } }

    init(root: URL, policy: CachePolicy = .default, http: HTTPClient) {
        self.root = root; self.policy = policy; self.http = http
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
            await acquire(); defer { Task { release() } }
            guard !Task.isCancelled, let img = await download(url, kind: kind, key: key) else { fail(key); return nil }
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

    func trimDisk() { CacheCleaner(root: root, limit: policy.diskLimitBytes).trim() }

    // MARK: internals

    private func fail(_ key: String) { failures[key] = Date() }

    private func store(_ img: CGImage, key: String) {
        memory.setObject(CGImageBox(img), forKey: key as NSString, cost: img.bytesPerRow * img.height)
    }

    private func acquire() async {
        if running < policy.maxConcurrentDownloads { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if let w = waiters.first { waiters.removeFirst(); w.resume() } else { running -= 1 }
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

    private func download(_ url: URL, kind: ArtworkKind, key: String) async -> CGImage? {
        do {
            let data = try await http.data(http.builder.get(url), maxBytes: http.config.maxImageBytes)
            guard let img = Self.decode(data, maxPixel: kind.maxPixel, policy: policy) else { return nil }
            if let encoded = Self.encode(img) { try? encoded.write(to: fileURL(key, kind), options: .atomic) }
            writesSinceTrim += 1
            if writesSinceTrim >= 200 { writesSinceTrim = 0; trimDisk() }
            return img
        } catch { return nil }
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
