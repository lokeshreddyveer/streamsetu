import Foundation
import Security

// The write side of the community lyrics service: an anonymous account made on the first send, submissions, votes and reports.
// Nothing here runs until the person presses Submit, Vote or Report. The account token lives in the Keychain, never in settings or a file.

struct MusicLyricsSession: Codable, Equatable, Sendable {
    var token: String
    var anonymous: Bool
}

protocol MusicLyricsTokenStore: Sendable {
    func load() -> MusicLyricsSession?
    func save(_ s: MusicLyricsSession)
    func clear()
}

/// Keychain item "StreamSetu.Music" / "lyrics.session", this device only.
struct MusicLyricsKeychainStore: MusicLyricsTokenStore {
    static let service = MusicKeychain.service
    static let account = "lyrics.session"

    func load() -> MusicLyricsSession? {
        MusicKeychain.shared.readData(Self.account).flatMap { try? JSONDecoder().decode(MusicLyricsSession.self, from: $0) }
    }

    func save(_ s: MusicLyricsSession) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        MusicKeychain.shared.writeData(Self.account, data)
    }

    func clear() { MusicKeychain.shared.remove(Self.account) }
}

/// For tests: a store that lives in memory.
final class MusicLyricsMemoryStore: MusicLyricsTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: MusicLyricsSession?
    init(_ v: MusicLyricsSession? = nil) { value = v }
    func load() -> MusicLyricsSession? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ s: MusicLyricsSession) { lock.lock(); value = s; lock.unlock() }
    func clear() { lock.lock(); value = nil; lock.unlock() }
}

/// The community lyrics service; the address is owned by its read-side provider.
enum MusicLyricsCommunity {
    static let providerID = MusicLyricsSources.community
    static let label = "Community lyrics"
    static let base = CommunityLyricsProvider.base
}

enum MusicLyricsSubmissionError: Error, Equatable, Sendable {
    case unauthorized, banned, rateLimited, stale, notFound, own, unavailable
    case invalid(String?)
    case unchanged(String?)
    case code(String)

    /// Plain words for the person.
    var message: String {
        switch self {
        case .unauthorized: "You are signed out. Try again to start a new anonymous account."
        case .banned: "This account can no longer send lyrics."
        case .rateLimited: "That's a lot for one hour. Try again later."
        case .stale: "Someone else's version went live after you started."
        case .notFound: "The service has no lyrics filed for this song yet."
        case .own: "You can't rate your own lyrics."
        case .unavailable: "The lyrics service can't be reached right now. Your draft is safe."
        case .invalid(let d): d.map { "The service refused these lyrics: \($0)" } ?? "The service refused these lyrics."
        case .unchanged(let d):
            if let d, let name = MusicLyricsSources.names[d] { "\(name) already has these lyrics word by word." } else { "These lyrics are the same as the ones already live." }
        case .code(let c): "The service answered \(c)."
        }
    }

    /// The service's answer to a failed call: 401 is unauthorized, 429 without a code is rate limiting, a 4xx with a code is that code, anything else is unavailable.
    static func map(status: Int, body: Data) -> MusicLyricsSubmissionError {
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let code = obj?["error"] as? String
        let detail = (obj?["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if status == 401 { return .unauthorized }
        if status == 429 && code == nil { return .rateLimited }
        guard (400..<500).contains(status), let code else { return .unavailable }
        switch code {
        case "unauthorized": return .unauthorized
        case "banned": return .banned
        case "rate_limited": return .rateLimited
        case "stale": return .stale
        case "not_found": return .notFound
        case "own": return .own
        case "invalid": return .invalid(detail)
        case "unchanged": return .unchanged(detail)
        default: return .code(code)
        }
    }
}

enum MusicLyricsReportReason: String, CaseIterable, Sendable, Identifiable {
    case timing, text, wrongSong = "wrong_song", abuse
    var id: String { rawValue }
    var label: String {
        switch self { case .timing: "Timing is off"; case .text: "Wrong words"; case .wrongSong: "Wrong song"; case .abuse: "Spam or abuse" }
    }
}

struct MusicLyricsReceipt: Equatable, Sendable {
    enum Status: String, Sendable { case published, pending }
    var revision: Int
    var status: Status
}

struct MusicLyricsLiveState: Equatable, Sendable {
    var revision: Int?
    var origin: String?
    var authors: [String]
    var up: Int
    var down: Int
    var myVote: Int
    var myPending: Bool
    var rejectedReason: String?
    var rejectedRevision: Int?
}

// MARK: - request bodies (pure)

enum MusicLyricsSubmissionBody {
    static let maxLines = 1000, maxWordsPerLine = 100, maxLineBytes = 500, maxWordBytes = 100, maxNoteBytes = 300

    /// One line as the service reads it: `time_ms`, `text`, `end_time_ms`, `words` (`start_ms`, `end_ms`, `bg`), `agent`, readings.
    static func lineJSON(_ line: MusicLyricLine) -> [String: Any] {
        func word(_ w: MusicLyricWord) -> [String: Any] {
            var d: [String: Any] = ["text": w.text, "start_ms": w.startMs, "end_ms": w.endMs]
            if w.background { d["bg"] = true }
            return d
        }
        var d: [String: Any] = ["time_ms": line.timeMs, "text": line.text, "words": (line.words ?? []).map(word)]
        if let e = line.endMs { d["end_time_ms"] = e }
        if let v = line.voice, MusicLyricsVoices.isValidAgent(v) { d["agent"] = v }
        if let r = line.romanized, !r.isEmpty { d["romanized"] = r }
        if let rw = line.romanizedWords, !rw.isEmpty { d["romanized_words"] = rw.map(word) }
        return d
    }

    static func revisionBody(lines: [MusicLyricLine], title: String, artist: String, album: String?, durationSeconds: Int?, baseRevision: Int?) -> Data? {
        var body: [String: Any] = [
            "lines": lines.map(lineJSON),
            "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
            "artist": artist.trimmingCharacters(in: .whitespacesAndNewlines),
            "base_revision": baseRevision.map { $0 as Any } ?? NSNull(),
        ]
        if let a = album?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty { body["album"] = a }
        if let d = durationSeconds, d > 0 { body["duration"] = d }
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func voteBody(_ value: Int) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["value": max(-1, min(1, value))], options: [.sortedKeys])
    }

    static func reportBody(reason: MusicLyricsReportReason, note: String?) -> Data? {
        var d: [String: Any] = ["reason": reason.rawValue]
        if let n = note?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { d["note"] = clipBytes(n, maxNoteBytes) }
        return try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
    }

    static func clipBytes(_ s: String, _ limit: Int) -> String {
        var out = ""
        var used = 0
        for ch in s {
            let n = String(ch).utf8.count
            if used + n > limit { break }
            out.append(ch); used += n
        }
        return out
    }

    /// The video id goes into a path that carries the token, so it must be exactly eleven plain characters.
    static func isValidFiledID(_ s: String) -> Bool {
        s.utf8.count == 11 && s.unicodeScalars.allSatisfy { ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }

    enum Readiness: Equatable, Sendable {
        case ready
        case blocked(String)
    }

    /// The send button's gate: at least one sung line, at most 1000, every word timed, every break started, and the size limits.
    static func readiness(lines: [MusicLyricLine], untimedWords: Int = 0, untimedBreaks: Int = 0) -> Readiness {
        let sung = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        if sung.isEmpty { return .blocked("Add at least one line of lyrics.") }
        if lines.count > maxLines { return .blocked("There are more than \(maxLines) lines. Remove some to send.") }
        if untimedWords > 0 { return .blocked("Some words are not timed yet.") }
        if untimedBreaks > 0 { return .blocked("An instrumental break has no start yet.") }
        for (i, l) in lines.enumerated() {
            let words = l.words ?? []
            if words.count > maxWordsPerLine || l.text.utf8.count > maxLineBytes || words.contains(where: { $0.text.utf8.count > maxWordBytes }) {
                return .blocked("Line \(i + 1) is too long to send. Split it in two.")
            }
        }
        return .ready
    }
}

// MARK: - client

actor MusicLyricsSubmissionClient {
    static let timeout = 8.0

    private let transport: MusicHTTPTransport
    private let store: MusicLyricsTokenStore
    private let base: URL
    private let userAgent: String
    private var creating: Task<MusicLyricsSession, Error>?

    init(transport: MusicHTTPTransport = URLSessionTransport(), store: MusicLyricsTokenStore = MusicLyricsKeychainStore(),
         base: URL = MusicLyricsCommunity.base, userAgent: String = MusicHTTP().userAgent) {
        self.transport = transport; self.store = store; self.base = base; self.userAgent = userAgent
    }

    var hasSession: Bool { store.load() != nil }

    // MARK: availability

    /// Contributions are offered only when the service says it takes anonymous accounts.
    func supportsAnonymous() async -> Bool {
        guard let (data, _) = try? await raw("GET", "v1/auth/providers", body: nil, token: nil),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return (obj["anonymous"] as? Bool) ?? false
    }

    // MARK: reads

    func state(videoID: String) async throws -> MusicLyricsLiveState {
        guard MusicLyricsSubmissionBody.isValidFiledID(videoID) else { throw MusicLyricsSubmissionError.invalid(nil) }
        let token = store.load()?.token
        let (data, _) = try await raw("GET", "v1/lyrics/\(videoID)/state", body: nil, token: token)
        return Self.parseState(data)
    }

    static func parseState(_ data: Data) -> MusicLyricsLiveState {
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let votes = o["votes"] as? [String: Any]
        let rej = o["my_rejected"] as? [String: Any]
        return MusicLyricsLiveState(
            revision: (o["revision"] as? NSNumber)?.intValue, origin: o["origin"] as? String,
            authors: (o["authors"] as? [String]) ?? [],
            up: (votes?["up"] as? NSNumber)?.intValue ?? 0, down: (votes?["down"] as? NSNumber)?.intValue ?? 0,
            myVote: (o["my_vote"] as? NSNumber)?.intValue ?? 0, myPending: (o["my_pending"] as? NSNumber)?.boolValue ?? false,
            rejectedReason: rej?["reason"] as? String, rejectedRevision: (rej?["revision"] as? NSNumber)?.intValue)
    }

    // MARK: writes

    func submit(filedID: String, lines: [MusicLyricLine], title: String, artist: String, album: String?, durationSeconds: Int?,
                baseRevision: Int?) async throws -> MusicLyricsReceipt {
        guard MusicLyricsSubmissionBody.isValidFiledID(filedID) else { throw MusicLyricsSubmissionError.invalid("The video id is not usable.") }
        guard let body = MusicLyricsSubmissionBody.revisionBody(lines: lines, title: title, artist: artist, album: album,
                                                                 durationSeconds: durationSeconds, baseRevision: baseRevision)
        else { throw MusicLyricsSubmissionError.invalid(nil) }
        let (data, _) = try await authorized("POST", "v1/lyrics/\(filedID)/revisions", body: body)
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let rev = (o?["revision"] as? NSNumber)?.intValue else { throw MusicLyricsSubmissionError.unavailable }
        let status = MusicLyricsReceipt.Status(rawValue: (o?["status"] as? String) ?? "pending") ?? .pending
        return MusicLyricsReceipt(revision: rev, status: status)
    }

    /// 1 up, -1 down, 0 withdraws. Returns the new totals.
    func vote(filedID: String, value: Int) async throws -> (up: Int, down: Int, mine: Int) {
        guard MusicLyricsSubmissionBody.isValidFiledID(filedID), let body = MusicLyricsSubmissionBody.voteBody(value) else { throw MusicLyricsSubmissionError.invalid(nil) }
        let (data, _) = try await authorized("PUT", "v1/lyrics/\(filedID)/vote", body: body)
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((o?["up"] as? NSNumber)?.intValue ?? 0, (o?["down"] as? NSNumber)?.intValue ?? 0, (o?["my_vote"] as? NSNumber)?.intValue ?? value)
    }

    func report(filedID: String, reason: MusicLyricsReportReason, note: String?) async throws {
        guard MusicLyricsSubmissionBody.isValidFiledID(filedID), let body = MusicLyricsSubmissionBody.reportBody(reason: reason, note: note)
        else { throw MusicLyricsSubmissionError.invalid(nil) }
        _ = try await authorized("POST", "v1/lyrics/\(filedID)/reports", body: body)
    }

    /// Forgets the account on this device.
    func signOut() { store.clear() }

    // MARK: plumbing

    private func session() async throws -> MusicLyricsSession {
        if let s = store.load() { return s }
        if let running = creating { return try await running.value }
        let t = Task<MusicLyricsSession, Error> { [self] in
            let (data, _) = try await raw("POST", "v1/auth/anonymous", body: nil, token: nil)
            guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let tok = o["token"] as? String, !tok.isEmpty
            else { throw MusicLyricsSubmissionError.unavailable }
            let s = MusicLyricsSession(token: tok, anonymous: true)
            store.save(s)
            return s
        }
        creating = t
        defer { creating = nil }
        return try await t.value
    }

    /// Runs a call with the account's token, making an anonymous account first when there is none. A 401 for an anonymous account gets one fresh account and one retry.
    private func authorized(_ method: String, _ path: String, body: Data?) async throws -> (Data, Int) {
        let s = try await session()
        do { return try await raw(method, path, body: body, token: s.token) } catch MusicLyricsSubmissionError.unauthorized {
            store.clear()
            guard s.anonymous else { throw MusicLyricsSubmissionError.unauthorized }
            let fresh = try await session()
            return try await raw(method, path, body: body, token: fresh.token)
        }
    }

    private func raw(_ method: String, _ path: String, body: Data?, token: String?) async throws -> (Data, Int) {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else { throw MusicLyricsSubmissionError.unavailable }
        var r = URLRequest(url: url, timeoutInterval: Self.timeout)
        r.httpMethod = method; r.httpBody = body
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let data: Data, resp: HTTPURLResponse
        do { (data, resp) = try await transport.data(for: r) } catch is CancellationError { throw CancellationError() } catch { throw MusicLyricsSubmissionError.unavailable }
        guard (200..<300).contains(resp.statusCode) else { throw MusicLyricsSubmissionError.map(status: resp.statusCode, body: data) }
        return (data, resp.statusCode)
    }
}
