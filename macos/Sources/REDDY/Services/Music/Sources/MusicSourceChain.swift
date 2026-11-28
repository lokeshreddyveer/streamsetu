import Foundation
import os

// The ordered audio chain. Added addons come first (in the person's order), then every other audio provider the registry has switched on; the YouTube
// and Audius style providers take part exactly like addons. Members are asked together, not one after another, and the best answer wins by quality.

// MARK: quality

/// How good one stream is, as claimed by its source: Dolby Atmos over lossless over lossy, lossless by bit depth then sample rate, lossy by kbps.
struct SourceQuality: Hashable, Sendable {
    var codec: String?
    var kbps: Int?
    /// True when the kbps was guessed from a rung word (HIGH means 320), not stated.
    var kbpsInferred: Bool = false
    var sampleRate: Int?
    var bitDepth: Int?
    /// nil means the source did not say.
    var isLossless: Bool?
    var isAtmos: Bool = false

    /// A mid-song swap away from a lossy stream must gain at least this much.
    static let swapMarginKbps = 96
    /// A lossy download only beats the YouTube ladder (top 256 kbps) when it is above this.
    static let downloadFloorKbps = 256

    init(codec: String?, kbps: Int?, kbpsInferred: Bool = false, sampleRate: Int?, bitDepth: Int?, isLossless: Bool?, isAtmos: Bool = false) {
        self.codec = codec; self.kbps = kbps; self.kbpsInferred = kbpsInferred; self.sampleRate = sampleRate
        self.bitDepth = bitDepth; self.isLossless = isLossless; self.isAtmos = isAtmos
    }

    /// For streams from providers that only fill the app's own stream fields.
    init(stream: MusicStream) {
        self.init(codec: stream.codec == "unknown" ? nil : stream.codec, kbps: stream.isLossless ? nil : stream.bitrate, sampleRate: stream.sampleRate, bitDepth: nil,
                  isLossless: stream.isLossless ? true : (stream.bitrate != nil ? false : nil))
    }

    var isLosslessKnown: Bool { isLossless == true }

    /// Ordering used everywhere a choice is made. Equal quality is not "better"; the caller breaks ties by source order.
    static func isBetter(_ a: SourceQuality, than b: SourceQuality) -> Bool {
        if a.isAtmos != b.isAtmos { return a.isAtmos }
        if a.isLosslessKnown != b.isLosslessKnown { return a.isLosslessKnown }
        if a.isLosslessKnown {
            if (a.bitDepth ?? 0) != (b.bitDepth ?? 0) { return (a.bitDepth ?? 0) > (b.bitDepth ?? 0) }
            return (a.sampleRate ?? 0) > (b.sampleRate ?? 0)
        }
        return (a.kbps ?? 0) > (b.kbps ?? 0)
    }

    /// Whether replacing the stream that is playing with `candidate` is worth the glitch. Lossless or Atmos is worth it over lossy; a lossy stream must beat
    /// the playing one by 96 kbps; an unknown rate on either side means no swap; never away from Atmos.
    static func worthSwapping(playing: SourceQuality, candidate: SourceQuality) -> Bool {
        if playing.isAtmos { return candidate.isAtmos && isBetter(candidate, than: playing) }
        if candidate.isAtmos { return true }
        if candidate.isLosslessKnown { return playing.isLosslessKnown ? isBetter(candidate, than: playing) : true }
        if playing.isLosslessKnown { return false }
        guard let p = playing.kbps, let c = candidate.kbps, !playing.kbpsInferred, !candidate.kbpsInferred else { return false }
        return c >= p + swapMarginKbps
    }

    /// A download from a source must be lossless, Atmos, or a lossy copy clearly above what YouTube offers. An unstated rate does not qualify.
    var meetsDownloadFloor: Bool {
        if isLosslessKnown || isAtmos { return true }
        guard let k = kbps, !kbpsInferred else { return false }
        return k > Self.downloadFloorKbps
    }

    var summary: String {
        if isAtmos { return "Dolby Atmos" }
        var parts: [String] = []
        if let c = codec { parts.append(c.uppercased()) }
        if isLosslessKnown {
            if let d = bitDepth { parts.append("\(d)-bit") }
            if let r = sampleRate { parts.append(String(format: "%g kHz", (Double(r) / 100).rounded() / 10)) }
        } else if let k = kbps { parts.append("\(k) kbps") }
        return parts.isEmpty ? "Unknown format" : parts.joined(separator: " · ")
    }
}

// MARK: matching

/// Cross-catalogue matching for addon rows. A row must be the same recording: the same title once packaging is removed, the same version markers in both
/// directions ("Song (Live)" is not "Song"), an overlapping artist and a plausible length.
enum AddonMatcher {
    struct Parts: Equatable, Sendable {
        var cleanTitle: String
        var core: String
        var words: [String]
        var versions: Set<String>
        var context: Set<String>
    }
    struct Scored: Sendable { var row: AddonRow; var score: Int; var credited: Bool }

    private static let versionVocabulary: [String: String] = {
        var m: [String: String] = [:]
        for w in ["remix", "refix", "flip", "bootleg", "mashup", "medley", "live", "concert", "unplugged", "acoustic", "instrumental", "karaoke", "vocal", "acapella",
                  "backing", "stems", "cover", "demo", "reprise", "remake", "rework", "extended", "edit", "version", "mix", "dub", "vip", "session", "sped", "slowed",
                  "reverb", "nightcore", "lofi", "orchestral", "symphonic", "part", "pt", "chapter"] { m[w] = w }
        m["remixes"] = "remix"; m["rmx"] = "remix"; m["vocals"] = "vocal"; m["sessions"] = "session"
        return m
    }()
    private static let neutralAsides = ["album version", "radio edit", "original mix", "single version", "original version", "radio version", "explicit", "clean"]
    private static let trailingNoise: Set<String> = ["song", "video", "audio", "lyrics", "lyric", "official", "full", "hd", "hq", "4k", "mp3", "ost", "soundtrack"]
    private static let trailingTakes: Set<String> = ["instrumental", "karaoke", "acapella", "remix", "rmx", "nightcore"]
    private static let noVocal: Set<String> = ["instrumental", "karaoke", "acapella"]

    static func fold(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
    }

    private static func words(_ s: String) -> [String] {
        fold(s).replacingOccurrences(of: "[^\\p{L}\\p{N}\\s]", with: " ", options: .regularExpression).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func classify(_ aside: String, versions: inout Set<String>, context: inout Set<String>) {
        var text = " " + words(aside).joined(separator: " ") + " "
        for n in neutralAsides { text = text.replacingOccurrences(of: " " + n + " ", with: " ") }
        for w in text.split(separator: " ").map(String.init) {
            if let v = versionVocabulary[w] { versions.insert(v) } else { context.insert(w) }
        }
    }

    static func parse(_ raw: String, artist: String? = nil) -> Parts {
        var t = raw.precomposedStringWithCompatibilityMapping.lowercased()
        for (a, b) in [("（", "("), ("）", ")"), ("［", "["), ("］", "]"), ("【", "["), ("】", "]"), ("「", "("), ("」", ")"), ("『", "("), ("』", ")")] { t = t.replacingOccurrences(of: a, with: b) }
        t = t.replacingOccurrences(of: "\\(\\s*part\\.[^)]*\\)", with: " ", options: .regularExpression)
        var versions = Set<String>(), context = Set<String>()
        for _ in 0..<3 {
            guard let r = t.range(of: "[\\(\\[\\{][^\\)\\]\\}]*[\\)\\]\\}]", options: .regularExpression) else { break }
            classify(String(t[r]), versions: &versions, context: &context)
            t.replaceSubrange(r, with: " ")
        }
        if let r = t.range(of: "[\\(\\[\\{]", options: .regularExpression) {      // an unbalanced bracket takes the rest
            classify(String(t[r.upperBound...]), versions: &versions, context: &context)
            t = String(t[..<r.lowerBound])
        }
        var pieces = [t]
        for sep in [" - ", " – ", " — ", " | "] {
            pieces = pieces.flatMap { $0.components(separatedBy: sep) }
        }
        pieces = pieces.prefix(4).map { $0 }
        var head = pieces.first ?? t
        var tails = Array(pieces.dropFirst())
        if let a = artist, !tails.isEmpty, fold(head).trimmingCharacters(in: .whitespaces) == fold(a).trimmingCharacters(in: .whitespaces) { head = tails.removeFirst() }
        for tail in tails { classify(tail, versions: &versions, context: &context) }
        head = head.replacingOccurrences(of: "\\s+(feat\\.?|ft\\.?|featuring)\\s.*$", with: "", options: .regularExpression)
        var toks = words(head)
        let original = toks
        while toks.count > 1, let last = toks.last {
            if trailingNoise.contains(last) { toks.removeLast() }
            else if trailingTakes.contains(last) { versions.insert(versionVocabulary[last] ?? last); toks.removeLast() }
            else { break }
        }
        if toks.isEmpty { toks = original }
        let core = toks.joined()
        return Parts(cleanTitle: toks.joined(separator: " "), core: core, words: toks, versions: versions, context: context)
    }

    // MARK: artists

    private static func artistNames(_ s: String) -> [String] {
        var t = " " + fold(s) + " "
        t = t.replacingOccurrences(of: "\\s(and|x|vs\\.?|feat\\.?|ft\\.?|featuring|with)\\s", with: ",", options: .regularExpression)
        for ch in ["&", "/", ";", "·", "|", "、", "，", "×"] { t = t.replacingOccurrences(of: ch, with: ",") }
        return t.split(separator: ",").map { words(String($0)).joined(separator: " ") }.filter { $0.count > 1 }
    }

    /// The first credited name, in its original spelling, for the search query.
    static func primaryArtist(_ credits: [String]) -> String {
        for credit in credits {
            let t = credit.replacingOccurrences(of: "\\s(feat\\.?|ft\\.?|featuring|with|and|vs\\.?|x)\\s.*$", with: "", options: [.regularExpression, .caseInsensitive])
            if let first = t.split(whereSeparator: { ",&/;·|、，×".contains($0) }).first {
                let n = first.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { return n }
            }
        }
        return ""
    }

    /// Two names match when one equals the other or contains it as a run of whole words ("Queen" is not inside "Queensryche").
    private static func namesOverlap(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: " ").map(String.init), y = b.split(separator: " ").map(String.init)
        func contains(_ big: [String], _ small: [String]) -> Bool {
            guard !small.isEmpty, small.count <= big.count else { return false }
            return (0...(big.count - small.count)).contains { Array(big[$0..<($0 + small.count)]) == small }
        }
        return contains(x, y) || contains(y, x)
    }

    // MARK: scoring

    /// Rows that are the same recording as `track`, best first. Empty when none qualify.
    static func rank(track: MusicTrack, rows: [AddonRow]) -> [Scored] {
        var want = parse(track.title, artist: track.artists.first?.name)
        if let a = track.album?.title { want.versions.formUnion(parse(a).versions.intersection(noVocal)) }
        let wantArtists = track.artists.flatMap { artistNames($0.name) }
        let wantArtistLine = fold(track.artists.map(\.name).joined(separator: " "))
        let wantSec = track.durationMs > 0 ? Double(track.durationMs) / 1000 : nil
        let wantAlbum = track.album.map { words($0.title).joined(separator: " ") } ?? ""
        var out: [Scored] = []
        for row in rows {
            var have = parse(row.title, artist: row.artist)
            // A no-vocal take named only in the album ("Instrumental Edition") applies to the row both ways.
            if let a = row.album { have.versions.formUnion(parse(a).versions.intersection(noVocal)) }
            guard have.versions == want.versions else { continue }
            let titleOK = !want.core.isEmpty && (have.core == want.core
                || (want.core.count > 3 && have.core.count > 3 && (have.core.contains(want.core) || want.core.contains(have.core))))
            guard titleOK else { continue }
            var score = 100
            var credited = false
            let haveArtists = row.artist.map(artistNames) ?? []
            if wantArtists.isEmpty || haveArtists.isEmpty {
                // Both sides blank scores nothing and vetoes nothing.
            } else if haveArtists.contains(where: { h in wantArtists.contains { namesOverlap($0, h) } }) {
                credited = true
                score += words(row.artist ?? "").joined(separator: " ") == words(wantArtistLine).joined(separator: " ") ? 25 : 10
            } else if let w = wantSec, let d = row.durationSec, abs(w - d) <= 2, track.isVideo != true {
                score -= 30     // composer credited on one side, singer on the other
            } else { continue }
            if let w = wantSec, let d = row.durationSec {
                let diff = abs(w - d)
                if diff > 30 && !(credited && diff <= 90) { continue }
                score += diff <= 3 ? 40 : 15
            }
            if !wantAlbum.isEmpty, let a = row.album, words(a).joined(separator: " ") == wantAlbum { score += 35 }
            if !want.context.isDisjoint(with: have.context) { score += 20 }
            out.append(Scored(row: row, score: score, credited: credited))
        }
        if out.contains(where: \.credited) { out = out.filter(\.credited) }
        return out.enumerated().sorted { ($0.element.score, -$0.offset) > ($1.element.score, -$1.offset) }.map(\.element)
    }

    /// The order rows are opened in: rows within 3 s of the wanted length first (when any agree), and for a lossless request hi-res over lossless over the rest.
    static func preferred(_ rows: [AddonRow], wantedSec: Double?, request: AddonRequest) -> [AddonRow] {
        var rows = rows
        if let w = wantedSec, rows.contains(where: { $0.durationSec.map { abs($0 - w) <= 3 } ?? false }) {
            rows = rows.filter { $0.durationSec.map { abs($0 - w) <= 3 } ?? false }
        }
        if request.isLossless {
            rows = rows.enumerated().sorted { ($0.element.losslessWeight, -$0.offset) > ($1.element.losslessWeight, -$1.offset) }.map(\.element)
        }
        return rows
    }
}

// MARK: failure memory

/// A source that fails is left out for a while, longer each time it fails again in a row. A good answer clears the record.
final class SourceFailureMemory: Sendable {
    static let windows: [TimeInterval] = [60, 300, 900]
    private struct Entry { var count: Int; var until: Date }
    private let state = OSAllocatedUnfairLock(initialState: [String: Entry]())
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    func recordFailure(_ id: String) {
        let t = now()
        state.withLock { s in
            let n = (s[id]?.count ?? 0) + 1
            s[id] = Entry(count: n, until: t.addingTimeInterval(Self.windows[min(n, Self.windows.count) - 1]))
        }
    }
    func recordSuccess(_ id: String) { state.withLock { $0[id] = nil } }
    func isSkipped(_ id: String) -> Bool { let t = now(); return state.withLock { ($0[id]?.until ?? .distantPast) > t } }
    func skippedUntil(_ id: String) -> Date? { let t = now(); return state.withLock { s in s[id].flatMap { $0.until > t ? $0.until : nil } } }
    func reset() { state.withLock { $0 = [:] } }
}

// MARK: file length probe

enum SourceLengthProbe {
    /// Size of the file behind a stream address without downloading it (a HEAD request, 4 s). nil when it cannot be told.
    static func bytes(of urlText: String, headers: [String: String], http: MusicHTTP, timeout: TimeInterval = 4) async -> Int64? {
        guard let url = URL(string: urlText), url.scheme == "https" || url.scheme == "http" else { return nil }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = "HEAD"
        r.setValue(http.userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let transport = http.transport
        let request = r
        guard let (_, resp) = try? await AddonTransport.withDeadline(timeout, { try await transport.data(for: request) }), (200..<300).contains(resp.statusCode) else { return nil }
        if let range = resp.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last.flatMap({ Int64($0) }) { return total }
        if let len = resp.value(forHTTPHeaderField: "Content-Length").flatMap({ Int64($0) }), len > 0 { return len }
        return nil
    }

    /// True when the file is too small to hold the whole song at the lowest plausible rate (a 30 second preview under a full length row).
    /// Floor: 200 kbps for lossless, else the stated rate capped at 64 kbps. Unmeasurable counts as not short.
    static func isTooShort(bytes: Int64?, expectedSeconds: Double?, slackSeconds: Double, quality: SourceQuality) -> Bool {
        guard let bytes, bytes > 0, let expected = expectedSeconds, expected > 0 else { return false }
        let floorKbps = quality.isLosslessKnown ? 200 : min(quality.kbps ?? 64, 64)
        let seconds = Double(bytes) * 8 / Double(max(1, floorKbps) * 1000)
        return seconds < expected - slackSeconds
    }
}

// MARK: chain

/// Supplies the audio chain to `MusicStreamResolver`: set `resolver.chain` and the resolver asks it before its own loop. With no addon added the chain
/// answers `.notUsed` and the resolver behaves exactly as before.
@MainActor
final class MusicSourceChain {
    struct Resolved: Sendable {
        var stream: MusicStream
        var quality: SourceQuality
        var memberID: String
        var memberName: String
        var page: String?
        /// True when a lossless stream was wanted and this is the best that was found.
        var belowRequest: Bool
    }
    enum Outcome: Sendable {
        /// No addon takes part, so the resolver's own loop does the work.
        case notUsed
        case resolved(Resolved)
        /// Every member was asked and none had the song.
        case exhausted
    }

    struct Member: Sendable {
        enum Kind: Sendable { case addon(AddonAudioProvider), generic(any MusicAudioProvider) }
        var id: String; var name: String; var rank: Int; var kind: Kind; var allowsDownload: Bool
    }
    struct Candidate: Sendable {
        var memberID: String; var memberName: String; var rank: Int
        var stream: MusicStream; var quality: SourceQuality; var page: String?; var belowRequest: Bool
        var resolved: Resolved { Resolved(stream: stream, quality: quality, memberID: memberID, memberName: memberName, page: page, belowRequest: belowRequest) }
    }
    struct Report: Sendable { var memberID: String; var candidate: Candidate?; var failed: Bool; var cancelled: Bool; var timedOut: Bool }
    struct Options: Sendable {
        var request: AddonRequest
        var quality: MusicQuality
        var strictLengthSeconds: Double?
        var probeLength: Bool
        var earlyExit: Bool
        var budget: TimeInterval
        var http: MusicHTTP
    }

    let store: AddonStore
    private let registry: MusicRegistry
    let failures: SourceFailureMemory
    var http = MusicHTTP()
    /// Seconds a candidate's length may differ from the song for a swap (the "track length tolerance").
    var lengthTolerance: Double = 5
    /// False while the app is locked or a Kids profile is on: no addon or provider is asked anything.
    var isAllowed = true
    var raceBudget: TimeInterval = 12
    var downloadBudget: TimeInterval = 20
    private var upgradeAsked: Set<String> = []

    init(store: AddonStore, registry: MusicRegistry, failures: SourceFailureMemory = SourceFailureMemory()) {
        self.store = store; self.registry = registry; self.failures = failures
    }

    // MARK: members

    func members(for quality: MusicQuality) -> [Member] {
        var out: [Member] = []
        for (i, a) in store.activeProviders(for: quality).enumerated() {
            out.append(Member(id: a.provider.info.id, name: a.config.displayName, rank: i, kind: .addon(a.provider), allowsDownload: a.config.allowDownloads))
        }
        for (i, p) in registry.audio.enumerated() { out.append(Member(id: p.id, name: p.info.name, rank: 1000 + i, kind: .generic(p), allowsDownload: true)) }
        return out
    }

    // MARK: entry points

    /// The stream for a track that has no stream of its own. Called by the resolver when `resolver.chain` is set.
    func resolve(_ track: MusicTrack, quality: MusicQuality) async -> Outcome {
        guard isAllowed else { return .exhausted }
        let all = members(for: quality)
        guard all.contains(where: { if case .addon = $0.kind { true } else { false } }) else { return .notUsed }
        // Sources that failed lately are asked last, not never: when every source is resting they are all asked, so a track is never refused
        // while a source remains untried.
        let rested = all.filter { !failures.isSkipped($0.id) }
        let live = rested.isEmpty ? all : rested
        let opts = Options(request: AddonRequest(quality), quality: quality, strictLengthSeconds: nil, probeLength: store.checkFileLength, earlyExit: true, budget: raceBudget, http: http)
        let cands = await race(live, track: track, opts: opts)
        guard let best = Self.choose(cands, request: opts.request) else { return .exhausted }
        return .resolved(best.resolved)
    }

    /// A better stream for a song that is already playing, or nil. Asks every other member once per song (`force` asks again). Only a stream worth the
    /// swap is returned: lossless or Atmos over lossy, or 96 kbps better.
    func upgrade(_ track: MusicTrack, playing: SourceQuality, servedBy: String?, quality: MusicQuality, force: Bool = false) async -> Resolved? {
        guard isAllowed else { return nil }
        if !force, upgradeAsked.contains(track.uid) { return nil }
        upgradeAsked.insert(track.uid)
        let live = members(for: quality).filter { $0.id != servedBy && !failures.isSkipped($0.id) }
        guard !live.isEmpty else { return nil }
        let opts = Options(request: AddonRequest(quality), quality: quality, strictLengthSeconds: lengthTolerance, probeLength: false, earlyExit: false, budget: raceBudget, http: http)
        let cands = await race(live, track: track, opts: opts).filter { SourceQuality.worthSwapping(playing: playing, candidate: $0.quality) }
        return Self.choose(cands, request: .best)?.resolved
    }

    /// A source copy for a download, only when it clears the floor (lossless, Atmos or above 256 kbps). Addons that forbid downloads are not asked.
    func downloadCandidate(for track: MusicTrack, quality: MusicQuality) async -> Resolved? {
        guard isAllowed else { return nil }
        let live = members(for: quality).filter { $0.allowsDownload && !failures.isSkipped($0.id) }
        guard !live.isEmpty else { return nil }
        let opts = Options(request: AddonRequest(quality), quality: quality, strictLengthSeconds: 2, probeLength: false, earlyExit: false, budget: downloadBudget, http: http)
        let cands = await race(live, track: track, opts: opts).filter { $0.quality.meetsDownloadFloor }
        return Self.choose(cands, request: .best)?.resolved
    }

    func forgetUpgradeHistory() { upgradeAsked = [] }

    /// Every addon forgets the stream answers it kept (a stream that failed must not come back from an addon's own cache).
    func clearAddonAnswers() async {
        for q in MusicQuality.allCases { for a in store.activeProviders(for: q) { await a.provider.evictStreams(for: MusicAudioSource(id: "", providerID: "", title: "", confidence: 0)) } }
    }

    // MARK: racing

    private func race(_ members: [Member], track: MusicTrack, opts: Options) async -> [Candidate] {
        let reports = await Self.runRace(members, track: track, opts: opts)
        for r in reports where !r.cancelled && !r.timedOut {
            if r.failed { failures.recordFailure(r.memberID) } else { failures.recordSuccess(r.memberID) }
        }
        return reports.compactMap(\.candidate)
    }

    /// Everything is asked at once. A lossless request ends the race at the first genuinely lossless answer; other requests end it when an answer arrives
    /// from a member that has no unfinished member above it. Then whatever already finished is folded in and rank breaks ties.
    nonisolated static func runRace(_ members: [Member], track: MusicTrack, opts: Options) async -> [Report] {
        await withTaskGroup(of: Report.self) { group in
            for m in members { group.addTask { await runMember(m, track: track, opts: opts) } }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, opts.budget) * 1_000_000_000))
                return Report(memberID: "", candidate: nil, failed: false, cancelled: false, timedOut: true)
            }
            var reports: [Report] = []
            var finished = Set<String>()
            for await r in group {
                if r.timedOut { group.cancelAll(); continue }
                reports.append(r); finished.insert(r.memberID)
                if opts.earlyExit, let c = r.candidate, !c.belowRequest {
                    let blockedAbove = members.contains { $0.rank < c.rank && !finished.contains($0.id) }
                    if opts.request.isLossless || !blockedAbove { group.cancelAll() }
                } else if members.allSatisfy({ finished.contains($0.id) }) { group.cancelAll() }
            }
            return reports
        }
    }

    nonisolated static func runMember(_ m: Member, track: MusicTrack, opts: Options) async -> Report {
        do {
            let c: Candidate?
            switch m.kind {
            case .addon(let p): c = try await runAddon(p, member: m, track: track, opts: opts)
            case .generic(let p): c = try await runGeneric(p, member: m, track: track, opts: opts)
            }
            return Report(memberID: m.id, candidate: c, failed: false, cancelled: false, timedOut: false)
        } catch is CancellationError {
            return Report(memberID: m.id, candidate: nil, failed: false, cancelled: true, timedOut: false)
        } catch MusicError.cancelled {
            return Report(memberID: m.id, candidate: nil, failed: false, cancelled: true, timedOut: false)
        } catch {
            // A source that throws costs that source its turn, never the song.
            return Report(memberID: m.id, candidate: nil, failed: true, cancelled: Task.isCancelled, timedOut: false)
        }
    }

    /// Up to three rows are opened. The first stream that meets the request wins; one that falls short is kept as a floor.
    nonisolated static func runAddon(_ p: AddonAudioProvider, member m: Member, track: MusicTrack, opts: Options) async throws -> Candidate? {
        let rows = try await p.rows(for: track, request: opts.request)
        let wanted = track.durationMs > 0 ? Double(track.durationMs) / 1000 : nil
        var ranked = AddonMatcher.rank(track: track, rows: rows).map(\.row)
        if let tol = opts.strictLengthSeconds {
            ranked = ranked.filter { r in
                guard let w = wanted, let d = r.durationSec else { return false }
                return abs(w - d) <= tol
            }
        }
        ranked = AddonMatcher.preferred(ranked, wantedSec: wanted, request: opts.request)
        var best: Candidate?
        var opened = 0, errors = 0
        var lastError: Error?
        for row in ranked.prefix(3) {
            try Task.checkCancellation()
            opened += 1
            let outcome: AddonStreamOutcome
            do { outcome = try await p.client.stream(row: row, request: opts.request) }
            catch is CancellationError { throw CancellationError() }
            catch MusicError.cancelled { throw MusicError.cancelled }
            catch { errors += 1; lastError = error; continue }
            guard case .stream(let r) = outcome else { continue }
            if opts.probeLength {
                let bytes = await SourceLengthProbe.bytes(of: r.stream.url, headers: r.stream.headers, http: opts.http)
                if SourceLengthProbe.isTooShort(bytes: bytes, expectedSeconds: row.durationSec ?? wanted, slackSeconds: 5, quality: r.quality) { continue }
            }
            let below = opts.request.isLossless && !r.quality.isLosslessKnown
            let cand = Candidate(memberID: m.id, memberName: m.name, rank: m.rank, stream: r.stream, quality: r.quality, page: nil, belowRequest: below)
            if !below { return cand }
            if best == nil || SourceQuality.isBetter(cand.quality, than: best!.quality) { best = cand }
        }
        if best == nil, opened > 0, errors == opened, let e = lastError { throw e }
        return best
    }

    /// Any other audio provider, scored with the resolver's own matcher so YouTube and the rest behave as they always did.
    nonisolated static func runGeneric(_ p: any MusicAudioProvider, member m: Member, track: MusicTrack, opts: Options) async throws -> Candidate? {
        let sources = try await p.sources(for: track)
        // The same hard rules as the plain walk (version, artist, runtime, explicit) come before any scoring.
        let scored = MusicCandidateRules.rank(track: track, candidates: sources, minimum: MusicStreamResolver.minimumScore,
                                              limit: MusicStreamResolver.candidatesPerProvider, score: { MusicStreamResolver.score(track: $0, candidate: $1) })
        let wanted = track.durationMs > 0 ? Double(track.durationMs) / 1000 : nil
        for (candidate, _) in scored {
            try Task.checkCancellation()
            if let tol = opts.strictLengthSeconds {
                guard let w = wanted, let d = candidate.durationMs, abs(w - Double(d) / 1000) <= tol else { continue }
            }
            var streams = candidate.streams ?? []
            if streams.isEmpty { streams = (try? await p.streams(for: candidate)) ?? [] }
            if let s = MusicStreamResolver.pick(from: streams, quality: opts.quality) {
                let q = SourceQuality(stream: s)
                return Candidate(memberID: m.id, memberName: m.name, rank: m.rank, stream: s, quality: q, page: candidate.externalURL,
                                 belowRequest: opts.request.isLossless && !q.isLosslessKnown)
            }
        }
        return nil
    }

    // MARK: choosing

    /// Lossless request: candidates that are not "below request" first. Best: higher quality wins, equal quality goes to the higher-ranked source.
    /// Capped: the source order decides, since quality above the cap is not wanted.
    nonisolated static func choose(_ cands: [Candidate], request: AddonRequest) -> Candidate? {
        let pool = cands.contains(where: { !$0.belowRequest }) ? cands.filter { !$0.belowRequest } : cands
        if case .capped = request { return pool.min { $0.rank < $1.rank } }
        return pool.min { a, b in
            if SourceQuality.isBetter(a.quality, than: b.quality) { return true }
            if SourceQuality.isBetter(b.quality, than: a.quality) { return false }
            return a.rank < b.rank
        }
    }
}
