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
}
