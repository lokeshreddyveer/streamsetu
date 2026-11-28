import Foundation

/// YouTube sometimes answers every audio request from a connection with "Sign in to confirm you're not a bot", whichever client or video is asked for. Asking more only keeps
/// the refusal going (a song tries several searches, several clients and several candidates, then the queue moves on to the next song and does it all again). So once two different
/// videos have been refused that way within two minutes, every YouTube lookup for a guest stops for fifteen minutes; the song waits (it is never skipped) and the person is told
/// why and what helps. A signed-in account is not checked this way and is never held back. The first audio that plays opens it again at once.
final class YouTubeBotGate: @unchecked Sendable {
    static let shared = YouTubeBotGate()
    /// How long every guest lookup stays stopped once the gate has closed.
    static let cooldown: TimeInterval = 15 * 60
    /// Two different videos refused within this long close it.
    static let window: TimeInterval = 120
    static let message = "YouTube is asking this connection to prove it isn't a bot. Sign in to YouTube Music in Music Settings, or try again later."

    private let lock = NSLock()
    private var refusals: [(video: String, at: Date)] = []
    private var closedUntil: Date?
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    /// True for YouTube's "confirm you're not a bot" refusal (not the age check, which is also "sign in" but about one video).
    static func isBotCheck(status: String, reason: String) -> Bool {
        status == "LOGIN_REQUIRED" && reason.lowercased().contains("not a bot")
    }

    /// Reads a player answer (`playabilityStatus`) and counts it when it is the bot check. Returns true when this refusal closed the gate.
    @discardableResult
    func observe(_ answer: Any?, videoID: String) -> Bool {
        guard let status = (answer as? [String: Any])?["playabilityStatus"] as? [String: Any] else { return false }
        return observe(status: status["status"] as? String ?? "", reason: status["reason"] as? String ?? "", videoID: videoID)
    }

    @discardableResult
    func observe(status: String, reason: String, videoID: String) -> Bool {
        guard Self.isBotCheck(status: status, reason: reason) else { return false }
        return recordRefusal(videoID: videoID)
    }

    /// Counts one refused video. True when this one closed the gate.
    @discardableResult
    func recordRefusal(videoID: String) -> Bool {
        lock.withLock {
            let t = now()
            if let until = closedUntil, until > t { return false }
            refusals = refusals.filter { t.timeIntervalSince($0.at) < Self.window } + [(videoID, t)]
            guard Set(refusals.map(\.video)).count >= 2 else { return false }
            closedUntil = t.addingTimeInterval(Self.cooldown)
            refusals = []
            return true
        }
    }

    var isClosed: Bool { lock.withLock { (closedUntil ?? .distantPast) > now() } }

    /// Seconds until lookups may start again (0 while open).
    var secondsLeft: TimeInterval { lock.withLock { max(0, (closedUntil ?? .distantPast).timeIntervalSince(now())) } }

    /// Audio played: the connection is fine, so the gate opens and the count starts again.
    func reset() { lock.withLock { closedUntil = nil; refusals = [] } }
}

/// Spaces the audio requests ("player" calls) sent to YouTube so that a song's candidates, a queue's preloads and two providers asking at once never arrive as one burst: a burst of
/// requests is one of the things YouTube's bot check reacts to. Nothing is dropped; each request simply waits for its turn.
actor YouTubeRequestPacer {
    static let shared = YouTubeRequestPacer(gap: 0.3)
    private let gap: TimeInterval
    private var next = Date.distantPast
    init(gap: TimeInterval) { self.gap = gap }

    func wait() async {
        let t = Date()
        let start = max(t, next)
        next = start.addingTimeInterval(gap)
        let delay = start.timeIntervalSince(t)
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }
}
