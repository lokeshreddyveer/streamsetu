import Foundation

/// The optional token built into the app (see Scripts/gen-builtin-tmdb.py). It exists in the program only as scrambled bytes and is joined in memory for the moment of a request.
enum BuiltInTMDB {
    static var isAvailable: Bool { token() != nil }
    /// Tests never use the built-in token (so they never reach TMDB, whatever the build contains): it is ignored while a test bundle is loaded.
    private static let underTest = Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") } || ProcessInfo.processInfo.arguments.contains { $0.contains(".xctest") } || ProcessInfo.processInfo.processName.contains("xctest") || ProcessInfo.processInfo.processName.contains("testing-helper")
    static func token() -> String? {
        if underTest { return nil }
        #if STREAMSETU_BUILTIN_TMDB
        return assemble(chunks: GeneratedTMDB.chunks, order: GeneratedTMDB.order, mask: GeneratedTMDB.mask)
        #else
        return nil
        #endif
    }
    /// Joins scrambled chunks (kept apart from their mask) back into text.
    static func assemble(chunks: [[UInt8]], order: [Int], mask: [UInt8]) -> String? {
        var bytes: [UInt8] = []
        for i in order where chunks.indices.contains(i) { bytes += chunks[i] }
        guard bytes.count == mask.count, !bytes.isEmpty else { return nil }
        return String(bytes: zip(bytes, mask).map { $0 ^ $1 }, encoding: .utf8)
    }
}

/// Which TMDB credential a request uses: the person's own key when they entered one, else the built-in token when this build has one, else none.
struct TMDBAccess: @unchecked Sendable {
    enum Source: String, Sendable, Equatable { case own, builtIn, none }
    struct Credential: Sendable { let secret: String; let source: Source
        /// A v4 read-access token (a JWT, or any long token) goes in a header; a v3 key (32 hex) only in the query. The built-in token is always a header.
        var usesHeader: Bool { source == .builtIn || MetadataMatchService.isBearerToken(secret) } }

    static let rejectedKey = "tmdb.builtIn.rejectedAt"
    let ownKey: @Sendable () -> String?
    var builtIn: @Sendable () -> String? = { BuiltInTMDB.token() }
    var defaults: UserDefaults = .standard
    var now: @Sendable () -> Date = { Date() }

    /// After TMDB refuses the built-in token it is left alone for the shared pause (no hammering), then tried once more.
    private var pause: BuiltInKeyPause { BuiltInKeyPause(storageKey: Self.rejectedKey, defaults: defaults, now: now) }
    private func rejected() -> Bool { pause.isPaused }
    var source: Source {
        if let k = ownKey(), !k.isEmpty { return .own }
        if !rejected(), builtIn() != nil { return .builtIn }
        return .none
    }
    var builtInRejected: Bool { rejected() }
    var builtInPresent: Bool { builtIn() != nil }
    func credential() -> Credential? {
        if let k = ownKey(), !k.isEmpty { return Credential(secret: k, source: .own) }
        if !rejected(), let t = builtIn() { return Credential(secret: t, source: .builtIn) }
        return nil
    }
    /// TMDB refused the built-in token (revoked or suspended): stop using it, and remember that.
    func markBuiltInRejected() { pause.reportRefused(ownKeyInUse: !(ownKey() ?? "").isEmpty) }
    func clearRejection() { pause.clear() }

    /// Puts the credential on a request the right way for its kind.
    func sign(_ url: URL, timeout: TimeInterval = 20) -> URLRequest? {
        guard let c = credential() else { return nil }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if !c.usesHeader { let existing = comps?.queryItems ?? []; comps?.queryItems = existing + [URLQueryItem(name: "api_key", value: c.secret)] }
        guard let u = comps?.url else { return nil }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.allowsConstrainedNetworkAccess = true          // Low Data Mode and hotspots never block TMDB
        req.allowsExpensiveNetworkAccess = true
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if c.usesHeader { req.setValue("Bearer " + c.secret, forHTTPHeaderField: "Authorization") }
        return req
    }
}
