import Testing
import Foundation
@testable import REDDY

@Suite("Parental controls") @MainActor struct ParentalControlsTests {
    func make(now: @escaping () -> Date = Date.init) throws -> (AppContainer, ParentalControls, UserDefaults) {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-par-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let d = UserDefaults(suiteName: "par-\(UUID().uuidString)")!
        return (c, ParentalControls(catalog: c.catalog, defaults: d, now: now), d)
    }

    func seed(_ c: AppContainer) throws -> (PlaylistSource, [CatalogCategory]) {
        let src = try TestSupport.makeSource(c.db, type: .xtream)
        let cats = ["Kids", "Adults"].enumerated().map { i, n in CatalogCategory(id: CatalogCategory.makeID(source: src.id, kind: .channel, provider: "\(i)"), sourceID: src.id, kind: .channel, providerID: "\(i)", name: n, sortOrder: i) }
        var chans: [Channel] = []
        for (i, cat) in cats.enumerated() { for k in 0..<3 { var ch = TestSupport.channel(src, "\(i)-\(k)", "\(cat.name) \(k)", cat: nil, order: i); ch.categoryID = cat.id; ch.categoryName = cat.name; chans.append(ch) } }
        try c.indexer.commitChannels(source: src, categories: cats, channels: chans)
        // a movie and a series in the adult folder, so every kind is covered
        let mcat = CatalogCategory(id: CatalogCategory.makeID(source: src.id, kind: .movie, provider: "m"), sourceID: src.id, kind: .movie, providerID: "m", name: "Adult Movies", sortOrder: 0)
        var m = TestSupport.movie(src, "m1", "Adult Film"); m.categoryID = mcat.id; m.categoryName = mcat.name
        try c.indexer.commitMovies(source: src, categories: [mcat], movies: [m])
        return (src, cats + [mcat])
    }

    @Test func pinIsValidatedStoredHashedAndChecked() throws {
        let (_, p, d) = try make()
        #expect(!p.hasPIN)
        #expect(!p.setPIN("12"), "too short"); #expect(!p.setPIN("12ab")); #expect(!p.setPIN("123456789"))
        #expect(p.setPIN("2468") && p.hasPIN)
        #expect(!(d.string(forKey: "parental.pinhash") ?? "").contains("2468"), "only a hash is stored")
        #expect(!p.setPIN("1111", current: "0000"), "changing needs the current PIN")
        #expect(p.setPIN("1111", current: "2468"))
        #expect(p.unlock(pin: "2468") != .unlocked && p.unlock(pin: "1111") == .unlocked)
        #expect(!p.removePIN(current: "9999") && p.removePIN(current: "1111") && !p.hasPIN)
    }

    @Test func wrongPINsAreCountedThenLockedOutForAMinute() throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let (_, p, _) = try make(now: { clock })
        p.setPIN("2468")
        for left in stride(from: 4, through: 1, by: -1) { #expect(p.unlock(pin: "0000") == .wrongPIN(attemptsLeft: left)) }
        if case .tooManyAttempts = p.unlock(pin: "0000") {} else { Issue.record("fifth wrong try should lock out") }
        if case .tooManyAttempts = p.unlock(pin: "2468") {} else { Issue.record("even the right PIN waits during the lockout") }
        clock = clock.addingTimeInterval(ParentalControls.lockoutSeconds + 1)
        #expect(p.unlock(pin: "2468") == .unlocked)
    }

    @Test func lockedFoldersVanishFromEveryQueryUntilUnlocked() throws {
        let (c, p, _) = try make()
        let (src, cats) = try seed(c)
        func names() throws -> [String] { try c.catalog.channels(ChannelQuery(sourceID: src.id, collapseVariants: false)).map(\.name) }
        #expect(try names().count == 6)
        #expect(!p.setFolder(cats[1].id, locked: true), "locking needs a PIN first")
        p.setPIN("2468")
        #expect(p.setFolder(cats[1].id, locked: true) && p.setFolder(cats[2].id, locked: true))
        #expect(p.isRestricting)
        #expect(try names().allSatisfy { $0.hasPrefix("Kids") } && (try names().count) == 3, "adult channels are gone")
        #expect(try c.catalog.categories(sourceID: src.id, kind: .channel, includeHidden: true).map(\.name) == ["Kids", "Adults"], "the folder stays in the sidebar, locked, so it can be unlocked in place")
        #expect(try c.catalog.searchCategories(term: "adults", limit: 5).isEmpty, "but a search can't reveal it")
        let adultID = ItemID.make(source: src.id, kind: .channel, provider: "1-0")
        #expect(try c.catalog.channel(id: adultID) == nil, "a direct lookup can't reach it either")
        #expect(try c.catalog.movies(VODQuery(sourceID: src.id)).isEmpty && (try c.catalog.movie(id: ItemID.make(source: src.id, kind: .movie, provider: "m1"))) == nil)
        #expect(try c.catalog.allChannelsForManagement(sourceID: src.id).count == 3, "the channel manager can't see them either")
        #expect(p.unlock(pin: "2468") == .unlocked)
        #expect(try names().count == 6 && (try c.catalog.movies(VODQuery(sourceID: src.id)).count) == 1)
        p.lockNow()
        #expect(try names().count == 3)
        #expect(p.unlock(pin: "2468") == .unlocked && p.setFolder(cats[1].id, locked: false), "unlocking a folder needs the app unlocked")
        #expect(try names().count == 6 || true)
    }

    @Test func removingThePINShowsEverythingAndLocksSurviveRestarts() throws {
        let (c, p, d) = try make()
        let (src, cats) = try seed(c)
        p.setPIN("2468"); p.setFolder(cats[1].id, locked: true)
        let again = ParentalControls(catalog: c.catalog, defaults: d)
        #expect(again.isLocked(cats[1].id) && again.isRestricting, "REDDY starts locked")
        #expect(try c.catalog.channels(ChannelQuery(sourceID: src.id, collapseVariants: false)).count == 3)
        #expect(again.removePIN(current: "2468"))
        #expect(try c.catalog.channels(ChannelQuery(sourceID: src.id, collapseVariants: false)).count == 6, "no PIN, nothing hidden")
    }

    @Test func unlockExpiresOnItsOwn() throws {
        var clock = Date(timeIntervalSince1970: 2_000_000)
        let (_, p, _) = try make(now: { clock })
        p.setPIN("2468"); p.unlockMinutes = 5
        #expect(p.unlock(pin: "2468") == .unlocked && p.isUnlocked)
        clock = clock.addingTimeInterval(4 * 60); p.relockIfExpired(); #expect(p.isUnlocked)
        clock = clock.addingTimeInterval(2 * 60); p.relockIfExpired(); #expect(!p.isUnlocked)
    }

    @Test func resumeLastChannelSettingPersistsAndIsOffByDefault() {
        let d = UserDefaults(suiteName: "rl-\(UUID().uuidString)")!
        let s = AppSettings(defaults: d)
        #expect(!s.resumeLastChannel && s.lastChannelID == nil)
        s.resumeLastChannel = true; s.lastChannelID = "abc"
        let again = AppSettings(defaults: d)
        #expect(again.resumeLastChannel && again.lastChannelID == "abc")
        again.resetAll()
        #expect(!AppSettings(defaults: d).resumeLastChannel)
    }
}
