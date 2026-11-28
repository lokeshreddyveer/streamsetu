import Testing
import Foundation
import CoreGraphics
@testable import REDDY

private actor FakeLoader: MusicArtworkLoading {
    var cachedAddresses: Set<String> = []
    private(set) var loads: [String] = []
    private(set) var pixels: [Int] = []
    var delayNanos: UInt64 = 0
    init(cached: Set<String> = [], delay: UInt64 = 0) { cachedAddresses = cached; delayNanos = delay }
    func isCached(_ address: String, pixels: Int) async -> Bool { cachedAddresses.contains(address) }
    func load(_ address: String, pixels: Int) async {
        if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
        if Task.isCancelled { return }
        loads.append(address); self.pixels.append(pixels)
    }
}

private func addresses(_ n: Int) -> [String] { (0..<n).map { "https://example.com/cover\($0).jpg" } }

private func tinyImage() -> MusicDecodedImage {
    let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return MusicDecodedImage(cg: ctx.makeImage()!)
}

@Suite("Music artwork refinements")
struct MusicArtworkRefinementTests {
    @Test func bucketsAreRightSized() {
        #expect(MusicArtworkClass.trackThumb.bucket(scale: 2) == 128)
        #expect(MusicArtworkClass.trackThumb.bucket(scale: 1) == 64)
        #expect(MusicArtworkClass.mini.bucket(scale: 2) == 256)
        #expect(MusicArtworkClass.tile.bucket(scale: 2) == 512)
        #expect(MusicArtworkClass.nowPlaying.bucket(scale: 2) == 1024)
        #expect(MusicArtworkClass.fullscreen.bucket(scale: 2) == 1024)
        #expect(MusicArtworkClass.hero.bucket(scale: 2) == 1024)
    }

    @Test func tinyCellsNeverRequestLargeBuckets() {
        for scale in [1.0, 2.0, 3.0] {
            #expect(MusicArtworkClass.trackThumb.bucket(scale: scale) <= 256)
            #expect(MusicArtworkClass.trackThumb.bucket(scale: scale) < MusicArtworkClass.tile.bucket(scale: scale) || scale == 3)
        }
        #expect(MusicArtworkClass.trackThumb.isSmall)
        #expect(!MusicArtworkClass.tile.isSmall)
    }

    @Test @MainActor func prefetchWindowIsBounded() async {
        let fake = FakeLoader()
        let p = MusicArtworkPrefetcher(loader: fake)
        p.prefetch(addresses: addresses(40), artworkClass: .tile, owner: "a", window: 100)
        await p.waitUntilIdle()
        #expect(await fake.loads.count == MusicArtworkPrefetcher.maxWindow)
        #expect(await fake.pixels.allSatisfy { $0 == 512 })
    }

    @Test @MainActor func cachedAndInvalidAddressesDoNoWork() async {
        let list = addresses(3)
        let fake = FakeLoader(cached: [list[0]])
        let p = MusicArtworkPrefetcher(loader: fake)
        p.prefetch(addresses: list + ["", "ftp://x/y", "https://localhost/a.jpg"], artworkClass: .trackThumb, owner: "a")
        await p.waitUntilIdle()
        #expect(await fake.loads == [list[1], list[2]])
        #expect(await fake.pixels.allSatisfy { $0 == 128 })
        #expect(p.inFlightCount == 0)
    }

    @Test @MainActor func duplicateRequestsAcrossOwnersLoadOnce() async {
        let fake = FakeLoader(delay: 20_000_000)
        let p = MusicArtworkPrefetcher(loader: fake)
        let list = addresses(4)
        p.prefetch(addresses: list, owner: "a")
        p.prefetch(addresses: list, owner: "b")
        await p.waitUntilIdle()
        #expect(await fake.loads.sorted() == list.sorted())
    }

    @Test @MainActor func cancelStopsRemainingWork() async {
        let fake = FakeLoader(delay: 50_000_000)
        let p = MusicArtworkPrefetcher(loader: fake)
        p.prefetch(addresses: addresses(10), owner: "a")
        p.cancel(owner: "a")
        await p.waitUntilIdle()
        #expect(p.inFlightCount == 0)
        #expect(await fake.loads.count < 10)
    }

    @Test @MainActor func newWindowReplacesOld() async {
        let fake = FakeLoader(delay: 30_000_000)
        let p = MusicArtworkPrefetcher(loader: fake)
        let old = addresses(8)
        let fresh = (100..<104).map { "https://example.com/new\($0).jpg" }
        p.prefetch(addresses: old, owner: "a")
        p.prefetch(addresses: fresh, owner: "a")
        await p.waitUntilIdle()
        let loads = await fake.loads
        #expect(Set(fresh).isSubset(of: Set(loads)))
        #expect(loads.filter { old.contains($0) }.count < old.count)
    }

    @Test func memoryPressureClearsMemoryTier() {
        let memory = MusicArtworkMemory()
        memory.insert(tinyImage(), url: "https://example.com/a.jpg", bucket: 128)
        #expect(memory.image(url: "https://example.com/a.jpg", bucket: 128) != nil)
        let watcher = MusicArtworkMemoryPressure(memory: memory)
        watcher.evict()
        #expect(memory.image(url: "https://example.com/a.jpg", bucket: 128) == nil)
    }

    @Test func decodeGateCapsConcurrency() async {
        let gate = MusicDecodeGate(limit: 2)
        await gate.acquire(); await gate.acquire()
        #expect(await gate.active == 2)
        await gate.release()
        #expect(await gate.active == 1)
        await gate.release()
        #expect(await gate.active == 0)
    }

    @Test func placeholderTintIsStable() {
        #expect(MusicCoverTint.hue(for: "https://example.com/a.jpg") == MusicCoverTint.hue(for: "https://example.com/a.jpg"))
        #expect(MusicCoverTint.hue(for: "a") != MusicCoverTint.hue(for: "b"))
        #expect((0..<1).contains(MusicCoverTint.hue(for: "x")))
    }
}
