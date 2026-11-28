import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import REDDY

private func makePNG(width: Int, height: Int) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.3, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

private final class StubTransport: MusicHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _hits = 0
    let body: Data; let status: Int; let delayMs: UInt64
    init(body: Data, status: Int = 200, delayMs: UInt64 = 0) { self.body = body; self.status = status; self.delayMs = delayMs }
    var hits: Int { lock.withLock { _hits } }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _hits += 1 }
        if delayMs > 0 { try await Task.sleep(nanoseconds: delayMs * 1_000_000) }
        let r = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, r)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var t: Date
    init(_ t: Date = Date(timeIntervalSince1970: 1_000_000)) { self.t = t }
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("music-art-test-\(UUID().uuidString)", isDirectory: true)
}

@Suite struct ArtworkServiceTests {
    @Test func bucketChoice() {
        #expect(MusicArtworkBuckets.bucket(forPixels: 1) == 64)
        #expect(MusicArtworkBuckets.bucket(forPixels: 64) == 64)
        #expect(MusicArtworkBuckets.bucket(forPixels: 65) == 128)
        #expect(MusicArtworkBuckets.bucket(forPixels: 300) == 512)
        #expect(MusicArtworkBuckets.bucket(forPixels: 5000) == 1024)
        #expect(MusicArtworkBuckets.fileName(url: "https://a/b.jpg", bucket: 128).hasSuffix("-128"))
        #expect(!MusicArtworkBuckets.fileName(url: "https://a/b.jpg", bucket: 128).contains("a/b"))
    }

    @Test func thumbnailPick() {
        let t = [MusicThumbnail(url: "big", width: 640), MusicThumbnail(url: "small", width: 60), MusicThumbnail(url: "mid", width: 300)]
        #expect(MusicArtworkService.pickThumbnail(t, neededPixels: 100) == "mid")
        #expect(MusicArtworkService.pickThumbnail(t, neededPixels: 50) == "small")
        #expect(MusicArtworkService.pickThumbnail(t, neededPixels: 2000) == "big")
        #expect(MusicArtworkService.pickThumbnail([MusicThumbnail(url: "x")], neededPixels: 100) == "x")
        #expect(MusicArtworkService.pickThumbnail([], neededPixels: 100) == nil)
    }

    @Test func schemeRejection() {
        #expect(MusicArtworkPolicy.validate("https://example.com/a.jpg") != nil)
        #expect(MusicArtworkPolicy.validate("http://example.com/a.jpg")?.scheme == "https")
        #expect(MusicArtworkPolicy.validate("file:///tmp/a.jpg") != nil)
        #expect(MusicArtworkPolicy.validate("ftp://example.com/a.jpg") == nil)
        #expect(MusicArtworkPolicy.validate("data:image/png;base64,AAAA") == nil)
        #expect(MusicArtworkPolicy.validate("http://192.168.1.5/a.jpg") == nil)
        #expect(MusicArtworkPolicy.validate("https://localhost/a.jpg") == nil)
        #expect(MusicArtworkPolicy.validate("http://10.0.0.2/a.jpg") == nil)
        #expect(MusicArtworkPolicy.validate("http://172.20.1.1/a.jpg") == nil)
        #expect(MusicArtworkPolicy.validate("http://172.40.1.1/a.jpg") != nil)
        #expect(MusicArtworkPolicy.validate("not a url") == nil)
    }

    @Test func downsampleDimensions() {
        let png = makePNG(width: 800, height: 400)
        let small = MusicArtworkCodec.downsample(png, maxPixel: 128)
        #expect(small?.width == 128)
        #expect(small?.height == 64)
        let tiny = makePNG(width: 40, height: 40)
        #expect(MusicArtworkCodec.downsample(tiny, maxPixel: 256)?.width == 40)
        #expect(MusicArtworkCodec.downsample(Data([1, 2, 3]), maxPixel: 64) == nil)
    }

    @Test func diskLRUEviction() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        var disk = MusicArtworkDisk(directory: dir, capBytes: 250, now: { clock.now })
        let blob = Data(repeating: 7, count: 100)
        disk.write(blob, name: "a"); clock.advance(1)
        disk.write(blob, name: "b"); clock.advance(1)
        _ = disk.read("a"); clock.advance(1)          // a is now newer than b
        disk.write(blob, name: "c")                    // 300 > 250: b is the least recently used
        #expect(disk.contains("a"))
        #expect(!disk.contains("b"))
        #expect(disk.contains("c"))
        #expect(disk.bytesUsed() == 200)
    }

    @Test func diskSizeCapRejectsOversizeAndClears() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var disk = MusicArtworkDisk(directory: dir, capBytes: 100)
        disk.write(Data(repeating: 1, count: 500), name: "huge")
        #expect(!disk.contains("huge"))
        disk.write(Data(repeating: 1, count: 60), name: "ok")
        #expect(disk.bytesUsed() == 60)
        disk.clear()
        #expect(disk.bytesUsed() == 0)
    }

    @Test func concurrentLoadsShareOneRequest() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubTransport(body: makePNG(width: 300, height: 300), delayMs: 100)
        let store = MusicArtworkStore(directory: dir, http: MusicHTTP(transport: stub))
        let url = "https://example.com/c.png"
        let results = await withTaskGroup(of: MusicDecodedImage?.self) { g in
            for _ in 0..<6 { g.addTask { await store.load(url, targetPixelSize: 200) } }
            var out: [MusicDecodedImage?] = []
            for await r in g { out.append(r) }
            return out
        }
        #expect(results.count == 6)
        #expect(results.allSatisfy { $0 != nil })
        #expect(stub.hits == 1)
        #expect(results.first??.pixelWidth == 256)
        // A second call is a memory hit, and a restart is a disk hit: neither touches the network.
        _ = await store.load(url, targetPixelSize: 200)
        let again = MusicArtworkStore(directory: dir, http: MusicHTTP(transport: stub))
        #expect(await again.load(url, targetPixelSize: 200) != nil)
        #expect(stub.hits == 1)
        #expect(await store.bytesUsed() > 0)
        await store.clear()
        #expect(await store.bytesUsed() == 0)
    }

    @Test func negativeCacheExpires() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let stub = StubTransport(body: Data(), status: 500)
        let store = MusicArtworkStore(directory: dir, http: MusicHTTP(transport: stub), now: { clock.now })
        let url = "https://example.com/missing.png"
        #expect(await store.load(url, targetPixelSize: 100) == nil)
        #expect(await store.load(url, targetPixelSize: 100) == nil)
        #expect(stub.hits == 1)
        #expect(await store.failureIsCached(url))
        clock.advance(301)
        #expect(!(await store.failureIsCached(url)))
        #expect(await store.load(url, targetPixelSize: 100) == nil)
        #expect(stub.hits == 2)
    }

    @Test func oversizeDownloadIsRefused() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubTransport(body: makePNG(width: 200, height: 200))
        let store = MusicArtworkStore(directory: dir, http: MusicHTTP(transport: stub), maxDownloadBytes: 50)
        #expect(await store.load("https://example.com/big.png", targetPixelSize: 100) == nil)
    }

    @Test func fileCoverLoadsAndBadSchemeNeverHitsNetwork() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("cover.png")
        try makePNG(width: 500, height: 500).write(to: f)
        let stub = StubTransport(body: Data())
        let store = MusicArtworkStore(directory: dir.appendingPathComponent("cache"), http: MusicHTTP(transport: stub))
        let img = await store.load(f.absoluteString, targetPixelSize: 100)
        #expect(img?.pixelWidth == 128)
        #expect(await store.load("ftp://example.com/x.png", targetPixelSize: 100) == nil)
        #expect(stub.hits == 0)
    }
}
