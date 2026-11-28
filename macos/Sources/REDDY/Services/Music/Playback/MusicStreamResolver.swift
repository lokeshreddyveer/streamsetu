import Foundation

/// Turns a track into one playable stream. A track that already carries streams (Audius, JioSaavn) uses them; any other track is matched against
/// the enabled audio providers in the person's order, best candidate first, until one yields a stream that fits the quality setting.
@MainActor
final class MusicStreamResolver {
    /// Candidates scoring below this are probably a different song and are never tried.
    nonisolated static let minimumScore: Float = 0.35
    nonisolated static let defaultLifetime: TimeInterval = 20 * 60
    /// How many top candidates one provider gets before the next provider is asked.
    nonisolated static let candidatesPerProvider = 4
    /// A provider that does not answer in this long counts as failed, so a dead public server never holds up a working one behind it.
    nonisolated static let maxNotesOnSuccess = 6
    nonisolated static let providerDeadline: TimeInterval = 8
    /// Stream lookups (the YouTube extractor chain is the slow one) get a longer allowance than a search; the race caps the whole resolve.
    nonisolated static let streamDeadline: TimeInterval = 120
    /// Providers whose resolve may legitimately run past the normal 20 second race cap when nothing else answered.
    nonisolated static let patientProviders: Set<String> = ["youtube-music", "youtube", "ytmusic"]

    /// Runs `work` and gives up after `seconds`. It is a race: the caller gets the first answer (or the timeout) at once and does not wait for the loser, which is cancelled. A group of
    /// child tasks would wait for a slow request to finish even after the deadline, because some requests do not react to cancellation.
    nonisolated static func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let race = DeadlineRace<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                race.start(cont)
                let w = Task { do { race.finish(.success(try await work())) } catch { race.finish(.failure(error)) } }
                let t = Task { try? await Task.sleep(nanoseconds: UInt64(max(0.01, seconds.isFinite ? seconds : 0.01) * 1_000_000_000)); race.finish(.failure(MusicError.network("timed out"))) }
                race.attach(w, t)
            }
        } onCancel: { race.finish(.failure(CancellationError())) }
    }

    private struct Cached { var stream: MusicStream; var expires: Date }

    private let registry: MusicRegistry
    private let now: () -> Date
    /// The person's own choice of recording for a song; when it fails, automatic matching takes over.
    var matchOverrides: MusicMatchOverrides?
    /// The ordered audio chain (added addons plus the other audio providers). Nil, or no addon added, means the plain loop below is used.
    var chain: MusicSourceChain?
    private var cache: [String: Cached] = [:]
    /// Running lookups by track and quality. Cancelling the last caller waiting for one cancels the lookup itself (see `MusicFlightBoard`).
    private let flights = MusicFlightBoard<MusicStream>()
    /// Which tracks the uid-keyed maps below (`pages`, `served`, `servedProvider`, `cachedServes`) hold, newest last; bounded.
    private var uidRecency = MusicRecency()
    private static let uidMapLimit = 200
    /// Where the chosen recording lives (a YouTube page, for example); SponsorBlock needs the video id from it.
    private var pages: [String: String] = [:]
    /// Which chain member served a track, so a better copy is asked from the others only.
    private var served: [String: String] = [:]
    /// Which audio provider's stream a track last got, so a stream that fails to open counts against that provider.
    private var servedProvider: [String: String] = [:]
    /// Stream addresses that were handed out and then failed to open; they are not offered again until they age out (bounded, ten minutes).
    private let bad: MusicBadAddresses
    /// The name of the provider whose stream this track last got.
    func servedProviderName(for t: MusicTrack) -> String? { (servedProvider[t.uid] ?? (t.directStreams != nil ? t.providerID : nil)).map(providerName) }

    /// True when the track's last stream was served from the result cache.
    func wasServedFromCache(_ t: MusicTrack) -> Bool { cachedServes.contains(t.uid) }

    /// Why the last late check refused an address, for the failure log.
    private var lateReasons: [String: String] = [:]
    /// Addresses handed out again only because nothing else was left (a bad address checked once more); a repeat lookup does not refuse them.
    private var lastResortURLs: Set<String> = []
    /// Tracks whose last stream came out of the result cache (for the failure log).
    private var cachedServes: Set<String> = []
    /// Providers that failed lately are asked last.
    let health = MusicProviderHealth()
    /// Verdicts, resting clients and failed addresses. The app shares one memory between the resolver, the YouTube extractor and the player.
    var unplayable: MusicUnplayableMemory = .shared
    /// Where a failed resolve leaves its plain reason. Optional so tests can run without it.
    var log: MusicPlaybackLog?
    /// Reads ranged bytes to prove a stream opens, is audio, serves the middle of the file and is as long as the song. Nil turns the check off
    /// (offline tests); the app uses the real reader.
    var verifier: MusicStreamVerifier.Reader? = MusicStreamResolver.defaultVerifier
    var raceConfig = MusicRace.Config()
    var raceSleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    /// Tracks whose chain (addon) stream failed: the plain provider walk serves them next.
    private var chainBypass: Set<String> = []

    nonisolated static var defaultVerifier: MusicStreamVerifier.Reader? {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil || NSClassFromString("XCTestCase") != nil { return nil }
        return MusicStreamVerifier.live
    }

    init(registry: MusicRegistry, now: @escaping () -> Date = { Date() }) {
        self.registry = registry
        self.now = now
        self.bad = MusicBadAddresses(now: now)
        MusicStreamProof.shared.setLateRejectionHandler { [weak self] url, reason in
            Task { @MainActor in self?.lateRejected(url: url, reason: reason) }
        }
    }

    /// Called after a song has started when the rest of its stream check fails: the address is dropped, the failure is counted and logged, and
    /// the player is told so it can carry on from another address at the same position.
    var onLateRejection: ((MusicTrack, MusicStream) -> Void)?
    private var servedByURL: [String: (track: MusicTrack, stream: MusicStream)] = [:]
    private var servedOrder: [String] = []

    private func lateRejected(url: String, reason: String) {
        bad.insert(url)
        if let h = MusicStreamProof.shared.lateHypothesis(for: url) {
            lateReasons[url] = h
            if lateReasons.count > 16 { lateReasons = [url: h] }
        }
        guard let hit = servedByURL.removeValue(forKey: url) else { return }
        reportFailure(hit.track, stream: hit.stream, reason: reason)
        onLateRejection?(hit.track, hit.stream)
    }

    // MARK: public

    /// `wantsVideo` is true only when the person turned music-video mode on and the track is a video; then a stream that carries a picture is preferred.
    func resolve(_ t: MusicTrack, quality: MusicQuality, wantsVideo: Bool = false) async throws -> MusicStream {
        let key = Self.key(t, quality, video: wantsVideo)
        if let c = cache[key] {
            // A copy is used only while it is inside its lifetime, its signed address has not (nearly) run out and the address never failed.
            if c.expires > now(), MusicStreamExpiry.isUsable(c.stream, now: now()), !bad.contains(c.stream.url) {
                MusicStartTimeline.shared.mark(t.uid, .resolved); MusicStartTimeline.shared.tag(t.uid, "cached stream")
                cachedServes.insert(t.uid); if cachedServes.count > 64 { cachedServes = [t.uid] }
                return c.stream
            }
            cache[key] = nil
        }
        // A lookup that was already running when an address failed may still land with that address: it is never handed out, the lookup is redone once.
        for attempt in 0..<2 {
            let stream = try await flights.value(key: key) { Task { try await self.perform(t, quality: quality, key: key, wantsVideo: wantsVideo) } }
            if attempt == 0, let twin = await lengthTwinStream(for: t, stream: stream, quality: quality, wantsVideo: wantsVideo, key: key) { return twin }
            if !bad.contains(stream.url) || lastResortURLs.contains(stream.url) || attempt == 1 { return stream }
            if cache[key]?.stream.url == stream.url { cache[key] = nil }
            flights.forgetKey(key)
        }
        throw MusicError.noPlayableSource(t.title)
    }

    /// Forgets what is known about a track, so the next resolve asks the providers again (a signed link stopped working).
    func invalidate(_ t: MusicTrack) {
        let prefix = t.uid + "|"
        for k in cache.keys where k.hasPrefix(prefix) { cache[k] = nil }
    }

    /// The stream a track was given would not open: forget it, remember it as bad and count the failure against its provider, so the next
    /// resolve tries another candidate before anything is skipped.
    func reportFailure(_ t: MusicTrack, stream: MusicStream?, reason: String) {
        evict(t, stream: stream)
        if let stream {
            // A YouTube address that failed in playback is not served again from the provider's own cache either, and its client rests for this
            // video for a couple of minutes, so the retry gets a fresh address from another client instead of "no playable source".
            if let u = URL(string: stream.url), MusicProxyPolicy.isGoogleVideo(u), let c = MusicProxyPolicy.client(of: u) {
                unplayable.exclude(client: c, videoID: t.videoID ?? t.id)
            }
        }
        if served[t.uid] != nil { chainBypass.insert(t.uid); served[t.uid] = nil }
        let provider = servedProvider[t.uid] ?? (t.directStreams != nil ? t.providerID : nil)
        if let provider { health.recordFailure(provider) }
        log?.record(track: t.title, provider: provider.map(providerName), reason: reason)
        invalidate(t)
    }

    /// Drops every copy of a failed address without passing any verdict on the song or its provider: the result cache (this row and any other
    /// row holding the same address), the proof of the address, the provider's own cached answer and the bad-address memory. Used for a
    /// lookahead that failed before it was ever played, and as the first step of `reportFailure`. A later resolve is a fresh one.
    func evict(_ t: MusicTrack, stream: MusicStream?) {
        if let stream {
            bad.insert(stream.url)
            MusicStreamProof.shared.forget(stream.url)
            unplayable.markBadURL(stream.url, videoID: t.videoID ?? t.id)
            servedByURL[stream.url] = nil
            for (k, c) in cache where c.stream.url == stream.url { cache[k] = nil }
        }
        invalidate(t)
        evictProviderCopies(of: t)
    }

    /// Providers that keep their own stream cache are told to drop the recording (fire and forget; the lookup path checks the bad-address memory too).
    private func evictProviderCopies(of t: MusicTrack) {
        let sourceID = t.videoID ?? t.id
        for p in registry.audio {
            guard let e = p as? any MusicStreamEvicting else { continue }
            let source = MusicAudioSource(id: sourceID, providerID: p.id, title: t.title, artist: nil, durationMs: nil, confidence: 1)
            Task { await e.evictStreams(for: source) }
        }
        if let chain { Task { await chain.clearAddonAnswers() } }
    }

    /// The song played for a few seconds: what was held against it is wrong or over. Provider failures, parked clients, an old verdict, the
    /// chain bypass and the playback marker all go. The addresses that failed stay on their own clock.
    func noteSuccess(_ t: MusicTrack) {
        if let p = servedProvider[t.uid] { health.recordSuccess(p) }
        unplayable.noteSuccess(videoID: t.videoID ?? t.id)
        chainBypass.remove(t.uid)
    }

    /// The person pressed play again or asked to search again: everything negative about this song is forgotten.
    func forgive(_ t: MusicTrack) {
        unplayable.forgive(videoID: t.videoID ?? t.id)
        chainBypass.remove(t.uid)
        invalidate(t)
    }

    /// The network changed or the app came back to the front: no failure memory is carried over (providers, addresses, parked clients, verdicts).
    func resetNegativeState() {
        bad.removeAll()
        health.reset()
        chainBypass = []
        unplayable.resetAll()
        chain?.failures.reset()
    }

    /// Why the last late check refused this address (client capped, or the address ran out), if it said.
    func lateReason(for url: String) -> String? { lateReasons[url] }

    /// True when this address failed lately (a swap to a better copy must not pick it again).
    func isKnownBad(_ url: String) -> Bool { bad.contains(url) }

    /// How many bad addresses are remembered (for tests of the bound).
    var badAddressCount: Int { bad.count }

    /// Stops a resolve that is still running (the person skipped).
    func cancel(_ t: MusicTrack) {
        let prefix = t.uid + "|"
        flights.cancelAll(prefix: prefix)
    }

    /// The web page of the recording last resolved for this track, if the provider gave one.
    func pageURL(for t: MusicTrack) -> String? { pages[t.uid] ?? t.externalURL }

    /// The chain member that served this track, if one did.
    func servedBy(_ t: MusicTrack) -> String? { served[t.uid] }

    // MARK: scoring and choosing (pure)

    /// Text and duration similarity (70 percent) combined with the provider's own confidence (30 percent).
    nonisolated static func score(track: MusicTrack, candidate: MusicAudioSource) -> Float {
        let text = MusicTextMatch.score(trackTitle: track.title, artists: track.artists.map(\.name), durationMs: track.durationMs,
                                        candidateTitle: candidate.title, candidateArtist: candidate.artist, candidateDurationMs: candidate.durationMs)
        let own = min(1, max(0, candidate.confidence))
        return min(1, max(0, text * 0.7 + own * 0.3))
    }

    /// The stream that suits the quality setting: low up to 96 kbps, medium up to 160, high up to 320; lossless prefers a lossless one.
    /// When nothing is at or under the ceiling, the lightest stream is used. DASH is skipped because AVPlayer cannot play it.
    /// A stream with a picture (`hasVideo == true`) is chosen only when `wantsVideo` is set; otherwise sound-only streams win whenever one exists.
    nonisolated static func pick(from streams: [MusicStream], quality: MusicQuality, now: Date = Date(), wantsVideo: Bool = false, opusAvailable: Bool = MusicOpusRouting.isAvailable) -> MusicStream? {
        var usable = streams.filter { $0.proto != .dash && isPlayable(container: $0.container, codec: $0.codec, opusAvailable: opusAvailable) && URL(string: $0.url) != nil && MusicStreamExpiry.isUsable($0, now: now) }
        guard !usable.isEmpty else { return nil }
        let withPicture = usable.filter { $0.hasVideo == true }
        let soundOnly = usable.filter { $0.hasVideo != true }
        if wantsVideo, !withPicture.isEmpty { usable = withPicture }
        else if !wantsVideo, !soundOnly.isEmpty { usable = soundOnly }
        // WebM and Ogg Opus play through the second backend, which is a little costlier: they are used only when nothing else is left.
        let native = usable.filter { !MusicOpusRouting.declaresOpusContainer($0) }
        if !native.isEmpty { usable = native }
        func kbps(_ s: MusicStream) -> Int { s.isLossless ? 10_000 : (s.bitrate ?? 128) }
        func rank(_ s: MusicStream) -> (Int, Int) { (kbps(s), s.proto == .progressive ? 1 : 0) }
        func better(_ a: MusicStream, _ b: MusicStream) -> Bool { rank(a) < rank(b) }

        if quality == .lossless, let l = usable.filter(\.isLossless).max(by: { ($0.sampleRate ?? 0) < ($1.sampleRate ?? 0) }) { return l }
        let ceiling: Int
        switch quality {
        case .low: ceiling = 96
        case .medium: ceiling = 160
        case .high, .lossless: ceiling = 320
        }
        let within = usable.filter { !$0.isLossless && kbps($0) <= ceiling }
        if let best = within.max(by: better) { return best }
        return usable.min(by: better)
    }

    /// AVPlayer cannot open WebM, Ogg or raw Opus (it fails with "Cannot Open"). Opus in those containers is playable through the Opus
    /// backend when this system has a decoder for it; Vorbis and other codecs in them are not playable at all.
    nonisolated static func isPlayable(container: String, codec: String, opusAvailable: Bool = MusicOpusRouting.isAvailable) -> Bool {
        let c = container.lowercased(), k = codec.lowercased()
        if ["webm", "ogg", "oga", "opus", "mkv", "weba"].contains(c) { return opusAvailable && (k == "opus" || k.isEmpty) }
        return !(k == "opus" || k == "vorbis") || c == "mp4" || c == "m4a" || c == "caf"
    }

    // MARK: private

    private static func key(_ t: MusicTrack, _ q: MusicQuality, video: Bool = false) -> String { t.uid + "|" + q.rawValue + (video ? "|video" : "") }

    /// Official audio twins found for music-video rows, by video (a failed search is not remembered).
    private var officialAudio: [String: MusicTrack] = [:]

    /// A music video that is wanted as sound plays as its official audio when one is known or found.
    private func audioTwin(of t: MusicTrack, wantsVideo: Bool) async -> MusicTrack {
        guard !wantsVideo, t.isVideo == true else { return t }
        if let c = MusicOfficialAudio.counterpart(of: t) { return c }
        if let known = officialAudio[t.uid] { return known }
        guard let provider = registry.provider(id: t.providerID) as? any MusicMetadataProvider, registry.isEnabled(t.providerID) else { return t }
        let q = MusicOfficialAudio.query(for: t)
        let found = try? await Self.withDeadline(Self.providerDeadline) { try await provider.searchTracks(q, page: nil).items }
        if let found, var twin = MusicOfficialAudio.choose(for: t, among: found) {
            twin.counterpartVideoID = t.videoID ?? t.id
            officialAudio[t.uid] = twin
            return twin
        }
        return t
    }

    /// Tracks whose stream length was compared with the catalogue (once each), so a twin that is also off cannot send the lookup round again.
    private var lengthChecked: Set<String> = []

    /// A stream whose own length (the `dur` in its address) is far from the catalogue length is another cut of the recording (a long music
    /// video, a preview). The audio twin is tried, and used when its length fits; with no better version the stream is kept and the player trims it.
    private func lengthTwinStream(for t: MusicTrack, stream: MusicStream, quality: MusicQuality, wantsVideo: Bool, key: String) async -> MusicStream? {
        guard !wantsVideo, t.isPodcast != true, t.durationMs > 0,
              MusicLengthGate.needsTwin(listed: t.duration, videoDeclared: MusicStreamLength.declaredSeconds(of: stream)),
              lengthChecked.insert(t.uid).inserted else { return nil }
        if lengthChecked.count > 200 { lengthChecked = [t.uid] }
        let twin = await audioTwin(of: t, wantsVideo: false)
        guard twin.uid != t.uid, lengthChecked.insert(twin.uid).inserted,
              let twinStream = try? await resolve(twin, quality: quality) else { return nil }
        guard MusicLengthGate.choose(listed: t.duration, videoDeclared: MusicStreamLength.declaredSeconds(of: stream),
                                     twinDeclared: MusicStreamLength.declaredSeconds(of: twinStream)) == .useTwin else { return nil }
        log?.record(track: t.title, provider: providerName(twin.providerID), reason: "Video is longer than the song; its audio version plays instead")
        return remember(twinStream, for: t, page: nil, key: key)
    }

    private func perform(_ original: MusicTrack, quality: MusicQuality, key: String, wantsVideo: Bool) async throws -> MusicStream {
        let t = original
        let matchTrack = await audioTwin(of: original, wantsVideo: wantsVideo)
        if let o = matchOverrides?.override(for: t), let provider = registry.audio.first(where: { $0.id == o.providerID }) {
            var streams = (matchOverrides?.streamsHint(for: t) ?? []).filter { $0.expiresAt.map { $0 > now() } ?? true }
            let page = matchOverrides?.pageURL(for: t)
            if streams.isEmpty {
                let src = MusicAudioSource(id: o.sourceID, providerID: o.providerID, title: t.title, artist: nil, durationMs: nil, externalURL: page, confidence: 1)
                streams = (try? await provider.streams(for: src)) ?? []
            }
            if let s = Self.pick(from: streams, quality: quality, now: now(), wantsVideo: wantsVideo) { return remember(s, for: t, page: page, key: key) }
        }
        var directVerifyFailed: Set<String> = []
        if let direct = t.directStreams, let s = Self.pick(from: fresh(direct), quality: quality, now: now(), wantsVideo: wantsVideo) {
            // A stream the track carries is proven too; one that fails the proof is left to the matching providers below.
            var ok = true
            if let verifier, let u = URL(string: s.url), !u.isFileURL, !MusicStreamProof.shared.isPassed(s.url) {
                let proof = MusicStreamProof.shared
                let pair = MusicStreamProof.pairKey(provider: t.providerID, url: u)
                if proof.isTrusted(pair) {
                    proof.checkLater(s, total: nil, startToo: t.durationMs, pair: pair, reader: verifier, soft: t.videoID != nil)
                } else {
                    let start = await MusicStreamVerifier.verifyStart(s, catalogueMs: t.durationMs, reader: verifier, proof: proof)
                    ok = start.verdict.isOK
                    if ok { proof.checkLater(s, total: start.total, pair: pair, reader: verifier, soft: t.videoID != nil) } else { proof.recordFailure(pair) }
                }
            }
            if ok {
                MusicStartTimeline.shared.mark(t.uid, .verified)
                servedProvider[t.uid] = t.providerID
                return remember(s, for: t, page: nil, key: key)
            }
            bad.insert(s.url)
            directVerifyFailed.insert(s.url)
        }
        let bypassChain = chainBypass.remove(t.uid) != nil
        // Added addons race with the other audio providers; with none added the chain steps aside and the loop below runs as before.
        if !wantsVideo, !bypassChain, let chain {
            switch await chain.resolve(t, quality: quality) {
            case .resolved(let r) where !bad.contains(r.stream.url):
                served[t.uid] = r.memberID
                return remember(r.stream, for: t, page: r.page, key: key)
            case .resolved:
                // The chain handed back an address that already failed (its own answer cache): the plain provider walk below asks again.
                break
            case .exhausted: throw Task.isCancelled ? MusicError.cancelled : MusicError.noPlayableSource(t.title)
            case .notUsed: break
            }
        }
        // Round one asks for the exact recording. When nothing plays it, round two looks the song up by title and artist (its audio twin).
        var attemptTrack = matchTrack
        var excludeID: String?
        var twinTried = false
        var lastResortRound = false
        while true {
        let providers = health.ordered(registry.audio, id: { $0.id })
        guard !providers.isEmpty else {
            log?.record(track: t.title, provider: nil, reason: "No audio source is turned on. Turn one on in Music Settings.")
            throw MusicError.noPlayableSource(t.title)
        }
        // Every healthy provider is asked at once; the first acceptable, verified stream wins and the rest are cancelled.
        let notes = LaneNotes()
        // The last round, when only failed addresses are left, lets them through (each is checked again before it is used).
        let bad = lastResortRound ? Set<String>() : self.bad.snapshot()
        let inLastResort = lastResortRound
        let verifier = self.verifier
        let minimum = Self.minimumScore
        let roundTrack = attemptTrack, skipID = excludeID
        let lanes = providers.map { provider -> MusicRaceLane<LaneHit> in
            let name = providerName(provider.id)
            return MusicRaceLane(id: provider.id) {
                try await Self.walk(provider: provider, name: name, track: roundTrack, quality: quality, wantsVideo: wantsVideo, bad: bad,
                                    verifier: verifier, minimum: minimum, notes: notes, now: Date(), timelineKey: original.uid, excludeSourceID: skipID, lastResortRound: inLastResort)
            }
        }
        var config = raceConfig
        config.patientIDs = Self.patientProviders
        let race = await MusicRace.run(lanes: lanes, config: config, sleep: raceSleep)
        if Task.isCancelled { throw MusicError.cancelled }
        if let hit = race.value, let w = race.winner {
            health.recordSuccess(providers[w].id)
            for (i, p) in providers.enumerated() where i != w && (race.errors[i] != nil || race.timedOut.contains(i)) { health.recordFailure(p.id) }
            servedProvider[t.uid] = hit.providerID
            if hit.lastResort { lastResortURLs.insert(hit.stream.url); if lastResortURLs.count > 32 { lastResortURLs = [hit.stream.url] } }
            // Why the other sources were skipped is kept for the playback log even though this song plays.
            for (i, p) in providers.enumerated() where i != w {
                let name = providerName(p.id)
                if let e = race.errorKinds[i] { notes.add(name, Self.reason(e, provider: name)) }
                else if race.timedOut.contains(i) { notes.add(name, "\(name) did not answer in time") }
            }
            for n in notes.all.prefix(Self.maxNotesOnSuccess) { log?.record(track: t.title, provider: n.0, reason: n.1) }
            return remember(hit.stream, for: t, page: hit.page, key: key)
        }
        // A dead connection is not a reason to search again: only when some source answered (or refused) is the title-and-artist round worth running.
        let someoneAnswered = providers.indices.contains { i in
            guard let e = race.errorKinds[i] else { return !race.timedOut.contains(i) }
            if case .network = (e as? MusicError) ?? .notFound { return false }
            return true
        }
        if !twinTried, !wantsVideo, someoneAnswered, let search = Self.searchRequest(for: t) {
            twinTried = true
            attemptTrack = search
            excludeID = t.videoID ?? t.id
            log?.record(track: t.title, provider: "YouTube Music", reason: Localized.string("Not available as audio. Trying another source."))
            continue
        }
        // Nothing else is left to ask. A stream the track carries itself that failed once (it was only ever marked, never proven dead) is the
        // last candidate: it is checked again before it is used, so a transient failure on a single-address source never ends in "no source".
        if let direct = t.directStreams, let s = Self.pick(from: direct.filter { !directVerifyFailed.contains($0.url) }, quality: quality, now: now(), wantsVideo: wantsVideo),
           bad.contains(s.url), !Task.isCancelled {
            var ok = true
            if let verifier, let u = URL(string: s.url), !u.isFileURL {
                ok = await MusicStreamVerifier.verifyStart(s, catalogueMs: t.durationMs, reader: verifier, proof: MusicStreamProof.shared).verdict.isOK
            }
            if ok {
                servedProvider[t.uid] = t.providerID
                lastResortURLs.insert(s.url); if lastResortURLs.count > 32 { lastResortURLs = [s.url] }
                log?.record(track: t.title, provider: providerName(t.providerID), reason: Localized.string("Trying the earlier address again: no other source is left."))
                return remember(s, for: t, page: nil, key: key)
            }
        }
        if !lastResortRound, notes.sawBadAddresses, !Task.isCancelled {
            lastResortRound = true
            attemptTrack = matchTrack
            excludeID = nil
            log?.record(track: t.title, provider: nil, reason: Localized.string("Trying the earlier address again: no other source is left."))
            continue
        }
        var networkTrouble = 0
        for (i, p) in providers.enumerated() {
            let name = providerName(p.id)
            if let e = race.errorKinds[i] {
                health.recordFailure(p.id)
                if case .network = (e as? MusicError) ?? .notFound { networkTrouble += 1 }
                notes.add(name, Self.reason(e, provider: name))
            } else if race.timedOut.contains(i) {
                health.recordFailure(p.id)
                networkTrouble += 1
                notes.add(name, "\(name) did not answer in time")
            }
        }
        for n in notes.all { log?.record(track: t.title, provider: n.0, reason: n.1) }
        if let v = unplayable.verdict(videoID: t.videoID ?? t.id) {
            log?.record(track: t.title, provider: "YouTube", reason: v.text)
            throw MusicError.noPlayableSource(t.title + ". " + v.text)
        }
        // Every provider failed to answer at all: the network is the likely cause, which is not a problem with this song.
        let answered = providers.indices.filter { race.errorKinds[$0] == nil && !race.timedOut.contains($0) }.count
        if answered == 0, networkTrouble > 0 { throw MusicError.network("no music source answered") }
        throw MusicError.noPlayableSource(t.title)
        }
    }

    struct LaneHit: Sendable { var stream: MusicStream; var page: String?; var providerID: String; var lastResort = false }

    /// Plain-English reasons collected by the lanes of one race.
    final class LaneNotes: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(String?, String)] = []
        private var badOnly = false
        func add(_ provider: String?, _ text: String) { lock.withLock { items.append((provider, text)) } }
        /// A lane found a recording whose only streams had all failed before.
        func flagBadAddresses() { lock.withLock { badOnly = true } }
        var sawBadAddresses: Bool { lock.withLock { badOnly } }
        var all: [(String?, String)] { lock.withLock { items } }
    }

    /// Search variants, rules, streams and verification for one provider. Returns nil when it has nothing acceptable.
    nonisolated static func walk(provider: any MusicAudioProvider, name: String, track t: MusicTrack, quality: MusicQuality, wantsVideo: Bool,
                                 bad: Set<String>, verifier: MusicStreamVerifier.Reader?, minimum: Float, notes: LaneNotes, now: Date,
                                 timelineKey: String? = nil, excludeSourceID: String? = nil, lastResortRound: Bool = false) async throws -> LaneHit? {
        let timeline = MusicStartTimeline.shared
        let proof = MusicStreamProof.shared
        let tkey = timelineKey ?? t.uid
        var lastError: Error?
        var sawMatch = false
        var rejected = false
        var answered = false
        var exact = false
        /// Picks streams from the pool one at a time and proves each (opening read now, the rest after the song starts); nil when none passes.
        func settle(_ pool: inout [MusicStream], candidate: MusicAudioSource, lastResort: Bool) async throws -> LaneHit? {
            while let s = pick(from: pool, quality: quality, now: now, wantsVideo: wantsVideo) {
                try Task.checkCancellation()
                if let verifier, !proof.isPassed(s.url) {
                    // Only the opening read is on the way to the first sound; the middle and tail are read while the song plays and
                    // swap the address if they fail. A pair with a clean recent run starts at once and is read in full afterwards.
                    let pair = MusicStreamProof.pairKey(provider: provider.id, url: URL(string: s.url))
                    if proof.isTrusted(pair) && !lastResort {
                        proof.checkLater(s, total: nil, startToo: t.durationMs, pair: pair, reader: verifier, soft: exact)
                    } else {
                        let start = await MusicStreamVerifier.verifyStart(s, catalogueMs: t.durationMs, reader: verifier, proof: proof)
                        if !start.verdict.isOK {
                            proof.recordFailure(pair)
                            notes.add(name, "\(name): \(start.verdict.reason)")
                            pool.removeAll { $0.url == s.url }
                            continue
                        }
                        proof.checkLater(s, total: start.total, pair: pair, reader: verifier, soft: exact)
                    }
                }
                timeline.mark(tkey, .verified)
                return LaneHit(stream: s, page: candidate.externalURL, providerID: provider.id, lastResort: lastResort)
            }
            return nil
        }
        for variant in MusicCandidateRules.variants(for: t) {
            try Task.checkCancellation()
            let sources: [MusicAudioSource]
            do { sources = try await withDeadline(providerDeadline) { try await provider.sources(for: variant) }; answered = true } catch {
                if (error as? MusicError) == .cancelled || error is CancellationError { throw MusicError.cancelled }
                if !answered { throw error }
                break
            }
            timeline.mark(tkey, .searched)
            // A track that already names this provider's own id (a YouTube Music video id) is that exact recording: the title, artist and length
            // rules exist to vet search results and never apply to it.
            exact = isExact(track: t, provider: provider, sources: sources)
            let ranked: [(source: MusicAudioSource, score: Float)] = exact
                ? sources.prefix(1).map { (source: $0, score: 1) }
                : MusicCandidateRules.rank(track: t, candidates: sources.filter { $0.id != excludeSourceID }, minimum: minimum, limit: candidatesPerProvider,
                                           score: { score(track: $0, candidate: $1) })
            if ranked.isEmpty { if !sources.isEmpty { rejected = true }; continue }
            sawMatch = true
            timeline.mark(tkey, .candidate)
            for (candidate, _) in ranked {
                try Task.checkCancellation()
                var streams = candidate.streams ?? []
                if streams.isEmpty {
                    do { streams = try await withDeadline(streamDeadline) { try await provider.streams(for: candidate) } } catch {
                        if (error as? MusicError) == .cancelled || error is CancellationError { throw MusicError.cancelled }
                        lastError = error
                    }
                }
                timeline.mark(tkey, .streamsListed)
                var pool = streams.filter { !bad.contains($0.url) }
                if pool.isEmpty, !streams.isEmpty {
                    // Every address this recording offers already failed once. The provider is asked to forget its copy and to look again; an answer
                    // that is still only failed addresses is noted, and the resolver asks again at the very end with them allowed (see `perform`).
                    if let e = provider as? any MusicStreamEvicting {
                        await e.evictStreams(for: candidate)
                        if let again = try? await withDeadline(streamDeadline, { try await provider.streams(for: candidate) }) { pool = again.filter { !bad.contains($0.url) } }
                    }
                    if pool.isEmpty { notes.flagBadAddresses(); continue }
                }
                if let hit = try await settle(&pool, candidate: candidate, lastResort: lastResortRound) { return hit }
            }
        }
        if let lastError { throw lastError }
        notes.add(name, sawMatch ? "Found a match but no stream this player can open"
                  : (rejected ? "Results were the wrong version, artist or length" : "No matching recording found"))
        return nil
    }

    /// True when `sources` is the one recording the track itself names for this provider (same provider, same id).
    nonisolated static func isExact(track t: MusicTrack, provider: any MusicAudioProvider, sources: [MusicAudioSource]) -> Bool {
        guard t.providerID == provider.id, sources.count == 1, let s = sources.first else { return false }
        return s.id == (t.videoID ?? t.id)
    }

    /// The same song as a search request: the video id is dropped so the provider looks the song up by title and artist (its official audio
    /// twin, a song match) instead of asking for the exact video again.
    nonisolated static func searchRequest(for t: MusicTrack) -> MusicTrack? {
        guard t.providerID == YTM.providerID, t.directStreams == nil else { return nil }
        var s = t
        s.videoID = nil; s.providerID = "search"; s.id = "search:" + t.id; s.isVideo = false
        return s
    }

    private func fresh(_ streams: [MusicStream]) -> [MusicStream] { streams.filter { !bad.contains($0.url) } }

    private func providerName(_ id: String) -> String { registry.provider(id: id)?.info.name ?? id }

    /// A short, plain sentence for a provider failure.
    nonisolated static func reason(_ error: Error, provider: String) -> String {
        if let m = error as? MusicError {
            switch m {
            case .network(let s): return "\(provider) did not answer (\(s))"
            case .notSignedIn: return "\(provider) needs a sign-in"
            case .rateLimited: return "\(provider) is busy"
            case .notFound: return "\(provider) has no match"
            case .noPlayableSource: return "\(provider) found no playable stream"
            default: return "\(provider) failed"
            }
        }
        return "\(provider) did not answer"
    }

    /// The uid-keyed maps hold the newest `uidMapLimit` tracks; older ones are dropped from all of them together.
    private func trimUIDMaps(touching uid: String) {
        uidRecency.touch(uid)
        for old in uidRecency.evict(limit: Self.uidMapLimit, keeping: [uid]) {
            pages[old] = nil; served[old] = nil; servedProvider[old] = nil; cachedServes.remove(old)
        }
    }

    private func remember(_ s: MusicStream, for t: MusicTrack, page: String?, key: String) -> MusicStream {
        cachedServes.remove(t.uid)
        MusicStartTimeline.shared.mark(t.uid, .resolved)
        if servedByURL[s.url] == nil { servedOrder.append(s.url) }
        servedByURL[s.url] = (t, s)
        while servedOrder.count > 16 { servedByURL[servedOrder.removeFirst()] = nil }
        if let page { pages[t.uid] = page }
        trimUIDMaps(touching: t.uid)
        let expires = MusicStreamExpiry.effectiveExpiry(s).map { $0.addingTimeInterval(-MusicStreamExpiry.safetyMargin) } ?? now().addingTimeInterval(Self.defaultLifetime)
        if expires > now(), !bad.contains(s.url) { cache[key] = Cached(stream: s, expires: expires) }
        // The result cache is bounded: expired copies go first, then the oldest.
        if cache.count > 64 { cache = cache.filter { $0.value.expires > now() } }
        if cache.count > 64 { for k in cache.sorted(by: { $0.value.expires < $1.value.expires }).prefix(cache.count - 64).map(\.key) { cache[k] = nil } }
        return s
    }
}

/// The one-shot state of `withDeadline`: the first result wins, the other task is cancelled, a second result is ignored.
private final class DeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    private var done = false
    private var early: Result<T, Error>?
    private var tasks: [Task<Void, Never>] = []

    func start(_ c: CheckedContinuation<T, Error>) {
        lock.lock(); defer { lock.unlock() }
        if let e = early { done = true; c.resume(with: e) } else { cont = c }
    }
    func attach(_ a: Task<Void, Never>, _ b: Task<Void, Never>) {
        lock.lock(); let finished = done || early != nil; if !finished { tasks = [a, b] }; lock.unlock()
        if finished { a.cancel(); b.cancel() }
    }
    func finish(_ r: Result<T, Error>) {
        lock.lock()
        if done || early != nil { lock.unlock(); return }
        let c = cont; cont = nil
        if let c { done = true } else { early = r }
        let t = tasks; tasks = []
        lock.unlock()
        for x in t { x.cancel() }
        c?.resume(with: r)
    }
}
