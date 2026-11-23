import Testing
import Foundation
@testable import REDDY

@Suite("Service preferences") struct ServicePreferencesTests {
    typealias P = ServicePreferences
    private func ok(_ b: Bool, _ c: Comment? = nil) { #expect(b, c) }
    private func ids(_ p: P) -> [String] { p.pinned.map(\.rawValue) }

    @Test func freshAndExistingInstallsStartWithNetflixPinnedOnly() {
        #expect(ids(P.initial()) == ["netflix"]); #expect(P.initial().recents.isEmpty)
        #expect(ids(P.decode(nil)) == ["netflix"]); #expect(ids(P.decode(Data())) == ["netflix"])
    }

    @Test func pinUnpinAndOrder() {
        var p = P.initial()
        ok(p.pin(.hulu) && p.pin(.youtube)); #expect(ids(p) == ["netflix", "hulu", "youtube"])
        ok(!p.pin(.hulu)); #expect(ids(p) == ["netflix", "hulu", "youtube"])          // already pinned
        ok(!p.pin("ghost")); ok(!p.pin(.crunchyroll, available: [.netflix]))
        ok(p.unpin(.hulu)); ok(!p.unpin(.hulu)); #expect(ids(p) == ["netflix", "youtube"])
        #expect(p.isPinned(.youtube) && !p.isPinned(.hulu))
        ok(p.unpin(.netflix) && p.unpin(.youtube)); #expect(p.pinned.isEmpty)          // an empty bar is a valid choice
    }

    @Test func reorderingClampsAndKeepsEveryItem() {
        var p = P(pinned: [.netflix, .hulu, .youtube, .peacock])
        ok(p.move(.peacock, to: 0)); #expect(ids(p) == ["peacock", "netflix", "hulu", "youtube"])
        ok(p.move(.peacock, to: 99)); #expect(ids(p) == ["netflix", "hulu", "youtube", "peacock"])
        ok(p.move(.hulu, to: -5)); #expect(ids(p) == ["hulu", "netflix", "youtube", "peacock"])
        ok(!p.move(.crunchyroll, to: 1))
        ok(p.moveRight(.hulu)); #expect(ids(p) == ["netflix", "hulu", "youtube", "peacock"])
        ok(p.moveLeft(.youtube)); #expect(ids(p) == ["netflix", "youtube", "hulu", "peacock"])
        ok(!p.moveLeft(.netflix)); ok(!p.moveRight(.peacock)); #expect(Set(p.pinned).count == 4)
    }

    @Test func persistenceRoundTripKeepsOrderAndRecents() {
        var p = P.initial(); p.pin(.hbomax); p.pin(.hulu); p.move(.hulu, to: 1); p.noteOpened(.hulu); p.noteOpened(.peacock)
        #expect(P.decode(p.encoded()) == p)
        let defaults = UserDefaults(suiteName: "ServicePreferencesTests.\(UUID().uuidString)")!
        p.save(to: defaults); #expect(P.load(from: defaults) == p)
        #expect(P.defaultsKey == "streaming.servicePreferences.v1")
    }

    @Test func corruptOlderUnknownAndDuplicateData() {
        for bad in ["", "not json", "{", "[1,2]", "{\"pinned\":5}", "null", "\u{0}\u{1}"] { #expect(ids(P.decode(Data(bad.utf8))) == ["netflix"], Comment(rawValue: bad)) }
        #expect(ids(P.decode(Data("[\"hulu\",\"netflix\"]".utf8))) == ["hulu", "netflix"])          // an older plain list
        #expect(ids(P.decode(Data("{\"recents\":[\"hulu\"]}".utf8))) == ["netflix"])               // pinned missing -> default
        let messy = Data("{\"pinned\":[\"hulu\",\"hulu\",\"nope\",\"netflix\",\"Hulu\",\"netflix\"],\"recents\":[\"x\",\"hulu\",\"hulu\",\"youtube\",\"peacock\",\"hbomax\"]}".utf8)
        let p = P.decode(messy)
        #expect(ids(p) == ["hulu", "netflix"]); #expect(p.recents.map(\.rawValue) == ["hulu", "youtube", "peacock"])
        #expect(ids(P.decode(Data("{\"pinned\":[]}".utf8))) == [])          // deliberately empty stays empty
    }

    @Test func removedAndUnavailableProvidersAreDroppedOnLoad() {
        let saved = P(pinned: [.netflix, .hulu, .youtube], recents: [.youtube, .hulu]).encoded()
        let p = P.decode(saved, available: [.netflix, .youtube])
        #expect(ids(p) == ["netflix", "youtube"]); #expect(p.recents == [.youtube])
        #expect(ids(P.decode(nil, available: [.hulu])) == [])          // default pin not available
    }

    @Test func resetKeepsRecentsAndRestoresTheDefaultPins() {
        var p = P(pinned: [.hulu, .youtube], recents: [.hulu]); p.resetOrder()
        #expect(ids(p) == ["netflix"]); #expect(p.recents == [.hulu])
    }

    @Test func recentsAreCappedAtThreeDeduplicatedAndIdsOnly() {
        var p = P.initial()
        for id in [ProviderID.hulu, .youtube, .peacock, .hulu, .hbomax] { p.noteOpened(id) }
        #expect(p.recents.map(\.rawValue) == ["hbomax", "hulu", "peacock"])
        p.noteOpened("ghost"); #expect(p.recents.count == 3 && !p.recents.contains("ghost"))
        let json = String(decoding: p.encoded(), as: UTF8.self)
        #expect(Set(((try? JSONSerialization.jsonObject(with: p.encoded())) as? [String: Any])?.keys.map { $0 } ?? []) == ["pinned", "recents"], Comment(rawValue: json))
    }

    @Test func anActiveUnpinnedServiceIsNeverStored() {
        var p = P.initial(); p.noteOpened(.hulu)          // opening does not pin
        #expect(!p.isPinned(.hulu)); #expect(ids(P.decode(p.encoded())) == ["netflix"])
    }
}
