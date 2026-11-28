import Foundation
import CryptoKit

/// The pixel sizes covers are stored at, so one download serves every row and card that needs "about this big".
enum MusicArtworkBuckets {
    static let sizes = [64, 128, 256, 512, 1024]

    /// The smallest bucket that holds `pixels`, or the largest one.
    static func bucket(forPixels pixels: Int) -> Int {
        sizes.first { $0 >= pixels } ?? sizes[sizes.count - 1]
    }

    /// The file name for a cover at a bucket: a hash of the address, so no cover address appears on disk.
    static func fileName(url: String, bucket: Int) -> String {
        return MusicHash.sha256(url) + "-\(bucket)"
    }
}

/// Decoded covers in memory, bounded by bitmap bytes. NSCache is thread-safe, so the view layer may look here without hopping actors.
final class MusicArtworkMemory: @unchecked Sendable {
    private final class Box { let image: MusicDecodedImage; init(_ i: MusicDecodedImage) { image = i } }
    private let cache = NSCache<NSString, Box>()

    init(costLimit: Int = 64 * 1024 * 1024) { cache.totalCostLimit = costLimit }

    static func key(url: String, bucket: Int) -> NSString { "\(bucket)|\(url)" as NSString }

    func image(url: String, bucket: Int) -> MusicDecodedImage? { cache.object(forKey: Self.key(url: url, bucket: bucket))?.image }
    func insert(_ image: MusicDecodedImage, url: String, bucket: Int) {
        cache.setObject(Box(image), forKey: Self.key(url: url, bucket: bucket), cost: image.cost)
    }
    func removeAll() { cache.removeAllObjects() }
}

/// Encoded covers on disk. Least recently used files go first once the folder is over its cap; "used" is the file's modification date, bumped on every read.
/// Not thread-safe by itself: the store actor is its only user.
struct MusicArtworkDisk {
    let directory: URL
    let capBytes: Int
    let now: @Sendable () -> Date
    private var total: Int?

    init(directory: URL, capBytes: Int = 200 * 1024 * 1024, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory; self.capBytes = capBytes; self.now = now
    }

    private struct Entry { let url: URL; let size: Int; let used: Date }

    private func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            return Entry(url: u, size: v.fileSize ?? 0, used: v.contentModificationDate ?? .distantPast)
        }
    }

    /// Total bytes in the folder.
    mutating func bytesUsed() -> Int {
        if let total { return total }
        let t = entries().reduce(0) { $0 + $1.size }
        total = t
        return t
    }

    mutating func read(_ name: String) -> Data? {
        let u = directory.appendingPathComponent(name)
        guard let d = try? Data(contentsOf: u) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: u.path)
        return d
    }

    func contains(_ name: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) }

    mutating func write(_ data: Data, name: String) {
        guard data.count <= capBytes else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let u = directory.appendingPathComponent(name)
        let old = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        _ = bytesUsed()
        do { try data.write(to: u, options: .atomic) } catch { return }
        try? fm.setAttributes([.modificationDate: now()], ofItemAtPath: u.path)
        total = (total ?? 0) - old + data.count
        trim()
    }

    /// Removes the least recently used files until the folder fits the cap.
    mutating func trim() {
        guard (total ?? bytesUsed()) > capBytes else { return }
        var size = 0
        let all = entries().sorted { $0.used < $1.used }
        size = all.reduce(0) { $0 + $1.size }
        for e in all where size > capBytes {
            try? FileManager.default.removeItem(at: e.url)
            size -= e.size
        }
        total = size
    }

    mutating func clear() {
        try? FileManager.default.removeItem(at: directory)
        total = 0
    }
}
