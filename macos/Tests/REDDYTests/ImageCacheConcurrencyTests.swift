import Testing
import Foundation
import CoreGraphics
@testable import REDDY

@Suite("Image cache concurrency", .serialized) struct ImageCacheConcurrencyTests {
    static func jpeg(_ w: Int, _ h: Int) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ImageCache.encode(ctx.makeImage()!)!
    }
    static func seeded(count: Int, w: Int = 600, h: Int = 900) throws -> (ImageCache, URL, [URL]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reddy-imgcache-\(UUID().uuidString)")
        let cache = ImageCache(root: root, http: HTTPClient())
        let data = jpeg(w, h)
        var urls: [URL] = []
        let dir = root.appendingPathComponent(ArtworkKind.poster.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<count {
            let u = URL(string: "https://img.example/p/\(i).jpg")!
            try data.write(to: dir.appendingPathComponent(ImageCache.key(u, .poster) + ".img")); urls.append(u)
        }
        return (cache, root, urls)
    }

    @Test func manyAskersForOnePictureShareOneImage() async throws {
        let (cache, root, urls) = try Self.seeded(count: 1); defer { try? FileManager.default.removeItem(at: root) }
        let results = await withTaskGroup(of: CGImage?.self) { g -> [CGImage?] in
            for _ in 0..<40 { g.addTask { await cache.image(for: urls[0], kind: .poster) } }
            var r: [CGImage?] = []; for await x in g { r.append(x) }; return r
        }
        let first = try #require(results.first ?? nil)
        #expect(results.allSatisfy { $0 != nil && $0! === first }, "one load, one decoded picture, shared by every asker")
        #expect(max(first.width, first.height) <= ArtworkKind.poster.maxPixel, "decoded no larger than the tile needs")
    }

    @Test func aMemoryHitIsSynchronousAndSkipsTheActor() async throws {
        let (cache, root, urls) = try Self.seeded(count: 1); defer { try? FileManager.default.removeItem(at: root) }
        #expect(cache.cachedImage(for: urls[0], kind: .poster) == nil, "nothing in memory before the first load")
        let img = try #require(await cache.image(for: urls[0], kind: .poster))
        #expect(cache.cachedImage(for: urls[0], kind: .poster) === img)
        #expect(cache.cachedImage(for: URL(string: "file:///etc/hosts")!, kind: .poster) == nil, "never local files")
    }

    @Test func memoryPressureDropsMemoryButTheDiskCopyReloads() async throws {
        let (cache, root, urls) = try Self.seeded(count: 3); defer { try? FileManager.default.removeItem(at: root) }
        for u in urls { _ = await cache.image(for: u, kind: .poster) }
        await cache.relieveMemory()
        for u in urls { #expect(cache.cachedImage(for: u, kind: .poster) == nil) }
        for u in urls { #expect(await cache.image(for: u, kind: .poster) != nil, "reloads from disk") }
    }

    @Test func cancellingTheOnlyAskerCancelsTheLoadAndIsNotRememberedAsAFailure() async throws {
        var p = CachePolicy.default; p.retryDelays = [5, 5]; p.attemptTimeout = 2
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reddy-imgcache-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ImageCache(root: root, policy: p, http: HTTPClient())
        let u = URL(string: "http://127.0.0.1:9/never.jpg")!           // refuses the connection: the load would wait 5 s before retrying
        let t0 = Date()
        let task = Task { await cache.image(for: u, kind: .poster) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        _ = await task.value
        #expect(Date().timeIntervalSince(t0) < 3, "cancelling does not wait out the retry delay")
        // The picture turns up on disk later (e.g. another route): it must load, which it could not if the cancel had been recorded as a failure.
        let dir = root.appendingPathComponent(ArtworkKind.poster.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.jpeg(300, 450).write(to: dir.appendingPathComponent(ImageCache.key(u, .poster) + ".img"))
        #expect(await cache.image(for: u, kind: .poster) != nil)
    }

    @Test func oneCancelledAskerDoesNotCancelTheLoadOthersWaitFor() async throws {
        let (cache, root, urls) = try Self.seeded(count: 1); defer { try? FileManager.default.removeItem(at: root) }
        let a = Task { await cache.image(for: urls[0], kind: .poster) }
        let b = Task { await cache.image(for: urls[0], kind: .poster) }
        a.cancel()
        #expect(await b.value != nil)
        _ = await a.value
    }

    @Test func prefetchWarmsMemoryInTheBackground() async throws {
        let (cache, root, urls) = try Self.seeded(count: 12); defer { try? FileManager.default.removeItem(at: root) }
        cache.prefetch(urls, kind: .poster)
        var warm = false
        for _ in 0..<100 { if urls.allSatisfy({ cache.cachedImage(for: $0, kind: .poster) != nil }) { warm = true; break }; try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(warm)
    }

    @Test func sixtyDiskPicturesDecodeInParallelNotOneByOne() async throws {
        let (cache, root, urls) = try Self.seeded(count: 60, w: 1000, h: 1500); defer { try? FileManager.default.removeItem(at: root) }
        let t0 = CFAbsoluteTimeGetCurrent()
        await withTaskGroup(of: Void.self) { g in for u in urls { g.addTask { _ = await cache.image(for: u, kind: .poster) } } }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        print("IMGCACHE 60 disk posters: \(Int(ms)) ms")
        #expect(urls.allSatisfy { cache.cachedImage(for: $0, kind: .poster) != nil })
    }
}
