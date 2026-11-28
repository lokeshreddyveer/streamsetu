import Foundation

// Stream resolution for YouTube Music tracks: a fixed client order, one signature timestamp per attempt, tail-range validation of every
// URL, a duration-aware URL cache and a memory of URLs that failed during playback.
//
// Client order: WEB_REMIX first when it can stream (it needs a PoToken, so only when a token source is plugged in), then VISIONOS (direct
// URLs, no cipher, no token), then TVHTML5_SIMPLY. Uploads need an account and use TVHTML5 then WEB_CREATOR.

/// Optional proof-of-origin tokens. No source ships by default; without one, clients that need a token are skipped.
protocol YouTubePoTokenSource: Sendable {
    /// Token bound to the visitor id, sent in the player request body.
    func sessionToken(visitorData: String) async -> String?
    /// Token bound to one video, appended to the stream URL as `pot`.
    func streamingToken(videoID: String) async -> String?
}

struct YTMFormat: Sendable, Equatable {
    var url: String?
    var cipher: String?
    var mime: String
    var bitrate: Int
    var averageBitrate: Int?
    var contentLength: Int
    var audioQuality: String?
    var audioChannels: Int
    var sampleRate: Int?
    var loudnessDb: Double?
    var isVideo: Bool
    var hasAudioTrack: Bool
    var audioIsDefault: Bool
    var autoDubbed: Bool

    var qualityRank: Int { ["AUDIO_QUALITY_HIGH": 3, "AUDIO_QUALITY_MEDIUM": 2, "AUDIO_QUALITY_LOW": 1][audioQuality ?? ""] ?? 0 }
    /// AAC in MP4 is the only YouTube audio the system player can open; WebM (Opus, Vorbis) is refused outright, so it ranks last.
    var codecRank: Int { mime.contains("mp4a") ? 2 : (mime.contains("opus") || mime.contains("vorbis") ? 0 : 1) }
    var isSystemPlayable: Bool { !(mime.contains("webm") || mime.contains("opus") || mime.contains("vorbis")) }
    var isOriginal: Bool { !hasAudioTrack || (audioIsDefault && !autoDubbed) }
    var isHigh: Bool { audioQuality == "AUDIO_QUALITY_HIGH" }
}

enum YTMFormatPicker {
    static func int(_ v: Any?) -> Int? { (v as? Int) ?? (v as? String).flatMap(Int.init) ?? (v as? Double).map(Int.init) }

    static func parse(_ streamingData: [String: Any]) -> (adaptive: [YTMFormat], progressive: [YTMFormat]) {
        func conv(_ f: [String: Any]) -> YTMFormat? {
            guard let mime = f.str("mimeType") else { return nil }
            let url = f.str("url"), cipher = f.str("signatureCipher") ?? f.str("cipher")
            guard url != nil || cipher != nil else { return nil }
            let track = f.dict("audioTrack")
            return YTMFormat(url: url, cipher: cipher, mime: mime, bitrate: int(f["bitrate"]) ?? 0, averageBitrate: int(f["averageBitrate"]),
                             contentLength: int(f["contentLength"]) ?? 0, audioQuality: f.str("audioQuality"), audioChannels: int(f["audioChannels"]) ?? 2,
                             sampleRate: int(f["audioSampleRate"]), loudnessDb: (f["loudnessDb"] as? Double) ?? (f["loudnessDb"] as? Int).map(Double.init),
                             isVideo: f["width"] != nil, hasAudioTrack: track != nil, audioIsDefault: (track?["audioIsDefault"] as? Bool) ?? false,
                             autoDubbed: (track?["isAutoDubbed"] as? Bool) ?? false)
        }
        return (streamingData.array("adaptiveFormats").compactMap(conv), streamingData.array("formats").compactMap(conv))
    }

    /// Audio candidates best first. Adaptive audio-only formats are preferred; progressive audio is the fallback (RSS podcasts).
    static func ranked(adaptive: [YTMFormat], progressive: [YTMFormat], low: Bool) -> [YTMFormat] {
        var pool = adaptive.filter { !$0.isVideo && $0.mime.hasPrefix("audio/") }
        if pool.isEmpty { pool = progressive.filter { $0.mime.hasPrefix("audio/") } }
        let originals = pool.filter(\.isOriginal)
        if !originals.isEmpty { pool = originals }
        let playable = pool.filter(\.isSystemPlayable)
        if !playable.isEmpty { pool = playable }
        if low {
            let small = pool.filter { $0.bitrate <= 128_000 }
            return (small.isEmpty ? pool : small).sorted { $0.bitrate > $1.bitrate }
        }
        return pool.sorted { a, b in
            (a.qualityRank, a.audioChannels == 2 ? 1 : 0, a.codecRank, a.bitrate) > (b.qualityRank, b.audioChannels == 2 ? 1 : 0, b.codecRank, b.bitrate)
        }
    }
}

enum YTMHLS {
    /// From a master playlist: return it whole when it has separate audio renditions, else the lowest-bandwidth AAC-LC variant
    /// (lowest of all when quality is low or none is AAC-LC). Variant lines must carry an https URL.
    static func choose(master: String, low: Bool, masterURL: String) -> String {
        if master.contains("#EXT-X-MEDIA:") { return masterURL }
        let lines = master.split(whereSeparator: \.isNewline).map(String.init)
        var variants: [(bandwidth: Int, aac: Bool, url: String)] = []
        for (i, l) in lines.enumerated() where l.hasPrefix("#EXT-X-STREAM-INF:") && i + 1 < lines.count && lines[i + 1].hasPrefix("https://") {
            let bw = l.range(of: #"BANDWIDTH=(\d+)"#, options: .regularExpression).flatMap { Int(l[$0].dropFirst(10)) } ?? Int.max
            variants.append((bw, l.contains("mp4a.40.2"), lines[i + 1]))
        }
        guard !variants.isEmpty else { return masterURL }
        let aac = variants.filter(\.aac)
        let pool = (low || aac.isEmpty) ? variants : aac
        return pool.min { $0.bandwidth < $1.bandwidth }?.url ?? masterURL
    }
}

struct YTMResolvedStream: Sendable {
    var videoID: String
    var streams: [MusicStream]
    var clientKey: String
    var expiresAt: Date
    var loudnessDb: Double?
    var isLive: Bool
}

actor YouTubeMusicStreamResolver {
    private let client: YouTubeMusicClient
    private let solver: YTMStreamURLSolver
    private let poToken: YouTubePoTokenSource?
    private let disabled: Set<YTMClientKey>
    private let now: @Sendable () -> Date
    private let unplayable: MusicUnplayableMemory
    /// Proves each stream (opens, audio, whole-file reach, right length). Nil leaves only the tail probe (offline tests).
    private let verifier: MusicStreamVerifier.Reader?
    private var cache: [String: YTMResolvedStream] = [:]
    private var failures: [String: Date] = [:]
    private let proof: MusicStreamProof = .shared
    static let failureMemory: TimeInterval = 30 * 60

    init(client: YouTubeMusicClient, solver: YTMStreamURLSolver? = nil, poToken: YouTubePoTokenSource? = nil, disabledClients: Set<YTMClientKey> = [],
         unplayable: MusicUnplayableMemory = .shared, verifier: MusicStreamVerifier.Reader? = MusicStreamResolver.defaultVerifier,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.unplayable = unplayable; self.verifier = verifier
        self.client = client
        self.solver = solver ?? YTMStreamURLSolver(http: client.http)
        self.poToken = poToken; self.disabled = disabledClients; self.now = now
    }

    // MARK: cache

    private func cacheKey(_ id: String, _ q: MusicQuality) -> String { id + (q == .low ? ":low" : ":hi") }

    /// A cached URL is used only while it outlives the whole track plus a minute: later seeks are new requests that need a live URL.
    func cached(videoID: String, quality: MusicQuality, durationSeconds: Double) -> YTMResolvedStream? {
        guard let e = cache[cacheKey(videoID, quality)] else { return nil }
        // An address that failed while playing, or whose client was just excluded for this video, is never handed out again.
        if e.streams.contains(where: { unplayable.isBadURL($0.url) }) || unplayable.isExcluded(client: e.clientKey, videoID: videoID) { return nil }
        // The address' own `expire` is checked as well as the lifetime YouTube reported: whichever is earlier decides.
        let horizon = now().addingTimeInterval(60 + durationSeconds)
        if e.expiresAt <= horizon { return nil }
        if e.streams.contains(where: { MusicStreamExpiry.urlExpiry($0.url).map { $0 <= horizon } ?? false }) { return nil }
        return e
    }

    private func store(_ r: YTMResolvedStream, quality: MusicQuality) {
        guard !r.isLive else { return }
        cache = cache.filter { $0.value.expiresAt > now() }
        cache[cacheKey(r.videoID, quality)] = r
    }

    /// Playback got a 403 on this video's URL: forget it and skip the web client's answer for 30 minutes.
    func reportPlaybackFailure(videoID: String) {
        failures = failures.filter { $0.value > now() }
        failures[videoID] = now().addingTimeInterval(Self.failureMemory)
        cache.removeValue(forKey: cacheKey(videoID, .high)); cache.removeValue(forKey: cacheKey(videoID, .low))
    }

    func invalidate(videoID: String) {
        cache.removeValue(forKey: cacheKey(videoID, .high)); cache.removeValue(forKey: cacheKey(videoID, .low))
    }

    // MARK: resolution

    /// The whole YouTube resolve (every client, then the watch-page extractor) gives up after this long.
    static let overallCap: TimeInterval = 120
    static let watchPageAttempts = 3

    func resolve(videoID: String, title: String, quality: MusicQuality, durationSeconds: Double, isUpload: Bool = false) async throws -> YTMResolvedStream {
        guard videoID.range(of: "^[A-Za-z0-9_-]{6,20}$", options: .regularExpression) != nil else { throw MusicError.notFound }
        if !isUpload, let c = cached(videoID: videoID, quality: quality, durationSeconds: durationSeconds) { return c }
        if let v = unplayable.verdict(videoID: videoID) { throw MusicError.noPlayableSource(title + ". " + v.text) }
        return try await ytmWithTimeout(Self.overallCap) { try await self.resolveWithin(videoID: videoID, title: title, quality: quality, durationSeconds: durationSeconds, isUpload: isUpload) }
    }

    private func resolveWithin(videoID: String, title: String, quality: MusicQuality, durationSeconds: Double, isUpload: Bool) async throws -> YTMResolvedStream {
        let signedIn = await client.isSignedIn
        if isUpload, !signedIn { throw MusicError.notSignedIn("YouTube Music") }
        // YouTube has refused this connection as a bot: no request is sent while the gate is closed (a signed-in account is never held back).
        if !signedIn, YouTubeBotGate.shared.isClosed { throw MusicError.rateLimited(retryAfter: YouTubeBotGate.shared.secondsLeft) }
        var outcome = Outcome()
        if let r = await attempt(videoID: videoID, quality: quality, isUpload: isUpload, signedIn: signedIn, durationSeconds: durationSeconds, outcome: &outcome) {
            if !isUpload { store(r, quality: quality) }
            YouTubeBotGate.shared.reset()
            return r
        }
        if !signedIn, YouTubeBotGate.shared.isClosed { throw MusicError.rateLimited(retryAfter: YouTubeBotGate.shared.secondsLeft) }
        // Every address YouTube offered had failed once already (a fresh lookup can return the same address) or every client was resting: ask
        // once more with those allowed, checking them again before use. A transient failure never leaves a song with nothing to try.
        if outcome.skippedBad || outcome.skippedParked {
            var again = Outcome()
            if let r = await attempt(videoID: videoID, quality: quality, isUpload: isUpload, signedIn: signedIn, durationSeconds: durationSeconds, outcome: &again, allowBad: true, allowParked: true) {
                if !isUpload { store(r, quality: quality) }
                return r
            }
            outcome.anyAnswer = outcome.anyAnswer || again.anyAnswer
            outcome.answers += again.answers
            outcome.permanent += again.permanent
        }
        // YouTube answered but nothing played: some region-locked tracks redirect to a twin that plays here.
        if outcome.anyAnswer, !isUpload, outcome.permanent.isEmpty, let twin = await client.watchRedirect(videoID: videoID) {
            var o2 = Outcome()
            if var r = await attempt(videoID: twin, quality: quality, isUpload: false, signedIn: signedIn, durationSeconds: durationSeconds, outcome: &o2) {
                r.videoID = videoID
                store(r, quality: quality)
                return r
            }
        }
        // Last extractor: the public watch page carries a player response of its own.
        if !isUpload, outcome.permanent.count < max(1, outcome.answers), let r = await watchPageFallback(videoID: videoID, quality: quality, durationSeconds: durationSeconds, outcome: &outcome) {
            store(r, quality: quality)
            return r
        }
        if !outcome.anyAnswer { throw MusicError.network("could not reach YouTube. Check your connection and try again.") }
        // A reason that no client can change (private, removed, region-locked, age-restricted) is remembered so the song is not asked again.
        if outcome.answers > 0, outcome.permanent.count >= outcome.answers, let v = outcome.permanent.first {
            unplayable.remember(v, videoID: videoID)
            await note(title: title, reason: v.text)
            throw MusicError.noPlayableSource(title + ". " + v.text)
        }
        // A guest who is told to sign in by every client simply cannot get this song from YouTube: it is unavailable, not a sign-in task.
        throw MusicError.noPlayableSource(title)
    }

    private func note(title: String, reason: String) async {
        await MainActor.run { MusicPlaybackLog.shared.record(track: title, provider: "YouTube", reason: reason) }
    }

    struct Outcome {
        var anyAnswer = false
        var sawLoginRequired = false
        /// Players that answered with a playability status (OK or not).
        var answers = 0
        /// One permanent verdict per answering client that gave one.
        var permanent: [MusicUnplayableMemory.Verdict] = []
        /// An address was left out because it had failed before, or a client because it was resting: a second pass may use them.
        var skippedBad = false
        var skippedParked = false
    }

    private func chain(isUpload: Bool, signedIn: Bool, videoID: String, hasPoToken: Bool, allowParked: Bool = false, skippedParked: inout Bool) -> [YTMClientKey] {
        var order: [YTMClientKey] = []
        if isUpload { order = [.tvhtml5, .webCreator] }
        else {
            if client.identity(.webRemix).useWebPoTokens ? hasPoToken : true, failures[videoID].map({ $0 <= now() }) ?? true { order.append(.webRemix) }
            // VISIONOS first (direct URLs, no cipher, no token), then the app clients; the stream probe decides whether a client's URLs really serve a whole song.
            order += YTMClientOrder.guest
        }
        return order.filter { k in
            let id = client.identity(k)
            guard !disabled.contains(k), !id.loginRequired || signedIn, !id.useWebPoTokens || hasPoToken else { return false }
            if !allowParked, unplayable.isExcluded(client: k.rawValue, videoID: videoID) { skippedParked = true; return false }
            return true
        }
    }

    private func attempt(videoID: String, quality: MusicQuality, isUpload: Bool, signedIn: Bool, durationSeconds: Double, outcome: inout Outcome,
                         allowBad: Bool = false, allowParked: Bool = false) async -> YTMResolvedStream? {
        let low = quality == .low
        let visitor = await client.session.snapshot().visitorData
        var sessionToken: String?
        if let poToken, let visitor { sessionToken = await poToken.sessionToken(visitorData: visitor) }
        let order = chain(isUpload: isUpload, signedIn: signedIn, videoID: videoID, hasPoToken: sessionToken != nil, allowParked: allowParked, skippedParked: &outcome.skippedParked)
        var sts: Int?
        var stsFetched = false
        var fallback: (stream: YTMResolvedStream, rank: Int)?
        var sawHigh = false
        var queue = order
        var tried = Set<YTMClientKey>()
        while !queue.isEmpty {
            // The gate closed while this song was being tried: the other clients would only be refused the same way.
            if !signedIn, YouTubeBotGate.shared.isClosed { break }
            let key = queue.removeFirst()
            guard tried.insert(key).inserted else { continue }
            let id = client.identity(key)
            // The signature timestamp costs a request; only the clients that send one pay for it.
            if id.useSignatureTimestamp, !stsFetched { sts = await solver.signatureTimestamp(); stsFetched = true }
            await YouTubeRequestPacer.shared.wait()
            guard let resp = try? await client.player(videoID: videoID, client: key, signatureTimestamp: id.useSignatureTimestamp ? sts : nil, poToken: sessionToken, playlistID: isUpload ? "MLPT" : nil) else { continue }
            outcome.anyAnswer = true
            outcome.answers += 1
            let root = resp.dict
            let status = root.dict("playabilityStatus")?.str("status") ?? ""
            if status != "OK" {
                if status == "LOGIN_REQUIRED" { outcome.sawLoginRequired = true }
                let reason = root.dict("playabilityStatus").map { ($0.str("reason") ?? "") + " " + (YTMJSON.firstString("text", in: $0["errorScreen"] as Any) ?? "") }
                if !signedIn { YouTubeBotGate.shared.observe(status: status, reason: reason ?? "", videoID: videoID) }
                if !(YouTubeBotGate.isBotCheck(status: status, reason: reason ?? "")), let v = YouTubePlayability.from(status: status, reason: reason).verdict { outcome.permanent.append(v) }
                if key == .webRemix, signedIn, ["AGE_CHECK_REQUIRED", "AGE_VERIFICATION_REQUIRED", "LOGIN_REQUIRED", "CONTENT_CHECK_REQUIRED"].contains(status) { queue.insert(.webCreator, at: 0) }
                continue
            }
            guard let sd = root.dict("streamingData") else { continue }
            let expires = TimeInterval(YTMFormatPicker.int(sd["expiresInSeconds"]) ?? 21540)
            let expiresAt = now().addingTimeInterval(expires)
            let details = root.dict("videoDetails")
            let loudness = (root.dict("playerConfig")?.dict("audioConfig")?["loudnessDb"] as? Double)
            let headers = ["User-Agent": id.userAgent]

            if (details?["isLive"] as? Bool) == true {
                if let live = await liveStream(sd, id: id, videoID: videoID, low: low, headers: headers, expiresAt: expiresAt, clientKey: key) { return live }
                continue
            }
            let (adaptive, progressive) = YTMFormatPicker.parse(sd)
            if adaptive.contains(where: { $0.isHigh }) { sawHigh = true }
            formats: for f in YTMFormatPicker.ranked(adaptive: adaptive, progressive: progressive, low: low) {
                guard let url = await finalURL(f, id: id, videoID: videoID, sessionToken: sessionToken) else {
                    if id.needsWebTransforms { await solver.selfHeal() }
                    continue
                }
                if !allowBad, unplayable.isBadURL(url) { outcome.skippedBad = true; continue }
                guard var s = YouTubeAudio.stream(url: url, mimeType: f.mime, bitrateBps: f.averageBitrate ?? f.bitrate, sampleRate: f.sampleRate, headers: headers) else { continue }
                // The whole-file probe (start, first-MiB boundary, middle, tail: all at once) and the opening read of the verifier run
                // together, so the way to the first sound pays for one round trip, not six. Together they cover what the verifier's
                // middle and tail reads would, so those are not repeated.
                async let wholeFile = validate(url: url, format: f, headers: headers)
                var startVerdict = MusicProbeVerdict.ok
                if let reader = verifier, !proof.isPassed(url) {
                    startVerdict = await MusicStreamVerifier.verifyStart(s, catalogueMs: Int64(durationSeconds * 1000), reader: reader, proof: proof).verdict
                    // One refusal can be a passing hiccup: ask once more before this client is set aside for the video.
                    if case .refused = startVerdict {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        startVerdict = await MusicStreamVerifier.verifyStart(s, catalogueMs: Int64(durationSeconds * 1000), reader: reader, proof: proof).verdict
                    }
                }
                guard await wholeFile else {
                    if id.needsWebTransforms { await solver.selfHeal() }
                    continue
                }
                let pair = MusicStreamProof.pairKey(provider: "ytm", url: URL(string: url))
                switch startVerdict {
                case .ok:
                    if verifier != nil {
                        let type = f.mime.split(separator: ";").first.map(String.init)
                        proof.markPassed(url, size: f.contentLength > 0 ? .init(total: Int64(f.contentLength), contentType: type) : nil)
                        proof.recordPass(pair)
                    }
                case .refused:
                    // This client's addresses do not serve the whole song (or are blocked), twice in a row: skip it for this video for a couple of minutes.
                    proof.recordFailure(pair)
                    unplayable.exclude(client: key.rawValue, videoID: videoID)
                    break formats
                case .unreachable, .preview:
                    proof.recordFailure(pair)
                    continue formats
                }
                s.expiresAt = expiresAt
                let r = YTMResolvedStream(videoID: videoID, streams: [s], clientKey: key.rawValue, expiresAt: expiresAt, loudnessDb: f.loudnessDb ?? loudness, isLive: false)
                // Wanted high quality but got less while some client offers high: keep this one as a last resort and look further.
                if !low, !f.isHigh, sawHigh {
                    if fallback == nil || f.qualityRank > fallback!.rank { fallback = (r, f.qualityRank) }
                    break
                }
                return r
            }
        }
        return fallback?.stream
    }

    // MARK: watch page

    /// The player response embedded in a public watch page, parsed by balancing braces after `ytInitialPlayerResponse =`.
    static func playerResponse(inWatchPage html: String) -> [String: Any]? {
        guard let marker = html.range(of: "ytInitialPlayerResponse") else { return nil }
        guard let open = html[marker.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var end: String.Index?
        var i = open
        while i < html.endIndex {
            let ch = html[i]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else if ch == "\"" { inString = true }
            else if ch == "{" { depth += 1 }
            else if ch == "}" { depth -= 1; if depth == 0 { end = html.index(after: i); break } }
            i = html.index(after: i)
        }
        guard let end, let data = String(html[open..<end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private func watchPageFallback(videoID: String, quality: MusicQuality, durationSeconds: Double, outcome: inout Outcome) async -> YTMResolvedStream? {
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)&hl=en&has_verified=1&bpctr=9999999999") else { return nil }
        let id = client.identity(.web)
        let headers = ["User-Agent": id.userAgent, "Cookie": "SOCS=CAI; CONSENT=PENDING+987", "Accept-Language": "en-US,en;q=0.9"]
        let http = client.http
        for attempt in 1...Self.watchPageAttempts {
            if Task.isCancelled { return nil }
            if attempt > 1 { await client.sleep(Double(attempt - 1)) }
            guard let data = try? await ytmWithTimeout(5, { try await http.get(url, headers: headers) }),
                  let html = String(data: data, encoding: .utf8), let root = Self.playerResponse(inWatchPage: html) else { continue }
            outcome.anyAnswer = true
            guard (root.dict("videoDetails")?.str("videoId") ?? videoID) == videoID else { continue }
            let status = root.dict("playabilityStatus")?.str("status") ?? ""
            guard status == "OK", let sd = root.dict("streamingData") else { return nil }
            let expiresAt = now().addingTimeInterval(TimeInterval(YTMFormatPicker.int(sd["expiresInSeconds"]) ?? 21540))
            let (adaptive, progressive) = YTMFormatPicker.parse(sd)
            let hdr = ["User-Agent": id.userAgent]
            for f in YTMFormatPicker.ranked(adaptive: adaptive, progressive: progressive, low: quality == .low) {
                guard let u = await finalURL(f, id: id, videoID: videoID, sessionToken: nil), await validate(url: u, format: f, headers: hdr),
                      var s = YouTubeAudio.stream(url: u, mimeType: f.mime, bitrateBps: f.averageBitrate ?? f.bitrate, sampleRate: f.sampleRate, headers: hdr) else { continue }
                if let reader = verifier, !(await MusicStreamVerifier.verify(s, catalogueMs: Int64(durationSeconds * 1000), reader: reader)).isOK { continue }
                s.expiresAt = expiresAt
                return YTMResolvedStream(videoID: videoID, streams: [s], clientKey: "WATCH_PAGE", expiresAt: expiresAt, loudnessDb: f.loudnessDb, isLive: false)
            }
            return nil
        }
        return nil
    }

    private func isYouTubeHost(_ url: String) -> Bool {
        guard let h = URL(string: url)?.host?.lowercased() else { return false }
        return h.hasSuffix(".googlevideo.com") || h.hasSuffix(".c.youtube.com")
    }

    private func finalURL(_ f: YTMFormat, id: YTMClientIdentity, videoID: String, sessionToken: String?) async -> String? {
        var url: String
        do {
            if f.cipher != nil, f.url == nil {
                guard id.needsWebTransforms else { return nil }
                url = try await solver.playableURL(url: nil, cipher: f.cipher)
            } else if let u = f.url {
                url = (id.needsWebTransforms && isYouTubeHost(u)) ? try await solver.playableURL(url: u, cipher: nil) : u
            } else { return nil }
        } catch { return nil }
        if id.useWebPoTokens, isYouTubeHost(url), let poToken, let pot = await poToken.streamingToken(videoID: videoID) {
            url += (url.contains("?") ? "&" : "?") + "pot=" + YouTubeSignature.encode(pot)
        }
        return url
    }

    /// Whole-file probe (see `YTMClientOrder.probeRanges`). Capped addresses pass a HEAD or an opening-range probe, but not the later ranges.
    func validate(url: String, format f: YTMFormat, headers: [String: String]) async -> Bool {
        guard let u = URL(string: url) else { return false }
        let http = client.http
        guard f.contentLength > 0, isYouTubeHost(url) else {
            do { _ = try await ytmWithTimeout(10) { try await http.send(url: u, method: "HEAD", query: [:], headers: headers, body: nil) }; return true } catch { return false }
        }
        // Start, first-MiB boundary, middle and tail, all at once: an address that serves only the opening mebibyte fails one of them.
        let ranges = YTMClientOrder.probeRanges(length: f.contentLength)
        return await withTaskGroup(of: Bool.self) { group in
            for r in ranges {
                var h = headers
                h["Range"] = "bytes=\(r.lowerBound)-\(r.upperBound)"
                h["Accept-Encoding"] = "identity"
                let headersCopy = h
                group.addTask {
                    do { _ = try await ytmWithTimeout(10) { try await http.send(url: u, method: "GET", query: [:], headers: headersCopy, body: nil) }; return true } catch { return false }
                }
            }
            for await ok in group where !ok { group.cancelAll(); return false }
            return true
        }
    }

    private func liveStream(_ sd: [String: Any], id: YTMClientIdentity, videoID: String, low: Bool, headers: [String: String], expiresAt: Date, clientKey: YTMClientKey) async -> YTMResolvedStream? {
        guard var manifest = sd.str("hlsManifestUrl"), isYouTubeHost(manifest) || manifest.contains("youtube.com") else { return nil }
        if id.needsWebTransforms, let r = manifest.range(of: #"/n/([^/]+)/"#, options: .regularExpression) {
            let value = String(manifest[r].dropFirst(3).dropLast())
            let decoded = value.removingPercentEncoding ?? value
            let t = await solver.transformN(decoded)
            if t == decoded { return nil }
            manifest.replaceSubrange(r, with: "/n/\(YouTubeSignature.encode(t))/")
        }
        if id.useWebPoTokens, manifest.contains("/api/manifest/"), let poToken, let pot = await poToken.streamingToken(videoID: videoID) {
            if let r = manifest.range(of: "/playlist/index.m3u8") { manifest.insert(contentsOf: "/pot/\(pot)", at: r.lowerBound) }
            else if let r = manifest.range(of: "/file/index.m3u8") { manifest.insert(contentsOf: "/pot/\(pot)", at: r.lowerBound) }
        }
        guard let mu = URL(string: manifest) else { return nil }
        let http = client.http, hdr = headers
        guard let data = try? await ytmWithTimeout(10, { try await http.get(mu, headers: hdr) }), let text = String(data: data, encoding: .utf8) else { return nil }
        let chosen = YTMHLS.choose(master: text, low: low, masterURL: manifest)
        let s = MusicStream(url: chosen, codec: "aac", container: "m3u8", proto: .hls, headers: headers, expiresAt: expiresAt)
        return YTMResolvedStream(videoID: videoID, streams: [s], clientKey: clientKey.rawValue, expiresAt: expiresAt, loudnessDb: nil, isLive: true)
    }
}
