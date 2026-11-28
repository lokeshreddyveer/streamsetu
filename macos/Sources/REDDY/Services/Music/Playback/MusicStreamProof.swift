import Foundation

/// What the player already knows about stream addresses it has checked: which ones passed, how big they are (so the loopback proxy does not ask
/// again), and which (provider, client) pairs have been passing lately (so a pair with a clean run starts playing before its deep check ends).
/// Memory only; nothing is written to disk.
final class MusicStreamProof: @unchecked Sendable {
    static let shared = MusicStreamProof()
    /// A passed address is remembered this long (stream addresses live for hours).
    static let memory: TimeInterval = 30 * 60
    static let capacity = 128
    /// A pair is trusted after this many passes inside the window, with no failure since.
    static let trustPasses = 3
    static let trustWindow: TimeInterval = 10 * 60

    struct Size: Sendable, Equatable { var total: Int64; var contentType: String? }

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var passed: [String: Date] = [:]
    private var sizes: [String: Size] = [:]
    private var order: [String] = []
    private var passes: [String: [Date]] = [:]
    private var lateHandler: (@Sendable (_ url: String, _ reason: String) -> Void)?
    /// A plain phrase for why the last late check refused each address (kept briefly, newest sixteen).
    private var lateNotes: [String: String] = [:]
    private var lateNoteOrder: [String] = []

    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    // MARK: addresses

    func markPassed(_ url: String, size: Size? = nil) {
        lock.withLock {
            touch(url)
            passed[url] = now()
            if let size { sizes[url] = size }
        }
    }

    /// The size is known (from the stream list or a first read) but the address is not proven yet.
    func seed(_ url: String, size: Size) { lock.withLock { touch(url); sizes[url] = size } }

    func isPassed(_ url: String) -> Bool {
        lock.withLock {
            guard let t = passed[url] else { return false }
            if now().timeIntervalSince(t) > Self.memory { passed[url] = nil; return false }
            return true
        }
    }

    func size(of url: String) -> Size? { lock.withLock { sizes[url] } }

    /// Forgets an address (it failed, or it was replaced).
    func forget(_ url: String) { lock.withLock { passed[url] = nil; sizes[url] = nil; order.removeAll { $0 == url } } }

    private func touch(_ url: String) {
        if !order.contains(url) { order.append(url) }
        while order.count > Self.capacity { let old = order.removeFirst(); passed[old] = nil; sizes[old] = nil }
    }

    // MARK: pairs

    /// "provider|client" for the pair that minted an address: a YouTube address names its client, any other host is keyed by its name.
    static func pairKey(provider: String, url: URL?) -> String {
        guard let url else { return provider }
        if let c = MusicProxyPolicy.client(of: url) { return provider + "|" + c }
        return provider + "|" + (url.host?.lowercased() ?? "")
    }

    func recordPass(_ pair: String) {
        let t = now()
        lock.withLock { passes[pair] = (passes[pair] ?? []).filter { t.timeIntervalSince($0) < Self.trustWindow } + [t] }
    }

    func recordFailure(_ pair: String) { lock.withLock { passes[pair] = nil } }

    func isTrusted(_ pair: String) -> Bool {
        let t = now()
        return lock.withLock { (passes[pair] ?? []).filter { t.timeIntervalSince($0) < Self.trustWindow }.count >= Self.trustPasses }
    }

    // MARK: late checks

    /// Called when a check that ran after playback started finds the address is not good. The resolver and player react to it.
    func setLateRejectionHandler(_ h: (@Sendable (_ url: String, _ reason: String) -> Void)?) { lock.withLock { lateHandler = h } }

    func rejectLate(url: String, reason: String, hypothesis: String? = nil) {
        let h: (@Sendable (String, String) -> Void)? = lock.withLock {
            passed[url] = nil
            if let hypothesis {
                if lateNotes[url] == nil { lateNoteOrder.append(url) }
                lateNotes[url] = hypothesis
                while lateNoteOrder.count > 16 { lateNotes[lateNoteOrder.removeFirst()] = nil }
            }
            return lateHandler
        }
        h?(url, reason)
    }

    /// The hypothesis recorded with the last late rejection of this address, if any.
    func lateHypothesis(for url: String) -> String? { lock.withLock { lateNotes[url] } }

    /// Runs the rest of a stream's check after playback has started (the middle and the tail of the file). A failure counts against the pair and
    /// is reported through the late-rejection handler so playback swaps to another address; a pass is remembered. `onRefused` lets a client-level
    /// owner (the YouTube resolver) exclude the client for the video.
    func checkLater(_ stream: MusicStream, total: Int64?, startToo catalogueMs: Int64? = nil, pair: String, reader: @escaping MusicStreamVerifier.Reader,
                    soft: Bool = false, onRefused: (@Sendable () -> Void)? = nil, run: @escaping @Sendable (@escaping @Sendable () async -> Void) -> Void = { work in Task.detached(priority: .utility) { await work() } }) {
        let wasPassed = isPassed(stream.url)
        run { [self] in
            let verdict: MusicProbeVerdict
            if let catalogueMs {
                // A trusted pair started playing before its opening read; the whole check runs now.
                let start = await MusicStreamVerifier.verifyStart(stream, catalogueMs: catalogueMs, reader: reader, proof: self)
                verdict = start.verdict.isOK ? await MusicStreamVerifier.verifyDeep(stream, total: start.total, reader: reader) : start.verdict
            } else {
                verdict = await MusicStreamVerifier.verifyDeep(stream, total: total, reader: reader)
            }
            if verdict.isOK {
                markPassed(stream.url)
                recordPass(pair)
            } else if soft, case .unreachable = verdict {
                // The opening read was good and one later read hiccuped twice: a warning, not a reason to drop an exact video id.
                return
            } else {
                // The same address passing earlier and refused now is an address that ran out; refused with only the opening ever served is a capped client.
                let servedBefore = wasPassed
                recordFailure(pair)
                if case .refused = verdict { onRefused?() }
                rejectLate(url: stream.url, reason: verdict.reason,
                           hypothesis: MusicStreamVerifier.refusalHypothesis(status: MusicStreamVerifier.status(inReason: verdict.reason), servedBefore: servedBefore))
            }
        }
    }
}
