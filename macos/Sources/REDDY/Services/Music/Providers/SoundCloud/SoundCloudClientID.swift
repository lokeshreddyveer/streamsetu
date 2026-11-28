import Foundation

/// How SoundCloud's public web client names itself: a 32 character key written into the script files its home page loads.
/// Pure helpers, so the reading of a page is tested against canned text and never touches the network.
enum SoundCloudSiteKey {
    /// `client_id:"..."`, `client_id = '...'` and the same with a quoted name.
    static let pattern = #"client_id["']?\s*[:=]\s*["']([0-9a-zA-Z]{32})["']"#
    static let scriptPattern = #"https://a-v2\.sndcdn\.com/assets/[A-Za-z0-9_\-\.]+\.js"#

    static func extract(from script: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = script as NSString
        guard let m = re.firstMatch(in: script, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// The script addresses of a home page in the order they appear, without repeats.
    static func scriptURLs(in html: String) -> [URL] {
        guard let re = try? NSRegularExpression(pattern: scriptPattern) else { return [] }
        let ns = html as NSString
        var seen = Set<String>()
        var out: [URL] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range)
            if seen.insert(s).inserted, let u = URL(string: s) { out.append(u) }
        }
        return out
    }
}

/// How long the provider rests after failing. The first miss costs nothing, then it rests 2 minutes, 10 minutes, and an hour from then on.
/// A success ends the rest. Pure, so the ladder is tested without a clock.
struct SoundCloudCooldown: Sendable, Equatable {
    static let ladder: [TimeInterval] = [120, 600, 3600]
    /// Failures in a row before the first rest.
    static let threshold = 2

    private(set) var failures = 0
    private(set) var until: Date?

    /// Records a failure and returns the rest it earned (nil while still under the threshold).
    @discardableResult
    mutating func recordFailure(now: Date) -> TimeInterval? {
        failures += 1
        guard failures >= Self.threshold else { return nil }
        let step = min(failures - Self.threshold, Self.ladder.count - 1)
        let wait = Self.ladder[step]
        until = now.addingTimeInterval(wait)
        return wait
    }

    mutating func recordSuccess() { failures = 0; until = nil }

    func isCooling(now: Date) -> Bool { (until.map { $0 > now }) ?? false }
    func remaining(now: Date) -> TimeInterval { max(0, until?.timeIntervalSince(now) ?? 0) }
}

/// Whether SoundCloud may be asked right now. Every failure class lands here, so one place decides when to rest.
actor SoundCloudHealth {
    private var cooldown = SoundCloudCooldown()
    private let clock: @Sendable () -> Date
    init(clock: @escaping @Sendable () -> Date = { Date() }) { self.clock = clock }

    var isCooling: Bool { cooldown.isCooling(now: clock()) }
    var remaining: TimeInterval { cooldown.remaining(now: clock()) }

    func success() { if cooldown.failures > 0 { MusicDebugLog.log("soundcloud", "health: recovered") }; cooldown.recordSuccess() }

    func failure(_ why: String) {
        let wait = cooldown.recordFailure(now: clock())
        let count = cooldown.failures
        let rest = wait.map { ", resting \(Int($0)) s" } ?? ""
        MusicDebugLog.log("soundcloud", "health: failure (\(why)), \(count) in a row" + rest)
    }
}

/// Finds, keeps and renews the public web key. One scrape at a time: callers that arrive while it runs wait for the same answer. The key is a
/// public value of the web client, not an account secret, so it is kept in the app's preferences with the time it was read. It is never logged.
actor SoundCloudClientID {
    static let ttl: TimeInterval = 12 * 3600
    static let home = URL(string: "https://soundcloud.com")!
    static let maxBundles = 8
    static let maxBundleBytes = 2_000_000
    static let deadline: TimeInterval = 10
    private static let keyDefaults = "music.soundcloud.siteKey", atDefaults = "music.soundcloud.siteKeyAt"
    /// Presented to the home page like a desktop browser does.
    static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private let http: MusicHTTP
    private let health: SoundCloudHealth
    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date
    private var cached: (id: String, at: Date)?
    private var inflight: Task<String, Error>?
    private(set) var scrapes = 0

    init(http: MusicHTTP = MusicHTTP(), health: SoundCloudHealth = SoundCloudHealth(), defaults: UserDefaults = .standard,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http; self.health = health; self.defaults = defaults; self.clock = clock
    }

    /// The key to use now: the one in memory or on disk while it is fresh, otherwise a new one.
    func current() async throws -> String {
        if cached == nil, let id = defaults.string(forKey: Self.keyDefaults), id.count == 32,
           let t = defaults.object(forKey: Self.atDefaults) as? Date { cached = (id, t) }
        if let c = cached, clock().timeIntervalSince(c.at) < Self.ttl { return c.id }
        return try await load()
    }

    /// Called after 401 or 403: forgets the key that was refused (when it is still the current one) and reads a new one.
    func refresh(replacing refused: String?) async throws -> String {
        if let refused, let c = cached, c.id != refused, clock().timeIntervalSince(c.at) < Self.ttl {
            return c.id   // another caller already renewed it
        }
        cached = nil
        defaults.removeObject(forKey: Self.keyDefaults); defaults.removeObject(forKey: Self.atDefaults)
        MusicDebugLog.log("soundcloud", "client key refused, reading a new one")
        return try await load()
    }

    private func load() async throws -> String {
        // The shared task is stored before anything is awaited, so callers that arrive meanwhile join it instead of starting another.
        if let t = inflight { return try await t.value }
        let task = Task { try await self.scrapeIfAllowed() }
        inflight = task
        defer { inflight = nil }
        do {
            let id = try await task.value
            let now = clock()
            cached = (id, now)
            defaults.set(id, forKey: Self.keyDefaults); defaults.set(now, forKey: Self.atDefaults)
            await health.success()
            MusicDebugLog.log("soundcloud", "client key read (length \(id.count))")
            return id
        } catch {
            // A refusal because the provider is already resting is not a new failure.
            if !(await health.isCooling) {
                await health.failure("client key scrape failed")
                MusicDebugLog.log("soundcloud", "client key scrape failed: \((error as? MusicError)?.errorDescription ?? "error")")
            }
            throw error
        }
    }

    private func scrapeIfAllowed() async throws -> String {
        if await health.isCooling { throw MusicError.refused("soundcloud.com") }
        return try await scrape()
    }

    private func scrape() async throws -> String {
        scrapes += 1
        let started = clock()
        let headers = ["User-Agent": Self.browserAgent, "Accept": "text/html"]
        let page = try await http.get(Self.home, headers: headers)
        guard let html = String(data: page, encoding: .utf8) else { throw MusicError.network("unexpected reply") }
        // The key is usually in the last script, so the newest are read first.
        let scripts = Array(SoundCloudSiteKey.scriptURLs(in: html).reversed().prefix(Self.maxBundles))
        for u in scripts {
            try Task.checkCancellation()
            if clock().timeIntervalSince(started) > Self.deadline { break }
            guard let data = try? await http.get(u, headers: ["User-Agent": Self.browserAgent]), data.count <= Self.maxBundleBytes,
                  let text = String(data: data, encoding: .utf8) else { continue }
            if let id = SoundCloudSiteKey.extract(from: text) { return id }
        }
        throw MusicError.network("SoundCloud's page did not carry a client key")
    }
}
