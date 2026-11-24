import Testing
import AppKit
@testable import REDDY

@MainActor @Suite("Service icons") struct ServiceIconTests {
    /// Services without a bundled icon show the letter tile. Every service has one now.
    static let lettersOnly: Set<String> = []
    static var ids: [String] { ProviderRegistry.standard.definitions.map(\.id.rawValue) }

    @Test func everyServiceHasAnIconOrIsListedAsLettersOnly() {
        for id in Self.ids { #expect((ServiceIconStore.url(id) != nil) != Self.lettersOnly.contains(id), Comment(rawValue: id)) }
    }

    @Test func eachFileIsAValidImageOfAtLeast128PixelsUnder100KB() throws {
        for id in Self.ids where !Self.lettersOnly.contains(id) {
            let url = try #require(ServiceIconStore.url(id))
            let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            #expect(size < 100_000, Comment(rawValue: id))
            let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: url)), Comment(rawValue: id))
            #expect(rep.pixelsWide >= 128 && rep.pixelsHigh >= 128 && rep.pixelsWide == rep.pixelsHigh, Comment(rawValue: id))
        }
    }

    @Test func theStoreReturnsAnImageForEveryBundledIconAfterPreload() async {
        await ServiceIconStore.preloadAndWait()
        for id in Self.ids where !Self.lettersOnly.contains(id) { #expect(ServiceIconStore.icon(for: ProviderID(unchecked: id)) != nil, Comment(rawValue: id)) }
    }

    @Test func aServiceWithoutAnIconFallsBack() {
        for id in Self.lettersOnly { #expect(ServiceIconStore.icon(for: ProviderID(unchecked: id)) == nil) }
        #expect(ServiceIconStore.icon(for: ProviderID(unchecked: "no-such-service")) == nil)
        #expect(ServiceIconStore.url("no-such-service") == nil)
    }

    @Test func everyNormalisedIconIsSquareTheSameSizeAndFullyOpaque() async throws {
        await ServiceIconStore.preloadAndWait()
        for id in Self.ids {
            let image = try #require(ServiceIconStore.icon(for: ProviderID(unchecked: id)), Comment(rawValue: id))
            var rect = CGRect(origin: .zero, size: image.size)
            let cg = try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil), Comment(rawValue: id))
            #expect(cg.width == ServiceIconStore.normalizedSide && cg.height == ServiceIconStore.normalizedSide, Comment(rawValue: id))
            let rep = NSBitmapImageRep(cgImage: cg)
            var transparent = 0
            for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) < 0.99 { transparent += 1 } }
            #expect(transparent == 0, Comment(rawValue: "\(id) has \(transparent) non-opaque pixels"))
        }
    }

    @Test func normalisingTrimsMarginsAndFillsRoundedCorners() throws {
        // a 100x60 canvas with a 40x40 red rounded-corner icon inside a transparent margin
        let img = NSImage(size: NSSize(width: 100, height: 60), flipped: false) { _ in
            NSColor.red.setFill(); NSBezierPath(roundedRect: NSRect(x: 30, y: 10, width: 40, height: 40), xRadius: 10, yRadius: 10).fill(); return true
        }
        let out = ServiceIconStore.normalized(img)
        var rect = CGRect(origin: .zero, size: out.size)
        let rep = NSBitmapImageRep(cgImage: try #require(out.cgImage(forProposedRect: &rect, context: nil, hints: nil)))
        #expect(rep.pixelsWide == rep.pixelsHigh)
        for (x, y) in [(0, 0), (rep.pixelsWide - 1, 0), (0, rep.pixelsHigh - 1), (rep.pixelsWide - 1, rep.pixelsHigh - 1), (rep.pixelsWide / 2, rep.pixelsHigh / 2)] {
            let c = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            #expect(c.alphaComponent > 0.99 && c.redComponent > 0.9 && c.greenComponent < 0.15)
        }
    }

    @Test func everyIconChipHasTheSameFrame() {
        let widths = Set(ProviderRegistry.standard.definitions.map { TopBarMenuRow.serviceItem($0.id, active: nil).width(tabPadding: 14) })
        #expect(widths == [ServiceChip.hitWidth])
        #expect(ServiceChip.iconSize == 22)
    }
}
