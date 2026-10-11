import Testing
import Foundation
@testable import REDDY

@MainActor @Suite("Multi-view") struct MultiViewTests {
    private func model(_ started: @escaping () -> Void = {}) -> MultiViewModel {
        MultiViewModel(resolve: { c in PlaybackRequest(itemID: c.id, kind: .channel, sourceID: c.sourceID, title: c.name, url: URL(fileURLWithPath: "/nonexistent/\(c.providerID).ts"), isLive: true) },
                       willStart: started)
    }
    private let src = PlaylistSource(name: "T", type: .m3uRemote, baseURL: "http://example.com/p.m3u")
    private func ch(_ n: Int) -> Channel { TestSupport.channel(src, "\(n)", "Channel \(n)") }

    @Test func holdsFourTilesAndRefusesAFifthOrADuplicate() {
        let m = model()
        #expect(m.add(ch(1)) == .added)
        #expect(m.add(ch(1)) == .alreadyShown)
        for i in 2...4 { #expect(m.add(ch(i)) == .added) }
        #expect(m.isFull && m.tiles.count == 4)
        #expect(m.add(ch(5)) == .full)
        m.removeAll()
    }

    @Test func exactlyOneTileIsAudibleAndRemovingItHandsSoundOn() {
        let m = model()
        m.add(ch(1)); m.add(ch(2)); m.add(ch(3))
        #expect(m.tiles.filter(\.isAudible).count == 1 && m.tiles[0].isAudible, "the first channel gets the sound")
        m.setAudible(m.tiles[2].id)
        #expect(m.tiles.map(\.isAudible) == [false, false, true])
        m.remove(m.tiles[2].id)
        #expect(m.tiles.count == 2 && m.tiles.filter(\.isAudible).count == 1)
        m.removeAll()
        #expect(m.tiles.isEmpty && m.audible == nil)
    }

    @Test func layoutFollowsTheNumberOfTiles() {
        let m = model()
        #expect(m.columns == 1)
        m.add(ch(1)); #expect(m.columns == 1)
        m.add(ch(2)); #expect(m.columns == 2)
        m.add(ch(3)); m.add(ch(4)); #expect(m.columns == 2)
        m.removeAll()
    }

    @Test func startingStopsTheMainPlayerOnceOnly() {
        var calls = 0
        let m = model { calls += 1 }
        m.add(ch(1)); m.add(ch(2))
        #expect(calls == 1)
        m.removeAll(); m.add(ch(3))
        #expect(calls == 2)
        m.removeAll()
    }

    @Test func anUnplayableChannelShowsAMessageInsteadOfHanging() async throws {
        let m = MultiViewModel(resolve: { _ in throw SourceError.invalidResponse("gone") })
        m.reconnectDelay = 0.01
        m.add(ch(1))
        for _ in 0..<100 where m.tiles[0].failure == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(m.tiles[0].failure != nil)
        m.removeAll()
    }

    @Test func aDroppedStreamIsReconnectedBeforeAnErrorIsShown() async throws {
        final class Counter: @unchecked Sendable { let l = NSLock(); var n = 0; func bump() -> Int { l.lock(); defer { l.unlock() }; n += 1; return n } }
        let c = Counter()
        let m = MultiViewModel(resolve: { _ in _ = c.bump(); throw SourceError.invalidResponse("dropped") })
        m.reconnectDelay = 0.01
        m.add(ch(1))
        for _ in 0..<100 where m.tiles[0].failure == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(c.n == MultiViewModel.maxReconnects + 1, "the first try plus each reconnect, then it gives up")
        #expect(m.tiles[0].failure != nil && !m.tiles[0].reconnecting)
        m.retry(m.tiles[0].id)                                  // Try Again starts a fresh round
        #expect(m.tiles[0].failure == nil)
        for _ in 0..<100 where m.tiles[0].failure == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(c.n == 2 * (MultiViewModel.maxReconnects + 1))
        m.removeAll()
    }

    @Test func clickingAnotherTileOnlyChangesTheSound() {
        let m = model(defaults: freshDefaults())
        m.add(ch(1)); m.add(ch(2)); m.add(ch(3))
        let ids = m.tiles.map(\.id), channels = m.tiles.map(\.channel.id)
        m.setAudible(ids[1]); m.setAudible(ids[2]); m.setAudible(ids[0])
        #expect(m.tiles.map(\.id) == ids && m.tiles.map(\.channel.id) == channels, "no tile is reloaded or replaced by a click")
        #expect(m.tiles.map { $0.engine.player.isMuted } == [false, true, true])
        m.removeAll()
    }

    private func model(defaults: UserDefaults, lookup: @escaping ([String]) -> [Channel] = { _ in [] }) -> MultiViewModel {
        MultiViewModel(resolve: { c in PlaybackRequest(itemID: c.id, kind: .channel, sourceID: c.sourceID, title: c.name, url: URL(fileURLWithPath: "/nonexistent/\(c.providerID).ts"), isLive: true) },
                       lookup: lookup, defaults: defaults)
    }
    private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "mv-\(UUID().uuidString)")! }

    @Test func swappingAChannelKeepsItsPlaceAndItsSound() {
        let m = model()
        m.add(ch(1)); m.add(ch(2)); m.add(ch(3))
        let second = m.tiles[1].id
        m.setAudible(second)
        m.replace(second, with: ch(9))
        #expect(m.tiles.map(\.channel.providerID) == ["1", "9", "3"])
        #expect(m.tiles[1].isAudible && m.tiles.filter(\.isAudible).count == 1)
        m.replace(m.tiles[0].id, with: ch(9))                 // already showing: refused
        #expect(m.tiles[0].channel.providerID == "1")
        m.removeAll()
    }

    @Test func spotlightAndMaximizeTrackTheRightTile() {
        let m = model(defaults: freshDefaults())
        m.add(ch(1)); m.add(ch(2)); m.add(ch(3))
        #expect(m.spotlight?.channel.providerID == "1" && m.others.count == 2)
        m.makeSpotlight(m.tiles[2].id)
        #expect(m.layout == .spotlight && m.spotlight?.channel.providerID == "3" && m.audible?.channel.providerID == "3")
        m.toggleMaximize(m.tiles[1].id)
        #expect(m.maximized?.channel.providerID == "2" && m.audible?.channel.providerID == "2")
        m.restoreFromMaximize()
        #expect(m.maximized == nil)
        m.toggleMaximize(m.tiles[0].id); m.remove(m.tiles[0].id)
        #expect(m.maximized == nil, "removing the filled tile returns to the overview")
        m.removeAll()
    }

    @Test func muteAllAndRestoreGivesTheSoundBack() {
        let m = model(defaults: freshDefaults())
        m.add(ch(1)); m.add(ch(2))
        m.setAudible(m.tiles[1].id)
        m.toggleMute()
        #expect(m.isMuted)
        m.toggleMute()
        #expect(!m.isMuted && m.audible?.channel.providerID == "2")
        m.selectTile(at: 0); m.selectTile(at: 7)            // out of range is ignored
        #expect(m.audible?.channel.providerID == "1")
        m.removeAll()
    }

    @Test func setsAreSavedReloadedAndSurviveARestart() {
        let d = freshDefaults()
        let all = (1...4).map(ch)
        let lookup: ([String]) -> [Channel] = { ids in all.filter { ids.contains($0.id) } }
        let m = model(defaults: d, lookup: lookup)
        m.add(all[0]); m.add(all[2])
        m.savePreset(named: "  Football ")
        m.savePreset(named: "football")                       // same name replaces, never duplicates
        m.savePreset(named: "   ")                            // blank is ignored
        #expect(m.presets.count == 1 && m.presets[0].name == "Football")
        m.removeAll()
        let restarted = model(defaults: d, lookup: lookup)
        #expect(restarted.presets.count == 1)
        #expect(restarted.load(restarted.presets[0]) == 2 && restarted.tiles.map(\.channel.providerID) == ["1", "3"])
        restarted.layout = .spotlight
        #expect(model(defaults: d).layout == .spotlight)
        restarted.deletePreset(restarted.presets[0].id)
        #expect(model(defaults: d).presets.isEmpty)
        restarted.removeAll()
    }

    @Test func aSetSkipsChannelsThatNoLongerExist() {
        let m = model(defaults: freshDefaults(), lookup: { ids in ids.contains(self.ch(1).id) ? [self.ch(1)] : [] })
        m.add(ch(1)); m.add(ch(2))
        m.savePreset(named: "Mixed")
        let loaded = m.load(m.presets[0])
        #expect(loaded == 1)
        m.removeAll()
    }
}
