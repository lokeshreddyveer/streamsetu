import Foundation

// HTTP addon audio sources. An addon is a plain web server the person points the app at. It answers three questions over HTTP and returns JSON:
//   GET <base>/manifest.json        who are you
//   GET <base>/search?...           which recordings match this song
//   GET <base>/stream/<id>?...      where is the audio file for that recording
// Nothing the server sends is ever executed; every reply is read as data, size limited and checked field by field.

// MARK: problems

/// Why an addon could not be added or used. Three of these mean different things to the person: an outage should not send them to re-paste a correct address.
enum AddonProblem: Error, Equatable, Sendable {
    case blocked(String)        // the address itself is not allowed
    case notRecognised(String)  // it answered, but not in a format this app reads
    case unsupported(String)    // a known format that cannot be used (no search)
    case unreachable(String)    // down, busy or timing out: keep it, try again later
    case rejected(String)       // refused: wrong address or credentials
    case duplicate(String)

    var message: String {
        switch self {
        case .blocked(let s), .notRecognised(let s), .unsupported(let s), .unreachable(let s), .rejected(let s), .duplicate(let s): s
        }
    }

    static func classify(_ e: Error) -> AddonProblem {
        if let p = e as? AddonProblem { return p }
        switch e as? MusicError {
        case .notFound: return .rejected("Nothing is served at that address.")
        case .notSignedIn, .refused: return .rejected("The addon refused access. Check its address or access token.")
        case .rateLimited: return .unreachable("The addon is limiting requests right now.")
        case .network(let s):
            if s.hasPrefix("HTTP 5") { return .unreachable("The addon is unavailable (\(s)).") }
            if s.hasPrefix("HTTP 4") { return .rejected("The addon refused the request (\(s)).") }
            if s == "unexpected reply" || s == "reply too large" || s == "empty reply" { return .rejected("The addon sent a reply this app cannot read.") }
            return .unreachable("Cannot reach the addon right now (\(s)).")
        case .cancelled: return .unreachable("Cancelled.")
        default: return .unreachable("Cannot reach the addon right now.")
        }
    }
}

// MARK: address rules

/// Which addresses an addon may live at. Public servers must use https. A private-network address (this Mac, your router's network) is only reachable
/// when the person ticked "my own server", so a stranger's addon can never point the app at devices inside the home network.
enum AddonURLPolicy {
    static func isPrivateHost(_ rawHost: String) -> Bool { MusicNetworkPolicy.isPrivateHost(rawHost) }

    /// nil when the address is allowed; otherwise a sentence for the person.
    static func violation(_ url: URL, ownServer: Bool) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return "Only web addresses (https) are allowed." }
        guard let host = url.host, !host.isEmpty else { return "That address has no server name." }
        if url.user != nil || url.password != nil { return "Addresses with a user name or password in them are not accepted. Use the access token field instead." }
        if isPrivateHost(host) {
            return ownServer ? nil : "That address is on a private network. If you run the server yourself, tick \"my own server\"."
        }
        return scheme == "https" ? nil : "Addresses must start with https://. Plain http is only allowed for your own server on a private network."
    }
}

// MARK: lenient JSON helpers

enum AddonJSON {
    static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d.isFinite ? d : nil }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
    static func int(_ v: Any?) -> Int? { double(v).flatMap { $0.magnitude < 1e12 ? Int($0) : nil } }
    static func string(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    /// 1/0, true/false, "yes"/"on"... Unknown text means "not stated".
    static func flag(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.intValue != 0 }
        guard let s = (v as? String)?.lowercased() else { return nil }
        if ["1", "true", "yes", "on", "y"].contains(s) { return true }
        if ["0", "false", "no", "off", "n"].contains(s) { return false }
        return nil
    }
    static func strings(_ v: Any?) -> [String] { (v as? [Any])?.compactMap { string($0) } ?? [] }
    static func object(_ data: Data) throws -> [String: Any] {
        if data.isEmpty { throw MusicError.network("empty reply") }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MusicError.network("unexpected reply") }
        return o
    }
}

// MARK: manifest

struct AddonOption: Codable, Hashable, Sendable { var value: String; var label: String }

struct AddonSetting: Hashable, Sendable {
    var key: String; var defaultValue: String?; var options: [AddonOption]
}

struct AddonManifest: Hashable, Sendable {
    var id: String
    var name: String
    var version: String?
    /// Empty means the addon did not say; search and stream are then settled by asking.
    var resources: [String]
    var settings: [AddonSetting]
    var allowDownloads: Bool
    var checkValidLossless: Bool

    var displayName: String { name.isEmpty ? id : name }
    var qualityOptions: [AddonOption] { settings.first { $0.key == "quality" }?.options ?? [] }

    static func synthesised(base: URL) -> AddonManifest {
        AddonManifest(id: base.absoluteString, name: base.host ?? "Addon", version: nil, resources: ["search", "stream"], settings: [],
                      allowDownloads: true, checkValidLossless: false)
    }

    /// A manifest has an `id` and either a name or a version, or a `resources` list.
    static func looksLikeManifest(_ o: [String: Any]) -> Bool {
        if o["resources"] is [Any] { return true }
        return AddonJSON.string(o["id"]) != nil && (o["name"] != nil || o["version"] != nil)
    }

    static func parse(_ o: [String: Any]) -> AddonManifest? {
        guard let id = AddonJSON.string(o["id"]) else { return nil }
        var settings: [AddonSetting] = []
        for case let s as [String: Any] in (o["settings"] as? [Any]) ?? [] {
            guard let key = AddonJSON.string(s["key"]) else { continue }
            var opts: [AddonOption] = []
            for item in (s["options"] as? [Any]) ?? [] {
                if let d = item as? [String: Any], let v = AddonJSON.string(d["value"]) ?? AddonJSON.string(d["id"]) {
                    opts.append(AddonOption(value: v, label: AddonJSON.string(d["label"]) ?? v))
                } else if let v = AddonJSON.string(item) { opts.append(AddonOption(value: v, label: v)) }
            }
            let def = AddonJSON.string(s["default"]) ?? AddonJSON.int(s["default"]).map(String.init)
            settings.append(AddonSetting(key: key, defaultValue: def, options: opts))
        }
        return AddonManifest(id: id, name: AddonJSON.string(o["name"]) ?? "", version: AddonJSON.string(o["version"]),
                             resources: AddonJSON.strings(o["resources"]).map { $0.lowercased() }, settings: settings,
                             allowDownloads: AddonJSON.flag(o["allowDownloads"]) ?? true, checkValidLossless: AddonJSON.flag(o["checkValidLossless"]) ?? false)
    }
}

// MARK: request type and parameters

/// What the person's quality choice asks of a source.
enum AddonRequest: Hashable, Sendable {
    case lossless, best, capped(Int)

    init(_ q: MusicQuality) {
        switch q {
        case .lossless: self = .lossless
        case .high: self = .best
        case .medium: self = .capped(160)
        case .low: self = .capped(96)
        }
    }
    var isLossless: Bool { self == .lossless }
    var tierWord: String {
        switch self {
        case .lossless: "LOSSLESS"
        case .best: "HIGH"
        case .capped(let k): k <= 128 ? "LOW" : "HIGH"
        }
    }
}

enum AddonQuery {
    /// The `quality` value sent to an addon, in the addon's own vocabulary. A lossless request never matches on the word "lossless" (an addon may use it for
    /// CD quality and list better rungs above), so it sends the person's pick or the first option listed.
    static func qualityValue(request: AddonRequest, options: [AddonOption], picked: String?) -> String {
        let values = options.map(\.value)
        if request.isLossless {
            if let p = picked, values.isEmpty || values.contains(p) { return p }
            return values.first ?? request.tierWord
        }
        guard !values.isEmpty else { return request.tierWord }
        let tier = request.tierWord
        if let exact = values.first(where: { $0.caseInsensitiveCompare(tier) == .orderedSame }) { return exact }
        let words = tier == "HIGH" ? ["high", "320", "normal", "standard"] : ["low", "96", "128", "min"]
        return values.first { v in words.contains { v.lowercased().contains($0) } } ?? values[0]
    }

    /// Declared setting defaults, then `quality`, then `title` and `artist` (only for a known song), then `q`.
    static func parameters(manifest: AddonManifest?, request: AddonRequest, picked: String?, q: String?, title: String?, artist: String?) -> [String: String] {
        var out: [String: String] = [:]
        for s in manifest?.settings ?? [] { if let d = s.defaultValue { out[s.key] = d } }
        out["quality"] = qualityValue(request: request, options: manifest?.qualityOptions ?? [], picked: picked)
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { out["title"] = t }
        if let a = artist?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty { out["artist"] = a }
        if let q { out["q"] = q }
        return out
    }
}

// MARK: search rows

enum AddonTier: Int, Comparable, Sendable { case low = 0, high, lossless
    static func < (a: AddonTier, b: AddonTier) -> Bool { a.rawValue < b.rawValue }

    /// Free text to a rung, checked in this order: lossless words, then low, then high.
    static func infer(_ text: String) -> AddonTier? {
        let u = text.uppercased()
        func has(_ w: [String]) -> Bool { w.contains { u.contains($0) } }
        if has(["LOSSLESS", "FLAC", "ALAC", "HI-RES", "HI_RES", "HIRES", "24-BIT", "16-BIT", "WAV"]) { return .lossless }
        if has(["LOW", "128", "96KBPS", "64"]) { return .low }
        if has(["HIGH", "320", "MP3", "AAC", "M4A", "OPUS", "OGG"]) { return .high }
        return nil
    }
}

struct AddonRow: Hashable, Sendable {
    var id: String
    var title: String
    var artist: String?
    var album: String?
    var durationSec: Double?
    var artworkURL: String?
    var format: String?
    var audioQuality: String?
    var audioModes: [String]
    var atmosFlag: Bool
    var streamURL: String?

    var isAtmos: Bool {
        if atmosFlag { return true }
        let text = ([audioQuality, format] + audioModes.map(Optional.some)).compactMap { $0 }.joined(separator: " ").lowercased()
        return ["atmos", "dolby", "eac3-joc", "ec-3"].contains { text.contains($0) }
    }
    var tier: AddonTier? { isAtmos ? nil : AddonTier.infer([audioQuality, format].compactMap { $0 }.joined(separator: " ")) }
    var isHiRes: Bool {
        guard !isAtmos else { return false }
        let t = [audioQuality, format].compactMap { $0 }.joined(separator: " ").lowercased()
        return t.contains("hi-res") || t.contains("hires") || t.contains("hi_res") || t.contains("24-bit")
    }
    /// Sort weight when lossless was asked: hi-res over lossless over the rest.
    var losslessWeight: Int { isHiRes ? 2 : (tier == .lossless ? 1 : 0) }

    static func parseList(_ o: [String: Any]) -> [AddonRow] {
        guard let list = o["tracks"] as? [Any] else { return [] }
        var rows: [AddonRow] = []
        for case let r as [String: Any] in list {
            guard let id = AddonJSON.string(r["id"]) ?? AddonJSON.int(r["id"]).map(String.init), let title = AddonJSON.string(r["title"]) else { continue }
            var modes = AddonJSON.strings(r["audioModes"])
            if let m = AddonJSON.string(r["audioMode"]) { modes.append(m) }
            rows.append(AddonRow(id: id, title: title, artist: AddonJSON.string(r["artist"]), album: AddonJSON.string(r["album"]),
                                 durationSec: AddonJSON.double(r["duration"]).flatMap { $0 > 0 ? $0 : nil },
                                 artworkURL: AddonJSON.string(r["artworkURL"]) ?? AddonJSON.string(r["albumArtworkURL"]),
                                 format: AddonJSON.string(r["format"]), audioQuality: AddonJSON.string(r["audioQuality"]), audioModes: modes,
                                 atmosFlag: AddonJSON.flag(r["atmos"]) ?? false, streamURL: AddonJSON.string(r["streamURL"])))
        }
        return rows
    }
}

// MARK: stream reply

struct AddonStreamResult: Sendable {
    var stream: MusicStream
    var quality: SourceQuality
}

enum AddonStreamOutcome: Sendable {
    case stream(AddonStreamResult)
    /// Not playable from this addon; the next candidate or source is tried. The text is for the log and the test report.
    case miss(String)
}

enum AddonStreamParser {
    private static let knownCodecs: Set<String> = ["flac", "alac", "wav", "aiff", "mp3", "aac", "he-aac", "m4a", "mp4", "ogg", "opus", "vorbis", "webm", "eac3-joc", "ec3-joc"]
    private static let selfDescribing: Set<String> = ["flac", "wav", "mp3", "aiff"]

    /// Applies the acceptance rules to one stream reply. `row` supplies the search row's own `streamURL` and quality text as a fallback.
    static func parse(_ o: [String: Any], row: AddonRow?, base: URL, ownServer: Bool, allowAtmos: Bool = false) -> AddonStreamOutcome {
        let urlText = AddonJSON.string(o["url"]) ?? row?.streamURL
        guard let urlText else {
            if let e = AddonJSON.string(o["error"]) { return .miss("The addon said: \(e)") }
            return .miss("The addon gave no stream address.")
        }
        guard let url = URL(string: urlText), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .miss("The stream address is not a web address.") }
        if let v = AddonURLPolicy.violation(url, ownServer: ownServer) { return .miss(v) }
        // A copy of the server's own origin inside its path is a known concatenation bug. A URL that passes another address as a parameter is fine.
        if let origin = originString(of: url), url.path.contains(origin) { return .miss("The stream address repeats the server's own address.") }
        if let enc = o["encrypted"] {
            if let b = enc as? Bool { if b { return .miss("The stream is protected by DRM.") } }
            else if let s = AddonJSON.string(enc)?.lowercased(), !["false", "none", "no", "0"].contains(s) { return .miss("The stream is protected by DRM.") }
        }
        let qualityText = ["quality", "streamQuality", "audioQuality"].compactMap { AddonJSON.string(o[$0]) }.joined(separator: " ")
            + " " + (row?.audioQuality ?? "")
        let formatText = AddonJSON.string(o["format"])?.lowercased() ?? row?.format?.lowercased() ?? ""
        let container = (AddonJSON.string(o["container"]) ?? AddonJSON.string(o["containerFormat"]))?.lowercased()
        let mime = AddonJSON.string(o["mimeType"])?.lowercased()
        let modes = AddonJSON.strings(o["audioModes"]) + [AddonJSON.string(o["audioMode"])].compactMap { $0 } + (row?.audioModes ?? [])
        let declaredCodec = (AddonJSON.string(o["codec"]) ?? AddonJSON.string(o["fileCodec"]))?.lowercased()

        // Immersive audio is refused here, not just ranked low, because it is often the only rendition offered and this device cannot play it.
        let atmosText = ([qualityText, formatText, declaredCodec ?? ""] + modes).joined(separator: " ").lowercased()
        let atmos = (row?.atmosFlag ?? false) || ["atmos", "dolby", "eac3-joc", "ec-3"].contains { atmosText.contains($0) }
        if atmos && !allowAtmos { return .miss("Dolby Atmos is not supported here.") }

        var proto = MusicStreamProtocol.progressive
        let transportWords = [AddonJSON.string(o["manifest"]), AddonJSON.string(o["mediaType"]), AddonJSON.string(o["format"]), mime].compactMap { $0?.lowercased() }.joined(separator: " ")
        if ["dash", "mpd"].contains(where: { transportWords.contains($0) }) { return .miss("The stream is DASH, which this player cannot open.") }
        if ["hls", "m3u8", "mpegurl"].contains(where: { transportWords.contains($0) }) { proto = .hls }

        // Codec: stated, else a self-describing container or format, else the mime subtype, else lossless text, else the file extension.
        var codec: String?
        if let d = declaredCodec, knownCodecs.contains(d) { codec = d }
        if codec == nil, let c = container, selfDescribing.contains(c) { codec = c }
        if codec == nil, selfDescribing.contains(formatText) { codec = formatText }
        if codec == nil, let m = mime, let sub = m.split(separator: "/").last.map(String.init) {
            let s = sub.replacingOccurrences(of: "x-", with: "").replacingOccurrences(of: "mpeg", with: "mp3")
            if knownCodecs.contains(s) { codec = s }
        }
        let lowerQuality = qualityText.lowercased()
        if codec == nil, lowerQuality.contains("alac") { codec = "alac" }
        if codec == nil, lowerQuality.contains("lossless") || lowerQuality.contains("flac") { codec = "flac" }
        if codec == nil {
            let ext = url.pathExtension.lowercased()
            if knownCodecs.contains(ext) { codec = ext }
        }
        if codec == nil, knownCodecs.contains(formatText) { codec = formatText }

        var kbps: Int?; var inferred = false
        if let b = AddonJSON.int(o["bitrate"]), b > 0 { kbps = b > 3000 ? b / 1000 : b }
        else if let m = qualityText.range(of: "(\\d{2,4})\\s*kbps", options: [.regularExpression, .caseInsensitive]) {
            kbps = Int(qualityText[m].filter(\.isNumber))
        }
        let tier = AddonTier.infer(qualityText + " " + formatText)
        var sampleRate: Int?
        if let sr = AddonJSON.double(o["sampleRate"]), sr > 0 { sampleRate = sr < 1000 ? Int(sr * 1000) : Int(sr) }
        else if let m = qualityText.range(of: "(\\d{2,3}(?:\\.\\d)?)\\s*khz", options: [.regularExpression, .caseInsensitive]) {
            let digits = qualityText[m].lowercased().replacingOccurrences(of: "khz", with: "").trimmingCharacters(in: .whitespaces)
            sampleRate = Double(digits).map { Int($0 * 1000) }
        }
        var bitDepth: Int?
        if let d = AddonJSON.int(o["bitDepth"]), (8...32).contains(d) { bitDepth = d }
        else if let m = qualityText.range(of: "(\\d{1,2})\\s*-?\\s*bit", options: [.regularExpression, .caseInsensitive]),
                let d = Int(qualityText[m].filter(\.isNumber)), (8...32).contains(d) { bitDepth = d }

        let lossless: Bool? = codec.map { ["flac", "alac", "wav", "aiff", "ape", "wv", "dsf", "dff"].contains($0) }
        if lossless != true, kbps == nil, let t = tier, t != .lossless { kbps = t == .high ? 320 : 128; inferred = true }

        let quality = SourceQuality(codec: codec, kbps: lossless == true ? nil : kbps, kbpsInferred: inferred, sampleRate: sampleRate,
                                    bitDepth: bitDepth, isLossless: lossless, isAtmos: atmos)
        // The app's stream type treats "no bitrate and a sample rate" as lossless, so each side is filled in to match what was claimed.
        var stream = MusicStream(url: url.absoluteString, codec: codec ?? "unknown", container: container ?? codec ?? "unknown", proto: proto)
        if lossless == true { stream.bitrate = nil; stream.sampleRate = sampleRate ?? 44_100 }
        else { stream.bitrate = kbps ?? 192; stream.sampleRate = sampleRate }
        if let secs = AddonJSON.double(o["expiresIn"]), secs > 0 { stream.expiresAt = Date().addingTimeInterval(min(secs, 6 * 3600)) }
        return .stream(AddonStreamResult(stream: stream, quality: quality))
    }

    private static func originString(of url: URL) -> String? {
        guard let s = url.scheme, let h = url.host else { return nil }
        return "\(s)://\(h)"
    }
}

// MARK: transport

/// Waits out a rate limit once for every call to the same addon.
actor AddonRateGate {
    private var holdUntil: Date = .distantPast
    func wait(now: @Sendable () -> Date, sleep: @Sendable (TimeInterval) async -> Void) async {
        let d = holdUntil.timeIntervalSince(now())
        if d > 0 { await sleep(d) }
    }
    func hold(_ seconds: TimeInterval, now: Date) { holdUntil = max(holdUntil, now.addingTimeInterval(seconds)) }
}

enum AddonLimits {
    static let metadataBytes = 2 * 1024 * 1024
    static let streamBytes = 256 * 1024
    /// Whole-call limit. The protocol asks for search under 5 s and stream under 3 s, but a cold lossless fetch can take far longer.
    static let callSeconds: TimeInterval = 45
    static let maxRetries = 2
    static let rowLimit = 15
}

/// One addon's connection: address rules, the optional access token, size and time limits, and the 429 back-off.
struct AddonTransport: Sendable {
    var http: MusicHTTP
    var token: String?
    var ownServer: Bool
    var gate = AddonRateGate()
    var now: @Sendable () -> Date = { Date() }
    var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }
    var callSeconds: TimeInterval = AddonLimits.callSeconds

    func getData(_ url: URL, query: [String: String] = [:], maxBytes: Int) async throws -> Data {
        if let v = AddonURLPolicy.violation(url, ownServer: ownServer) { throw AddonProblem.blocked(v) }
        let headers: [String: String] = {
            var h = ["Accept": "application/json"]
            if let token, !token.isEmpty { h["Authorization"] = "Bearer " + token }
            return h
        }()
        var attempt = 0
        while true {
            await gate.wait(now: now, sleep: sleep)
            do {
                let data = try await Self.withDeadline(callSeconds) { try await http.get(url, query: query, headers: headers) }
                if data.count > maxBytes { throw MusicError.network("reply too large") }
                return data
            } catch MusicError.rateLimited(let after) {
                attempt += 1
                let wait = min(8, max(0.5, after ?? 0.5 * pow(2, Double(attempt - 1))))
                await gate.hold(wait, now: now())
                if attempt > AddonLimits.maxRetries { throw MusicError.network("HTTP 429") }
            }
        }
    }

    static func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.01, seconds) * 1_000_000_000))
                throw MusicError.network("timed out")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw MusicError.network("timed out") }
            return first
        }
    }

    /// `<base>/<segments...>` with each segment encoded so a `/` or `?` inside an id cannot change the endpoint. The base may carry a token in its path.
    static func endpoint(_ base: URL, _ segments: [String]) -> URL? {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        var path = c.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        for s in segments { path += "/" + (s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }
        c.percentEncodedPath = path; c.query = nil; c.fragment = nil
        return c.url
    }
}

// MARK: cache

/// Completed answers kept for a while, and one running request shared by every caller asking the same thing. Failures are never kept. The work runs in its
/// own task, so a caller that gives up (a race loser) does not cancel a request already at the server.
actor AddonAnswerCache<V: Sendable> {
    private var done: [String: (value: V, expires: Date)] = [:]
    private var running: [String: Task<V, Error>] = [:]
    private var order: [String] = []
    private let capacity: Int

    init(capacity: Int = 128) { self.capacity = capacity }

    func value(_ key: String, ttl: TimeInterval, now: Date, load: @escaping @Sendable () async throws -> V) async throws -> V {
        if let d = done[key], d.expires > now { return d.value }
        if let t = running[key] { return try await Self.waitCancellable(t) }
        let expires = now.addingTimeInterval(ttl)
        let task = Task { [weak self] () async throws -> V in
            do {
                let v = try await load()
                await self?.complete(key, value: v, expires: expires)
                return v
            } catch {
                await self?.complete(key, value: nil, expires: expires)
                throw error
            }
        }
        running[key] = task
        return try await Self.waitCancellable(task)
    }

    private func complete(_ key: String, value: V?, expires: Date) {
        running[key] = nil
        guard let value else { return }
        done[key] = (value, expires)
        order.removeAll { $0 == key }; order.append(key)
        while order.count > capacity { done[order.removeFirst()] = nil }
    }

    /// Waits for a shared task but gives up at once when the waiter is cancelled; the task itself keeps running for the other callers.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<V, Error>?
        private var result: Result<V, Error>?
        func install(_ c: CheckedContinuation<V, Error>) {
            lock.lock(); defer { lock.unlock() }
            if let r = result { c.resume(with: r); result = nil } else { cont = c }
        }
        func finish(_ r: Result<V, Error>) {
            lock.lock(); defer { lock.unlock() }
            if let c = cont { cont = nil; c.resume(with: r); result = nil } else if result == nil { result = r }
        }
    }
    private static func waitCancellable(_ task: Task<V, Error>) async throws -> V {
        let once = Once()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<V, Error>) in
                once.install(c)
                Task { do { once.finish(.success(try await task.value)) } catch { once.finish(.failure(error)) } }
            }
        } onCancel: { once.finish(.failure(CancellationError())) }
    }

    /// Forgets completed answers (not running ones) so an empty answer can be asked again.
    func clear() { done = [:]; order = [] }
}

// MARK: client

/// What the addon is configured as, with the address and token already read from the Keychain.
struct AddonEndpoint: Sendable {
    var id: String
    var name: String
    var base: URL
    var token: String?
    var ownServer: Bool
    var pickedQuality: String?
    var allowDownloads: Bool = true
}

/// Talks the addon protocol to one server.
final class AddonClient: Sendable {
    let endpoint: AddonEndpoint
    private let transport: AddonTransport
    private let now: @Sendable () -> Date
    private let manifestCache = AddonAnswerCache<AddonManifest?>(capacity: 4)
    private let searchCache = AddonAnswerCache<[AddonRow]>()
    private let streamCache = AddonAnswerCache<AddonStreamOutcome>()

    init(endpoint: AddonEndpoint, http: MusicHTTP = MusicHTTP(), now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }) {
        self.endpoint = endpoint
        self.now = now
        var t = AddonTransport(http: http, token: endpoint.token, ownServer: endpoint.ownServer)
        t.now = now; t.sleep = sleep
        self.transport = t
    }

    /// nil when the addon has no manifest (a 404 is not a failure; the protocol makes the manifest optional).
    func manifest() async throws -> AddonManifest? {
        let base = endpoint.base, t = transport
        return try await manifestCache.value("m", ttl: 600, now: now()) {
            guard let url = AddonTransport.endpoint(base, ["manifest.json"]) else { throw AddonProblem.blocked("Bad address.") }
            do {
                let obj = try AddonJSON.object(try await t.getData(url, maxBytes: AddonLimits.metadataBytes))
                return AddonManifest.parse(obj)
            } catch MusicError.notFound { return nil }
        }
    }

    func search(q: String, title: String? = nil, artist: String? = nil, request: AddonRequest) async throws -> [AddonRow] {
        let manifest = (try? await manifest()) ?? nil
        let params = AddonQuery.parameters(manifest: manifest, request: request, picked: endpoint.pickedQuality, q: q, title: title, artist: artist)
        let key = params.sorted { $0.key < $1.key }.map { "\($0.key.count):\($0.key)=\($0.value.count):\($0.value)" }.joined(separator: "&")
        let base = endpoint.base, t = transport
        return try await searchCache.value(key, ttl: 600, now: now()) {
            guard let url = AddonTransport.endpoint(base, ["search"]) else { throw AddonProblem.blocked("Bad address.") }
            let obj = try AddonJSON.object(try await t.getData(url, query: params, maxBytes: AddonLimits.metadataBytes))
            guard obj["tracks"] is [Any] else { throw MusicError.network("unexpected reply") }
            return AddonRow.parseList(obj)
        }
    }

    /// Asks `/stream/<id>`; falls back to the row's own `streamURL` when the addon has nothing for it.
    func stream(row: AddonRow, request: AddonRequest) async throws -> AddonStreamOutcome {
        let manifest = (try? await manifest()) ?? nil
        let params = AddonQuery.parameters(manifest: manifest, request: request, picked: endpoint.pickedQuality, q: nil, title: nil, artist: nil)
        let key = row.id.count.description + ":" + row.id + "|" + params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let base = endpoint.base, t = transport, own = endpoint.ownServer
        return try await streamCache.value(key, ttl: 300, now: now()) {
            guard let url = AddonTransport.endpoint(base, ["stream", row.id]) else { return .miss("Bad stream address.") }
            do {
                let obj = try AddonJSON.object(try await t.getData(url, query: params, maxBytes: AddonLimits.streamBytes))
                let out = AddonStreamParser.parse(obj, row: row, base: base, ownServer: own)
                if case .miss = out, row.streamURL != nil, AddonJSON.string(obj["url"]) == nil {
                    return AddonStreamParser.parse([:], row: row, base: base, ownServer: own)
                }
                return out
            } catch MusicError.notFound {
                if row.streamURL != nil { return AddonStreamParser.parse([:], row: row, base: base, ownServer: own) }
                return .miss("The addon has no stream for that recording.")
            }
        }
    }

    func clearAnswers() async { await searchCache.clear(); await streamCache.clear() }
}

// MARK: provider

/// One added addon as an audio provider. It is not placed in the registry: the source chain owns the addons, so adding one never switches anything else on.
struct AddonAudioProvider: MusicAudioProvider {
    static let idPrefix = "addon."
    let client: AddonClient
    let displayName: String

    init(client: AddonClient, displayName: String) { self.client = client; self.displayName = displayName }

    var info: MusicProviderInfo {
        MusicProviderInfo(id: Self.idPrefix + client.endpoint.id, name: displayName, summary: "An audio source you added by address.",
                          version: "1.0.0", kind: .builtIn, requiresSignIn: false,
                          privacyNote: "For each song it is asked about, this addon sees the title and artist and your internet address. Nothing runs on your Mac from the addon.",
                          homepage: nil)
    }
    var capabilities: MusicCapabilities { [.audio] }

    /// Queries for a known song: "title artist", then the title alone (catalogues that credit the composer). A source that errors gets no second query.
    func rows(for track: MusicTrack, request: AddonRequest) async throws -> [AddonRow] {
        let parts = AddonMatcher.parse(track.title)
        let title = parts.cleanTitle.isEmpty ? track.title : parts.cleanTitle
        let artist = AddonMatcher.primaryArtist(track.artists.map(\.name))
        for q in [[title, artist].filter { !$0.isEmpty }.joined(separator: " "), title] {
            let rows = try await client.search(q: q, title: title, artist: artist, request: request)
            if !rows.isEmpty { return Array(rows.prefix(AddonLimits.rowLimit)) }
        }
        return []
    }

    func sources(for track: MusicTrack) async throws -> [MusicAudioSource] {
        try await rows(for: track, request: .best).map { r in
            MusicAudioSource(id: r.id, providerID: info.id, title: r.title, artist: r.artist, album: r.album, durationMs: r.durationSec.map { Int64($0 * 1000) },
                             thumbnails: r.artworkURL.map { [MusicThumbnail(url: $0)] } ?? [], externalURL: nil, confidence: 0.6)
        }
    }

    func streams(for source: MusicAudioSource) async throws -> [MusicStream] {
        let row = AddonRow(id: source.id, title: source.title, artist: source.artist, album: source.album, durationSec: nil, artworkURL: nil,
                           format: nil, audioQuality: nil, audioModes: [], atmosFlag: false, streamURL: nil)
        if case .stream(let r) = try await client.stream(row: row, request: .best) { return [r.stream] }
        return []
    }
}

extension AddonAudioProvider: MusicStreamEvicting {
    /// A stream that failed is dropped from the addon's answer cache, so the retry asks the addon again.
    func evictStreams(for source: MusicAudioSource) async { await client.clearAnswers() }
}

// MARK: identifying a pasted address

struct AddonIdentity: Sendable {
    var base: URL
    var manifest: AddonManifest
    /// False when no manifest answered and one was made up after a successful search probe.
    var hasManifest: Bool
}

enum AddonFormatDetector {
    enum Detected { case addon(AddonManifest), unsupported(String), unknown }

    /// Scheme and host lower case, path case kept (it can hold a token), no trailing slash, no default port, no query or fragment, no `*.json` last segment.
    static func canonicalBase(_ raw: String) -> URL? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        guard var c = URLComponents(string: t), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https", c.host?.isEmpty == false else { return nil }
        c.scheme = scheme; c.host = c.host?.lowercased(); c.query = nil; c.fragment = nil
        if (scheme == "https" && c.port == 443) || (scheme == "http" && c.port == 80) { c.port = nil }
        var comps = c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let last = comps.last, last.lowercased().hasSuffix(".json") { comps.removeLast() }
        c.percentEncodedPath = comps.isEmpty ? "" : "/" + comps.joined(separator: "/")
        return c.url
    }

    static func detect(_ o: [String: Any]) -> Detected {
        if o.keys.contains(where: { $0.hasPrefix("category:") }) { return .unsupported("That is a plug-in index. This app never runs downloaded code; add a web addon address instead.") }
        if AddonManifest.looksLikeManifest(o), let m = AddonManifest.parse(o) {
            if !m.resources.isEmpty && !m.resources.contains("search") {
                return .unsupported("This addon offers \(m.resources.joined(separator: ", ")) but this app needs search.")
            }
            return .addon(m)
        }
        if let key = o.first(where: { ($0.value as? [Any])?.isEmpty == false })?.key { return .unsupported("That JSON lists \"\(key)\", which is not a format this app reads.") }
        return .unsupported("Unrecognised JSON. It holds: \(o.keys.sorted().prefix(4).joined(separator: ", ")).")
    }

    /// Works out what a pasted address is. Accepts the addon's root or its manifest link.
    static func identify(_ raw: String, ownServer: Bool, token: String? = nil, http: MusicHTTP = MusicHTTP(), transport custom: AddonTransport? = nil) async throws -> AddonIdentity {
        guard let base = canonicalBase(raw) else { throw AddonProblem.notRecognised("That does not look like a web address.") }
        if let v = AddonURLPolicy.violation(base, ownServer: ownServer) { throw AddonProblem.blocked(v) }
        let transport = custom ?? AddonTransport(http: http, token: token, ownServer: ownServer)
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let typedJSON = typed.split(separator: "?").first.map { $0.hasSuffix(".json") } ?? false
        let typedURL: URL? = {
            var t = raw.trimmingCharacters(in: .whitespacesAndNewlines); while t.hasSuffix("/") { t.removeLast() }
            return URL(string: t)
        }()
        let manifestURL = AddonTransport.endpoint(base, ["manifest.json"])
        let attempts: [URL] = typedJSON ? [typedURL, manifestURL].compactMap { $0 } : [manifestURL, typedURL].compactMap { $0 }
        var firstUnsupported: AddonProblem?
        var firstFailure: AddonProblem?
        for url in attempts {
            do {
                let data = try await transport.getData(url, maxBytes: AddonLimits.metadataBytes)
                guard let obj = try? AddonJSON.object(data) else {
                    firstUnsupported = firstUnsupported ?? .unsupported("That address answered with something other than a JSON object.")
                    continue
                }
                switch detect(obj) {
                case .addon(let m): return AddonIdentity(base: base, manifest: m, hasManifest: true)
                case .unsupported(let s): firstUnsupported = firstUnsupported ?? .unsupported(s)
                case .unknown: break
                }
            } catch MusicError.notFound { continue
            } catch let p as AddonProblem { throw p
            } catch MusicError.cancelled { throw MusicError.cancelled
            } catch { firstFailure = firstFailure ?? AddonProblem.classify(error) }
        }
        // A manifest is optional: an address that answers a plain search is accepted.
        if let search = AddonTransport.endpoint(base, ["search"]) {
            do {
                let obj = try AddonJSON.object(try await transport.getData(search, query: ["q": "music"], maxBytes: AddonLimits.metadataBytes))
                if obj["tracks"] is [Any] { return AddonIdentity(base: base, manifest: .synthesised(base: base), hasManifest: false) }
            } catch MusicError.notFound { // nothing served here: not a failure, just not an addon
            } catch MusicError.cancelled { throw MusicError.cancelled
            } catch { firstFailure = firstFailure ?? AddonProblem.classify(error) }
        }
        if let u = firstUnsupported { throw u }
        if let f = firstFailure { throw f }
        throw AddonProblem.notRecognised("Nothing answered at that address.")
    }
}
