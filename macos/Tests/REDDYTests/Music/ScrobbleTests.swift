import Testing
import Foundation
@testable import REDDY

// Scrobbling. Pure logic and canned replies only: no network, no socket, no real clock.

private final class ScrobbleStub: MusicHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URLRequest] = []
    private let handler: @Sendable (URLRequest) -> (Int, String)
    init(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) { self.handler = handler }
    var requests: [URLRequest] { lock.withLock { seen } }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { seen.append(request) }
        let (code, body) = handler(request)
        let resp = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: code, httpVersion: nil, headerFields: nil)
        return (Data(body.utf8), resp ?? HTTPURLResponse())
    }
}

private final class ScrobbleMemoryStore: ScrobbleSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func read(_ account: String) -> String? { lock.withLock { values[account] } }
    func write(_ value: String, account: String) { lock.withLock { values[account] = value } }
    func remove(_ account: String) { lock.withLock { values[account] = nil } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    @discardableResult func next() -> Int { lock.withLock { n += 1; return n } }
    var value: Int { lock.withLock { n } }
}

private final class FakeScrobbleProvider: MusicScrobbleProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var got: [MusicScrobble] = []
    private var playing: [MusicTrack] = []
    var info: MusicProviderInfo { MusicProviderInfo(id: "fake", name: "Fake", summary: "") }
    var capabilities: MusicCapabilities { [.scrobble] }
    var isSignedIn: Bool { get async { true } }
    func signIn() async throws {}
    func signOut() async {}
    func scrobble(_ s: MusicScrobble) async throws { lock.withLock { got.append(s) } }
    func nowPlaying(_ track: MusicTrack) async { lock.withLock { playing.append(track) } }
    var scrobbles: [MusicScrobble] { lock.withLock { got } }
    var nowPlayings: [MusicTrack] { lock.withLock { playing } }
}

private func info(_ title: String, _ artists: [String], album: String = "", video: Bool = false, uid: String = "x:1", ms: Int64 = 200_000) -> ScrobbleTrackInfo {
    ScrobbleTrackInfo(uid: uid, title: title, artists: artists, album: album, isVideo: video, durationMs: ms)
}

private func rule(_ field: ScrobbleField, _ find: String, _ replace: String = "") -> ScrobbleRule { ScrobbleRule(enabled: true, field: field, find: find, replace: replace) }

// MARK: cleaner

@Suite struct TrackCleanerTests {
    @Test func plainTrackPassesThrough() {
        let r = MusicTrackCleaner.clean(info("Song", ["A", "B"], album: "Al"), ScrobbleCleanSettings())
        #expect(r.artist == "A, B" && r.title == "Song" && r.album == "Al" && r.skip == nil)
    }

    @Test func keyedEditWinsAndSkipsEverythingElse() {
        var s = ScrobbleCleanSettings()
        s.splitVideoTitles = true; s.primaryArtist = true; s.rules = [rule(.title, "Song", "CHANGED")]
        s.edits = [ScrobbleEdit(key: "x:1", artist: "  Fixed  ", title: "", album: "New")]
        let r = MusicTrackCleaner.clean(info("Song", ["A, B"], video: true), s)
        #expect(r.artist == "Fixed" && r.title == "Song" && r.album == "New")
        #expect(r.editIndex == 0 && r.rulesApplied.isEmpty && !r.splitFired)
    }

    @Test func editSkipsTheTrack() {
        var s = ScrobbleCleanSettings()
        s.edits = [ScrobbleEdit(key: "x:1", skip: true)]
        #expect(MusicTrackCleaner.clean(info("Song", ["A"]), s).skip == .edit)
    }

    @Test func firstMatchingEditWins() {
        var s = ScrobbleCleanSettings()
        s.edits = [ScrobbleEdit(key: "other"), ScrobbleEdit(key: "x:1", title: "First"), ScrobbleEdit(key: "x:1", title: "Second")]
        let r = MusicTrackCleaner.clean(info("Song", ["A"]), s)
        #expect(r.title == "First" && r.editIndex == 1)
    }

    @Test func keylessEditMatchesTrimmedCaseInsensitiveWithBlankWildcards() {
        var s = ScrobbleCleanSettings()
        s.edits = [ScrobbleEdit(fromArtist: " the ARTIST ", fromTitle: "", title: "Right")]
        #expect(MusicTrackCleaner.clean(info("Anything", ["The Artist"]), s).title == "Right")
        #expect(MusicTrackCleaner.clean(info("Anything", ["Someone"]), s).title == "Anything")
        s.edits = [ScrobbleEdit(title: "Never")]   // all from_ fields blank matches nothing
        #expect(MusicTrackCleaner.clean(info("Anything", ["Someone"]), s).title == "Anything")
    }

    @Test func titleSplitOnlyForVideosAtTheEarliestSpacedDash() {
        var s = ScrobbleCleanSettings(); s.splitVideoTitles = true
        let r = MusicTrackCleaner.clean(info("Ruelle - Fire Meets Fate - Shadowhunters 3x10", ["Channel"], video: true), s)
        #expect(r.artist == "Ruelle" && r.title == "Fire Meets Fate - Shadowhunters 3x10" && r.splitFired)
        let song = MusicTrackCleaner.clean(info("Ruelle - Fire", ["Channel"], video: false), s)
        #expect(song.artist == "Channel" && !song.splitFired)
        #expect(MusicTrackCleaner.splitTitle("Re-Run") == nil)
        #expect(MusicTrackCleaner.splitTitle(" - Intro") == nil)
        #expect(MusicTrackCleaner.splitTitle("A \u{2013} B")?.title == "B")
        #expect(MusicTrackCleaner.splitTitle("A \u{2014} B - C")?.artist == "A")
        var off = ScrobbleCleanSettings(); off.splitVideoTitles = false
        #expect(!MusicTrackCleaner.clean(info("A - B", ["C"], video: true), off).splitFired)
    }

    @Test func primaryArtistRules() {
        var s = ScrobbleCleanSettings(); s.primaryArtist = true
        #expect(MusicTrackCleaner.clean(info("S", ["Future", "Metro Boomin"]), s).artist == "Future")
        #expect(MusicTrackCleaner.clean(info("S", ["Future & Metro Boomin"]), s).artist == "Future & Metro Boomin")
        #expect(MusicTrackCleaner.clean(info("S", ["Tyler, The Creator"]), s).artist == "Tyler, The Creator")
        s.primaryStrict = true
        #expect(MusicTrackCleaner.clean(info("S", ["Future & Metro Boomin"]), s).artist == "Future")
        #expect(MusicTrackCleaner.cutPrimary("A, B", strict: false) == "A")
        #expect(MusicTrackCleaner.cutPrimary("A & B", strict: false) == "A & B")
        #expect(MusicTrackCleaner.cutPrimary(", B", strict: false) == ", B")
        // After a title split the artist is a plain string and the comma always cuts.
        var split = ScrobbleCleanSettings(); split.splitVideoTitles = true; split.primaryArtist = true
        #expect(MusicTrackCleaner.clean(info("A, B - Song", ["Chan"], video: true), split).artist == "A")
    }

    @Test func plainRulesReplaceEveryMatchCaseInsensitively() {
        var s = ScrobbleCleanSettings()
        s.rules = [rule(.title, "live", "studio")]
        let r = MusicTrackCleaner.clean(info("Live and LIVE", ["A"]), s)
        #expect(r.title == "studio and studio" && r.rulesApplied == [0])
        s.rules = [rule(.title, "(?-i)live", "x")]
        #expect(MusicTrackCleaner.clean(info("Live", ["A"]), s).rulesApplied.isEmpty)
    }

    @Test func replacementSyntaxSupportsNumberedAndNamedGroups() {
        var s = ScrobbleCleanSettings()
        s.rules = [rule(.title, #"^(?<a>\w+) (\w+)$"#, "$2 ${a} $$ ${1}")]
        #expect(MusicTrackCleaner.clean(info("one two", ["A"]), s).title == "two one $ one")
    }

    @Test func extractionRuleWritesNamedGroupsAndIgnoresReplacement() {
        var s = ScrobbleCleanSettings()
        s.rules = [rule(.title, #"^(?<artist>.+?) - (?<title>.+)$"#, "ignored")]
        let r = MusicTrackCleaner.clean(info("Nova - Higher", ["Chan"]), s)
        #expect(r.artist == "Nova" && r.title == "Higher" && r.rulesApplied == [0])
        let none = MusicTrackCleaner.clean(info("NoDashHere", ["Chan"]), s)
        #expect(none.title == "NoDashHere" && none.rulesApplied.isEmpty)
    }

    @Test func badPatternIsReportedAndOthersStillRun() {
        var s = ScrobbleCleanSettings()
        s.rules = [rule(.title, "(unclosed"), ScrobbleRule(enabled: false, field: .title, find: "x"), rule(.title, "Song", "Fixed")]
        let r = MusicTrackCleaner.clean(info("Song", ["A"]), s)
        #expect(r.ruleErrors.map(\.index) == [0] && r.title == "Fixed" && r.rulesApplied == [2])
    }

    @Test func rulesRunInOrderAndSeeEarlierResults() {
        var s = ScrobbleCleanSettings()
        s.rules = [rule(.title, "a", "b"), rule(.title, "b", "c")]
        #expect(MusicTrackCleaner.clean(info("a", ["A"]), s).title == "c")
    }

    @Test func splitRunsBeforeRules() {
        var s = ScrobbleCleanSettings(); s.splitVideoTitles = true
        s.rules = [rule(.title, #"\s*\(Official Video\)"#)]
        let r = MusicTrackCleaner.clean(info("Nova Sky - Higher Ground (Official Video)", ["NovaSkyVEVO"], video: true), s)
        #expect(r.artist == "Nova Sky" && r.title == "Higher Ground")
    }

    @Test func presets() {
        func run(_ name: String, _ title: String = "", _ artist: String = "") -> CleanedTrack {
            let p = MusicTrackCleaner.presets.first { $0.name.contains(name) }
            var s = ScrobbleCleanSettings(); s.rules = p.map { [$0.rule] } ?? []
            return MusicTrackCleaner.clean(info(title, [artist.isEmpty ? "A" : artist]), s)
        }
        #expect(MusicTrackCleaner.presets.count == 5)
        #expect(run("Official Video", "Song (Official Video)").title == "Song")
        #expect(run("Official Video", "Song [Lyrics]").title == "Song")
        #expect(run("Official Video", "Song (Official Music Video)").title == "Song")
        #expect(run("Official Video", "Song (4K)").title == "Song")
        #expect(run("Official Video", "Song (Live)").title == "Song (Live)")
        #expect(run("Remastered", "Song - 2011 Remaster").title == "Song")
        #expect(run("Remastered", "Song (Remastered 2011) [Live]").title == "Song [Live]")
        #expect(run("Remastered", "Song").title == "Song")
        #expect(run("Explicit", "Song (Explicit)").title == "Song")
        #expect(run("Explicit", "Song - Clean Version").title == "Song")
        #expect(run("Explicit", "Song [Edited]").title == "Song [Edited]")
        #expect(run("Topic", "S", "Artist - Topic").artist == "Artist")
        #expect(run("VEVO", "S", "NovaSkyVEVO").artist == "NovaSky")
    }

    @Test func incompleteTracksAreSkipped() {
        #expect(MusicTrackCleaner.clean(info("", ["A"]), ScrobbleCleanSettings()).skip == .incomplete)
        #expect(MusicTrackCleaner.clean(info("S", []), ScrobbleCleanSettings()).skip == .incomplete)
        #expect(MusicTrackCleaner.clean(info("S", ["Unknown artist"]), ScrobbleCleanSettings()).skip == .incomplete)
        var s = ScrobbleCleanSettings(); s.rules = [rule(.title, ".*")]
        #expect(MusicTrackCleaner.clean(info("S", ["A"]), s).skip == .incomplete)
    }
}

// MARK: thresholds, config, preview

@Suite struct ScrobbleThresholdTests {
    let cfg = MusicScrobbleConfig()

    @Test func defaultsAndFloor() {
        #expect(cfg.percent == 50 && cfg.minutes == 4 && cfg.nowPlaying)
        #expect(ScrobbleThreshold.firePoint(durationSeconds: 200, config: cfg) == 100)
        #expect(ScrobbleThreshold.firePoint(durationSeconds: 900, config: cfg) == 240)
        #expect(ScrobbleThreshold.firePoint(durationSeconds: 40, config: cfg) == 30)
        #expect(ScrobbleThreshold.firePoint(durationSeconds: 25, config: cfg) == nil)
        #expect(ScrobbleThreshold.isTooShort(durationSeconds: 25) && !ScrobbleThreshold.isTooShort(durationSeconds: nil))
    }

    @Test func unknownLengthAndCapOff() {
        #expect(ScrobbleThreshold.firePoint(durationSeconds: nil, config: cfg) == 240)
        var c = cfg; c.minutes = 0
        #expect(ScrobbleThreshold.firePoint(durationSeconds: nil, config: c) == nil)
        #expect(ScrobbleThreshold.firePoint(durationSeconds: 900, config: c) == 450)
        c.percent = 1000
        #expect(c.clampedPercent == 100)
    }

    @Test func stricterOfTheTwoRulesWins() {
        var c = cfg; c.minutes = 2                       // configured cap 120 s, The stricter 180 s is stricter
        #expect(ScrobbleThreshold.firePoint(durationSeconds: 900, config: c) == 180)
        c.percent = 30                                   // a deliberately low percent switches the extra rule off
        #expect(ScrobbleThreshold.firePoint(durationSeconds: 200, config: c) == 60)
        #expect(ScrobbleThreshold.firePoint(durationSeconds: nil, config: cfg) == 240)
    }

    @Test func oldStaticRuleStillHolds() {
        #expect(MusicScrobbler.shouldScrobble(playedMs: 100_000, durationMs: 200_000))
        #expect(!MusicScrobbler.shouldScrobble(playedMs: 99_000, durationMs: 200_000))
        #expect(!MusicScrobbler.shouldScrobble(playedMs: 29_000, durationMs: 40_000))
        #expect(MusicScrobbler.shouldScrobble(playedMs: 30_000, durationMs: 50_000))
    }

    @Test func configDecodesWithMissingFieldsAndGarbage() throws {
        let c = MusicScrobbleConfig.decode(Data(#"{"percent":70}"#.utf8))
        #expect(c.percent == 70 && c.minutes == 4 && c.nowPlaying && c.clean.rules.isEmpty)
        #expect(MusicScrobbleConfig.decode(Data("nonsense".utf8)) == MusicScrobbleConfig())
        #expect(MusicScrobbleConfig.decode(nil) == MusicScrobbleConfig())
        var d = MusicScrobbleConfig(); d.clean.rules = [rule(.title, "x")]; d.serviceEnabled["lastfm"] = false
        let back = MusicScrobbleConfig.decode(try JSONEncoder().encode(d))
        #expect(back == d && !back.isServiceEnabled("lastfm") && back.isServiceEnabled("other"))
    }

    @Test func clockText() {
        #expect(ScrobbleThreshold.clock(100) == "1:40" && ScrobbleThreshold.clock(240) == "4:00" && ScrobbleThreshold.clock(5) == "0:05")
    }
}

@Suite struct ScrobblePreviewTests {
    let on = [ScrobbleServiceState(id: "lastfm", name: "Last.fm", connected: true, enabled: true)]
    let song = info("Song (Official Video)", ["Artist"], album: "Al")

    @Test func statusLinesFollowTheSpecOrder() {
        var cfg = MusicScrobbleConfig()
        #expect(ScrobblePreviewBuilder.build(info: song, config: cfg, masterOn: true, services: []).statusLine == "No scrobbling service is connected, so nothing is sent.")
        #expect(ScrobblePreviewBuilder.build(info: song, config: cfg, masterOn: false, services: on).statusLine == "Scrobbling is off.")
        #expect(ScrobblePreviewBuilder.build(info: song, config: cfg, masterOn: true, services: on).statusLine == "Scrobbles at 1:40.")
        let live = ScrobbleLiveState(positionSeconds: 120, durationSeconds: 200)
        #expect(ScrobblePreviewBuilder.build(info: song, config: cfg, masterOn: true, services: on, live: live).statusLine == "Scrobbled at 1:40.")
        let short = ScrobbleLiveState(positionSeconds: 1, durationSeconds: 20)
        #expect(ScrobblePreviewBuilder.build(info: song, config: cfg, masterOn: true, services: on, live: short).statusLine == "Too short to scrobble.")
        cfg.clean.edits = [ScrobbleEdit(key: "x:1", skip: true)]
        #expect(ScrobblePreviewBuilder.build(info: song, config: cfg, masterOn: true, services: on).statusLine == "Your edit turns this track off.")
        cfg.clean.edits = []
        #expect(ScrobblePreviewBuilder.build(info: info("S", []), config: cfg, masterOn: true, services: on).statusLine == "Nothing is sent: no title or artist is left.")
    }

    @Test func everyActiveServiceGetsTheSameCleanedTrackAndChipsListWhatChanged() {
        var cfg = MusicScrobbleConfig()
        cfg.clean.rules = [MusicTrackCleaner.presets[0].rule]
        let two = on + [ScrobbleServiceState(id: "listenbrainz", name: "ListenBrainz", connected: true, enabled: true),
                        ScrobbleServiceState(id: "off", name: "Off", connected: true, enabled: false)]
        let p = ScrobblePreviewBuilder.build(info: song, config: cfg, masterOn: true, services: two)
        #expect(p.services.map(\.id) == ["lastfm", "listenbrainz"])
        #expect(p.services.allSatisfy { $0.title == "Song" && $0.artist == "Artist" && $0.album == "Al" })
        #expect(p.chips == ["Rule 1"])
        let skipped = ScrobblePreviewBuilder.build(info: song, config: cfg, masterOn: false, services: two)
        #expect(skipped.services.allSatisfy { $0.title == nil })
    }

    @Test func sampleTrackExampleCleansUp() {
        var cfg = MusicScrobbleConfig()
        cfg.clean.splitVideoTitles = true
        cfg.clean.rules = [MusicTrackCleaner.presets[0].rule, MusicTrackCleaner.presets[4].rule]
        let p = ScrobblePreviewBuilder.build(info: ScrobblePreviewBuilder.sample, config: cfg, masterOn: true, services: on)
        #expect(p.cleaned.artist == "Nova Sky" && p.cleaned.title == "Higher Ground" && p.chips == ["Title split", "Rule 1"])
    }
}

// MARK: scrobbler during playback

@MainActor @Suite struct ScrobblerPlaybackTests {
    private func makeTrack(_ ms: Int64 = 200_000) -> MusicTrack {
        MusicTrack(id: "1", providerID: "fake", title: "Song (Official Video)", durationMs: ms, artists: [MusicArtistRef(id: "a", name: "Artist")],
                   album: MusicAlbumRef(id: "al", title: "Album"))
    }

    private func make() throws -> (MusicScrobbler, FakeScrobbleProvider) {
        let suite = UserDefaults(suiteName: "scrobble-test-" + UUID().uuidString) ?? .standard
        let reg = MusicRegistry(defaults: suite)
        let fake = FakeScrobbleProvider()
        reg.register(fake); reg.setEnabled(true, id: "fake")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scrobble-" + UUID().uuidString)
        let lib = MusicLibrary(directory: dir, debounce: .milliseconds(10))
        lib.settings.scrobbleEnabled = true
        let s = MusicScrobbler(registry: reg, library: lib, defaults: suite, now: { Date(timeIntervalSince1970: 1_000) }, sleep: { _ in })
        s.configStore.config.clean.rules = [MusicTrackCleaner.presets[0].rule]
        return (s, fake)
    }

    private func settle(_ until: () -> Bool) async {
        for _ in 0..<200 where !until() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    @Test func nowPlayingOnStartThenScrobbleAtThresholdWithStartTime() async throws {
        let (s, fake) = try make()
        let start = Date(timeIntervalSince1970: 5_000)
        s.started(makeTrack())
        await settle { !fake.nowPlayings.isEmpty }
        #expect(fake.nowPlayings.first?.title == "Song" && fake.nowPlayings.first?.artists.first?.name == "Artist")
        for i in 0...100 { s.tick(position: Double(i), duration: 200, isPlaying: true, at: start.addingTimeInterval(Double(i))) }
        await settle { !fake.scrobbles.isEmpty }
        #expect(fake.scrobbles.count == 1)
        #expect(fake.scrobbles.first?.track.title == "Song")
        #expect(fake.scrobbles.first?.timestamp == Date(timeIntervalSince1970: 1_000))   // the start time, not the moment of crossing
        for i in 101...150 { s.tick(position: Double(i), duration: 200, isPlaying: true, at: start.addingTimeInterval(Double(i))) }
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(fake.scrobbles.count == 1)   // latched once per play
    }

    @Test func seekingAheadAloneDoesNotScrobble() async throws {
        let (s, fake) = try make()
        s.started(makeTrack())
        let t = Date(timeIntervalSince1970: 5_000)
        s.tick(position: 1, duration: 200, isPlaying: true, at: t)
        s.tick(position: 150, duration: 200, isPlaying: true, at: t.addingTimeInterval(1))
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(fake.scrobbles.isEmpty)
    }

    @Test func skippedTracksSendNothing() async throws {
        let (s, fake) = try make()
        s.configStore.config.clean.edits = [ScrobbleEdit(key: "fake:1", skip: true)]
        s.started(makeTrack())
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(fake.nowPlayings.isEmpty)
    }

    @Test func serviceSwitchedOffReceivesNothing() async throws {
        let (s, fake) = try make()
        s.configStore.config.serviceEnabled["fake"] = false
        s.started(makeTrack())
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(fake.nowPlayings.isEmpty)
    }

    @Test func lateAlbumResendsNowPlayingOnly() async throws {
        let (s, fake) = try make()
        var t = makeTrack(); t.album = nil
        s.started(t)
        await settle { fake.nowPlayings.count == 1 }
        t.album = MusicAlbumRef(id: "al", title: "Album")
        s.trackUpdated(t)
        await settle { fake.nowPlayings.count == 2 }
        #expect(fake.nowPlayings.count == 2 && fake.nowPlayings.last?.album?.title == "Album" && fake.scrobbles.isEmpty)
    }

    @Test func previewMatchesWhatIsSent() throws {
        let (s, _) = try make()
        let p = s.preview(for: makeTrack())
        #expect(p.cleaned.title == "Song" && p.services.map(\.id) == ["fake"] && p.statusLine == "Scrobbles at 1:40.")
        #expect(s.preview(for: nil).original.uid == "sample")
    }
}

@Suite struct ScrobbleRetryTests {
    @Test func networkFailureRetriesTwiceThenGivesUp() async {
        let tries = Counter(), waits = Counter()
        await #expect(throws: ScrobbleSendError.network("down")) {
            try await MusicScrobbler.retrying(sleep: { _ in waits.next() }) { tries.next(); throw ScrobbleSendError.network("down") }
        }
        #expect(tries.value == 3 && waits.value == 2)
    }

    @Test func recoversOnTheSecondAttempt() async throws {
        let tries = Counter()
        try await MusicScrobbler.retrying(sleep: { _ in }) { if tries.next() < 2 { throw ScrobbleSendError.network("blip") } }
        #expect(tries.value == 2)
    }

    @Test func refusalsAreNeverRetried() async {
        let tries = Counter()
        await #expect(throws: ScrobbleSendError.refused("no")) {
            try await MusicScrobbler.retrying(sleep: { _ in }) { tries.next(); throw ScrobbleSendError.refused("no") }
        }
        #expect(tries.value == 1)
    }
}

// MARK: Last.fm

@Suite struct LastFMFlowTests {
    @Test func signatureAndPayloadShapes() {
        #expect(LastFMProvider.signature(["method": "track.scrobble", "artist": "A", "format": "json"], secret: "s")
                == LastFMProvider.md5Hex("artistAmethodtrack.scrobbles"))
        let now = LastFMClient.nowPlayingFields(artist: "A", title: "T", album: "")
        #expect(now == ["artist": "A", "track": "T"])
        #expect(LastFMClient.nowPlayingFields(artist: "A", title: "T", album: "Al")["album"] == "Al")
        let f = LastFMClient.scrobbleFields(artist: "A", title: "T", album: "Al", start: Date(timeIntervalSince1970: 42), durationMs: 215_900)
        #expect(f["timestamp"] == "42" && f["duration"] == "215" && f["album"] == "Al")
        #expect(LastFMClient.scrobbleFields(artist: "A", title: "T", album: "", start: Date(), durationMs: 0)["duration"] == nil)
        let signed = LastFMClient.signed(["artist": "A"], method: "m", apiKey: "k", secret: "s", sessionKey: "sk")
        #expect(signed["format"] == "json" && signed["sk"] == "sk" && signed["api_sig"] == LastFMProvider.signature(signed, secret: "s"))
        #expect(LastFMClient.authURL(apiKey: "K", token: "T")?.absoluteString == "https://www.last.fm/api/auth/?api_key=K&token=T")
    }

    @Test func customEndpointIsUsedForCallsAndTheApprovalPage() async throws {
        let stub = ScrobbleStub { _ in (200, #"{"scrobbles":{}}"#) }
        let client = LastFMClient(http: MusicHTTP(transport: stub), store: ScrobbleMemoryStore())
        #expect(client.endpoint.absoluteString == "https://ws.audioscrobbler.com/2.0/" && client.authorizeBase == "https://www.last.fm/api/auth/")
        #expect(!client.setEndpoint("ftp://x.org") && !client.setEndpoint("https://x.org/2.0/?a=1"))
        #expect(client.setEndpoint(" https://libre.fm/2.0/ "))
        #expect(client.endpoint.absoluteString == "https://libre.fm/2.0/" && client.authorizeBase == "https://libre.fm/api/auth/")
        client.setAppKeys(key: "k", secret: "s"); _ = client.storeSession(key: "SK", user: "me")
        try await client.nowPlaying(artist: "A", title: "T", album: "")
        #expect(stub.requests.last?.url?.host == "libre.fm")
        #expect(client.setEndpoint("  ") && client.endpoint.host == "ws.audioscrobbler.com")
    }

    @Test func scrobbleIsASignedPostWithTheCleanedValues() async throws {
        let stub = ScrobbleStub { _ in (200, #"{"scrobbles":{}}"#) }
        let store = ScrobbleMemoryStore()
        let client = LastFMClient(http: MusicHTTP(transport: stub), store: store)
        client.setAppKeys(key: "key", secret: "sec")
        #expect(client.storeSession(key: "SK", user: "me"))
        try await client.scrobble(artist: "A", title: "T", album: "", start: Date(timeIntervalSince1970: 7), durationMs: 100_000)
        let req = try #require(stub.requests.last)
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        #expect(req.httpMethod == "POST" && req.timeoutInterval == 15)
        #expect(body.contains("method=track.scrobble") && body.contains("timestamp=7") && body.contains("sk=SK") && body.contains("duration=100"))
        #expect(!body.contains("album=") && !body.contains("sec"))
    }

    @Test func errorBodiesOnFourHundredRepliesAreRead() async {
        let stub = ScrobbleStub { _ in (403, #"{"error":9,"message":"Invalid session key"}"#) }
        let store = ScrobbleMemoryStore()
        let client = LastFMClient(http: MusicHTTP(transport: stub), store: store)
        client.setAppKeys(key: "k", secret: "s"); _ = client.storeSession(key: "x", user: "u")
        await #expect(throws: ScrobbleSendError.signedOut) { try await client.nowPlaying(artist: "A", title: "T", album: "") }
    }

    @Test @MainActor func authFlowPollsThroughPendingApprovalThenStoresTheSession() async {
        let polls = Counter()
        let stub = ScrobbleStub { r in
            let q = r.url?.query ?? ""
            if q.contains("method=auth.getToken") { return (200, #"{"token":"TOK"}"#) }
            if q.contains("method=auth.getSession") {
                return polls.next() < 3 ? (403, #"{"error":14,"message":"Unauthorized Token"}"#) : (200, #"{"session":{"name":"me","key":"SK"}}"#)
            }
            return (200, "{}")
        }
        let store = ScrobbleMemoryStore()
        let client = LastFMClient(http: MusicHTTP(transport: stub), store: store)
        client.setAppKeys(key: "key", secret: "sec")
        let slept = Counter()
        let flow = LastFMAuthFlow(client: client, sleep: { _ in slept.next() })
        var opened: URL?
        flow.openURL = { opened = $0 }
        await flow.connect()
        #expect(flow.state == .connected("me") && polls.value == 3 && slept.value == 3)
        #expect(opened?.absoluteString == "https://www.last.fm/api/auth/?api_key=key&token=TOK")
        #expect(client.credentials()?.sessionKey == "SK" && client.username == "me")
        flow.disconnect()
        #expect(flow.state == .idle && client.credentials() == nil && client.username == nil)
    }

    @Test @MainActor func authFlowStopsOnOtherErrorsAndTimesOut() async {
        let fatal = ScrobbleStub { r in
            (r.url?.query ?? "").contains("getToken") ? (200, #"{"token":"T"}"#) : (200, #"{"error":10,"message":"Invalid API key"}"#)
        }
        let c1 = LastFMClient(http: MusicHTTP(transport: fatal), store: ScrobbleMemoryStore()); c1.setAppKeys(key: "k", secret: "s")
        let f1 = LastFMAuthFlow(client: c1, sleep: { _ in })
        await f1.connect()
        #expect(f1.state == .failed("Last.fm: Invalid API key"))

        let waiting = ScrobbleStub { r in
            (r.url?.query ?? "").contains("getToken") ? (200, #"{"token":"T"}"#) : (200, #"{"error":14,"message":"pending"}"#)
        }
        let c2 = LastFMClient(http: MusicHTTP(transport: waiting), store: ScrobbleMemoryStore()); c2.setAppKeys(key: "k", secret: "s")
        let slept = Counter()
        let f2 = LastFMAuthFlow(client: c2, sleep: { _ in slept.next() })
        await f2.connect()
        #expect(f2.state == .failed("Last.fm authorization timed out - try again") && slept.value == 60)

        let f3 = LastFMAuthFlow(client: LastFMClient(http: MusicHTTP(transport: waiting), store: ScrobbleMemoryStore()), sleep: { _ in })
        await f3.connect()
        #expect(f3.state == .failed("Enter your Last.fm API key and secret first."))
    }

    @Test @MainActor func cancellingBumpsTheGenerationSoAStalePollExits() async {
        let stub = ScrobbleStub { r in
            (r.url?.query ?? "").contains("getToken") ? (200, #"{"token":"T"}"#) : (200, #"{"session":{"name":"late","key":"K"}}"#)
        }
        let client = LastFMClient(http: MusicHTTP(transport: stub), store: ScrobbleMemoryStore()); client.setAppKeys(key: "k", secret: "s")
        let box = FlowBox()
        let flow = LastFMAuthFlow(client: client, sleep: { _ in await box.cancel() })
        box.flow = flow
        await flow.connect()
        #expect(flow.state == .idle && client.credentials() == nil)
    }
}

@MainActor private final class FlowBox {
    var flow: LastFMAuthFlow?
    func cancel() { flow?.cancel() }
}

// MARK: ListenBrainz

@Suite struct ListenBrainzFlowTests {
    @Test func serverAddressRules() throws {
        func root(_ s: String) -> String? { if case .success(let u) = ListenBrainzClient.normalizedRoot(s) { return u.absoluteString }; return nil }
        #expect(root("") == "https://api.listenbrainz.org")
        #expect(root("  https://lb.example.com/// ") == "https://lb.example.com")
        #expect(root("http://localhost:8100/lb/") == "http://localhost:8100/lb")
        #expect(root("/") == nil && root("ftp://x.org") == nil && root("https://x.org?a=1") == nil && root("https://x.org#f") == nil && root("nonsense") == nil)
        if case .failure(let e) = ListenBrainzClient.normalizedRoot("/") { #expect(e.message == "server URL must be http(s)://host[/path], without ? or #") }
    }

    @Test func payloadShapes() throws {
        let t = ScrobblePayloadTrack(artist: "A", title: "T", album: "Al", durationMs: 200_000, isrc: "ISRC1", originURL: "https://music.example/watch?v=1")
        let now = try #require(try JSONSerialization.jsonObject(with: ListenBrainzClient.payload(listenType: "playing_now", t, listenedAt: nil, version: "2.0")) as? [String: Any])
        #expect(now["listen_type"] as? String == "playing_now")
        let listen = try #require((now["payload"] as? [[String: Any]])?.first)
        #expect(listen["listened_at"] == nil)
        let meta = try #require(listen["track_metadata"] as? [String: Any])
        #expect(meta["artist_name"] as? String == "A" && meta["track_name"] as? String == "T" && meta["release_name"] as? String == "Al")
        let extra = try #require(meta["additional_info"] as? [String: Any])
        #expect(extra["submission_client"] as? String == "StreamSetu" && extra["submission_client_version"] as? String == "2.0")
        #expect(extra["duration_ms"] as? Int == 200_000 && extra["music_service"] as? String == "music.example" && extra["origin_url"] as? String == "https://music.example/watch?v=1")

        let local = ScrobblePayloadTrack(artist: "A", title: "T", album: "", durationMs: 0, isrc: nil, originURL: nil)
        let single = try #require(try JSONSerialization.jsonObject(with: ListenBrainzClient.payload(listenType: "single", local, listenedAt: Date(timeIntervalSince1970: 99), version: "1")) as? [String: Any])
        let l2 = try #require((single["payload"] as? [[String: Any]])?.first)
        #expect(l2["listened_at"] as? Int == 99)
        let m2 = try #require(l2["track_metadata"] as? [String: Any])
        let e2 = try #require(m2["additional_info"] as? [String: Any])
        #expect(m2["release_name"] == nil && e2["origin_url"] == nil && e2["music_service"] == nil && e2["duration_ms"] == nil)
    }

    @Test func validationStatesStoreNothingOnError() async throws {
        let store = ScrobbleMemoryStore()
        let bad = ScrobbleStub { _ in (200, #"{"valid":false,"message":"Invalid access token."}"#) }
        let c1 = ListenBrainzClient(http: MusicHTTP(transport: bad), store: store)
        await #expect(throws: ScrobbleSendError.refused("Invalid access token.")) { try await c1.connect(token: "t", server: "") }
        let proxy401 = ScrobbleStub { _ in (401, #"{"valid":false,"message":"Nope"}"#) }
        await #expect(throws: ScrobbleSendError.refused("Nope")) { try await ListenBrainzClient(http: MusicHTTP(transport: proxy401), store: store).connect(token: "t", server: "") }
        let html = ScrobbleStub { _ in (200, "<html>hi</html>") }
        await #expect(throws: ScrobbleSendError.refused("no ListenBrainz API answered at https://lb.example.com (is this the API address?)")) {
            try await ListenBrainzClient(http: MusicHTTP(transport: html), store: store).connect(token: "t", server: "https://lb.example.com/")
        }
        let noUser = ScrobbleStub { _ in (200, #"{"valid":true}"#) }
        await #expect(throws: ScrobbleSendError.self) { try await ListenBrainzClient(http: MusicHTTP(transport: noUser), store: store).connect(token: "t", server: "") }
        let server500 = ScrobbleStub { _ in (500, #"{"x":1}"#) }
        await #expect(throws: ScrobbleSendError.self) { try await ListenBrainzClient(http: MusicHTTP(transport: server500), store: store).connect(token: "t", server: "") }
        #expect(store.read(ListenBrainzClient.tokenAccount) == nil)

        let good = ScrobbleStub { r in
            (200, r.value(forHTTPHeaderField: "Authorization") == "Token good" ? #"{"valid":true,"user_name":"me"}"# : #"{"valid":false,"message":"bad"}"#)
        }
        let c = ListenBrainzClient(http: MusicHTTP(transport: good), store: store)
        #expect(try await c.connect(token: " good ", server: "https://lb.example.com/") == "me")
        #expect(c.token == "good" && c.username == "me" && c.root.absoluteString == "https://lb.example.com")
        #expect(good.requests.first?.url?.absoluteString == "https://lb.example.com/1/validate-token")
        #expect(c.profileURL(user: "me")?.absoluteString == "https://lb.example.com/user/me/")
        c.disconnect()
        #expect(!c.isConnected && c.username == nil)
    }

    @Test func refusalStatesOnSubmit() async throws {
        let store = ScrobbleMemoryStore(); store.write("tok", account: ListenBrainzClient.tokenAccount)
        let t = ScrobblePayloadTrack(artist: "A", title: "T", album: "", durationMs: 0, isrc: nil, originURL: nil)
        func client(_ code: Int, _ body: String) -> ListenBrainzClient { ListenBrainzClient(http: MusicHTTP(transport: ScrobbleStub { _ in (code, body) }), store: store) }
        await #expect(throws: ScrobbleSendError.listenBrainz(.email)) { try await client(401, #"{"error":"You must have a verified email address"}"#).playingNow(t) }
        await #expect(throws: ScrobbleSendError.listenBrainz(.rejected)) { try await client(401, #"{"error":"Invalid authorization token."}"#).listen(t, start: Date()) }
        await #expect(throws: ScrobbleSendError.network("ListenBrainz answered HTTP 503")) { try await client(503, "").playingNow(t) }
        await #expect(throws: ScrobbleSendError.refused("ListenBrainz answered HTTP 400")) { try await client(400, "").playingNow(t) }
        try await client(200, #"{"status":"ok"}"#).listen(t, start: Date())
        #expect(ListenBrainzClient.classify401(body: Data("Verified Email needed".utf8)) == .email)
        #expect(ListenBrainzProblem.email.message.hasPrefix("Verify your MetaBrainz email") && ListenBrainzProblem.rejected.message.hasPrefix("ListenBrainz no longer"))
    }
}
