import Foundation
import Testing
@testable import REDDY

/// The right-hand panel and player bar, second pass: the strip under the Now Playing title, the "Playing from" line, the stable lyrics-loading phrase and its wording,
/// the seek guard and the retired Info tab. Pure rules only; no window and no audio.
private func connection(_ kind: MusicConnectionKind, _ name: String, role: MusicRole? = nil) -> MusicConnection {
    let id = MusicEntityID.provisional(kind: kind == .film ? .film : .person, providerUID: "graph:" + name)
    return MusicConnection(kind: kind, target: id, name: name, role: role, imageRef: nil, year: nil, count: 1, derived: false)
}

private func song(artists: [MusicArtistRef]) -> MusicTrack {
    MusicTrack(id: "s1", providerID: "p", title: "Song", durationMs: 200_000, artists: artists)
}

@Suite("Now Playing link strip") struct NowPlayingStripTests {
    @Test func theStripHoldsFilmAndCreditsAndNotTheArtistsAlreadyLinkedAbove() {
        let t = song(artists: [MusicArtistRef(id: "a1", name: "Lata")])
        var c = MusicTrackContext(song: MusicEntityID.provisional(kind: .recording, providerUID: "p:s1"))
        c.film = connection(.film, "Awaara")
        c.musicDirector = connection(.musicDirector, "Shankar", role: .musicDirector)
        c.singers = [connection(.singer, "Lata", role: .singer), connection(.singer, "Mukesh", role: .singer)]
        let chips = MusicTrackLinkItems.strip(track: t, context: c)
        #expect(chips.map(\.name) == ["Awaara", "Shankar", "Mukesh"])
        #expect(chips.allSatisfy { !$0.label.isEmpty && !$0.name.hasPrefix("Go to") })
    }

    @Test func aCompilationCreditDoesNotHideAnyone() {
        let t = song(artists: [MusicArtistRef(id: "v", name: "Various Artists")])
        var c = MusicTrackContext(song: MusicEntityID.provisional(kind: .recording, providerUID: "p:s1"))
        c.singers = [connection(.singer, "Various Artists", role: .singer)]
        #expect(MusicTrackLinkItems.strip(track: t, context: c).count == 1)
    }

    @Test func aPersonIsNeverListedTwice() {
        let t = song(artists: [])
        var c = MusicTrackContext(song: MusicEntityID.provisional(kind: .recording, providerUID: "p:s1"))
        let m = connection(.musicDirector, "Pritam", role: .musicDirector)
        c.musicDirector = m
        c.singers = [connection(.singer, "Pritam", role: .singer)]
        let chips = MusicTrackLinkItems.strip(track: t, context: c)
        #expect(chips.count == 2 && Set(chips.map(\.role)) == [.musicDirector, .singer])
    }
}

@Suite("Playing from, loading phrases and seek guard") struct SidebarSecondPassTests {
    @Test func aProviderNameIsNeverTheContext() {
        #expect(MusicPlayingFrom.line(source: "Deezer", providerNames: ["Deezer", "Audius"]) == nil)
        #expect(MusicPlayingFrom.line(source: "  deezer ", providerNames: ["Deezer"]) == nil)
        #expect(MusicPlayingFrom.line(source: "Road trip", providerNames: ["Deezer"]) == "Road trip")
        #expect(MusicPlayingFrom.line(source: nil, providerNames: []) == nil)
        #expect(MusicPlayingFrom.line(source: "   ", providerNames: []) == nil)
    }

    @Test func theLoadingPhraseIsStablePerSongAndAlwaysOneOfTheFive() {
        #expect(MusicLyricsLoadingPhrases.all.count == 5)
        for key in ["p:1", "p:2", "yt:abc", ""] {
            let a = MusicLyricsLoadingPhrases.phrase(for: key), b = MusicLyricsLoadingPhrases.phrase(for: key)
            #expect(a == b && MusicLyricsLoadingPhrases.all.contains(a))
        }
        #expect(Set((0..<60).map { MusicLyricsLoadingPhrases.phrase(for: "song-\($0)") }).count > 1)
    }

    @Test func everyLoadingPhraseHasHindiAndTelugu() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for code in ["hi", "te"] {
            let url = root.appendingPathComponent("Resources/Localization/\(code).lproj/Localizable.strings")
            let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
            for p in MusicLyricsLoadingPhrases.all {
                #expect(table[p] != nil && table[p] != p, "\(code): \(p)")
            }
        }
    }

    @Test func aSeekNeedsAKnownLength() {
        #expect(MusicSeekGuard.target(fraction: 0.5, duration: 0) == nil)
        #expect(MusicSeekGuard.target(fraction: 0.5, duration: .nan) == nil)
        #expect(MusicSeekGuard.target(fraction: .nan, duration: 100) == nil)
        #expect(MusicSeekGuard.target(fraction: 0.25, duration: 200) == 50)
        #expect(MusicSeekGuard.target(fraction: 2, duration: 200) == 200)
        #expect(MusicSeekGuard.target(fraction: -1, duration: 200) == 0)
    }

    @MainActor @Test func aPanelLeftOnTheRetiredInfoTabOpensOnRelated() throws {
        let name = "SidebarGaps2-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        let s = MusicContextPanelState(defaults: d)
        s.enter(.home); s.show(.info)
        #expect(s.selectedTab == .related)
    }
}
