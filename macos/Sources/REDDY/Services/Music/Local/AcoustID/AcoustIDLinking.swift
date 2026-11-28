import Foundation

/// The states AcoustID documents for a linked user key (the "User key link status" method).
enum AcoustIDLinkState: String, Codable, Sendable, CaseIterable { case pending, approved, declined, expired, revoked, unknown }

/// What the person has to do or know after a link ends without approval.
enum AcoustIDLinkOutcome: String, Codable, Sendable { case declined, expired, revoked, unknown }

/// What the app keeps about a link it asked for: the code and address the person approves with and when they stop working. The key itself is kept apart.
struct AcoustIDLinkRecord: Codable, Equatable, Sendable {
    var code: String
    var url: String
    var expires: Date
    var state: AcoustIDLinkState
}

struct AcoustIDLinkRequest: Equatable, Sendable {
    var userKey: String
    var record: AcoustIDLinkRecord
}

enum AcoustIDLinkParser {
    private static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// {"status":"ok","user":{"apikey":…,"link":{"code":…,"url":…,"expires":…}}}
    static func requestLink(_ data: Data) -> Result<AcoustIDLinkRequest, AcoustIDError> {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.network("unreadable reply")) }
        if let e = AcoustIDParser.error(in: j) { return .failure(e) }
        guard let u = j["user"] as? [String: Any], let key = u["apikey"] as? String, !key.isEmpty, let l = u["link"] as? [String: Any],
              let code = l["code"] as? String, let url = l["url"] as? String, let expires = date(l["expires"] as? String) else { return .failure(.network("unexpected reply")) }
        return .success(AcoustIDLinkRequest(userKey: key, record: AcoustIDLinkRecord(code: code, url: url, expires: expires, state: .pending)))
    }

    /// {"status":"ok","key":{"state":"pending","expires":…}}. A state this app does not know is an error, never a reason to throw the key away.
    static func status(_ data: Data) -> Result<AcoustIDLinkState, AcoustIDError> {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.network("unreadable reply")) }
        if let e = AcoustIDParser.error(in: j) { return .failure(e) }
        guard let k = j["key"] as? [String: Any], let s = k["state"] as? String, let state = AcoustIDLinkState(rawValue: s) else { return .failure(.network("unexpected reply")) }
        return .success(state)
    }
}

enum AcoustIDLinkRules {
    enum Action: Equatable { case keepWaiting, activate, discard(AcoustIDLinkOutcome) }

    /// What to do with a stored link given the state AcoustID reports. A pending link past its time is over, whatever the server has not yet said.
    static func action(for state: AcoustIDLinkState, expires: Date, now: Date) -> Action {
        switch state {
        case .approved: return .activate
        case .pending: return now >= expires ? .discard(.expired) : .keepWaiting
        case .declined: return .discard(.declined)
        case .expired: return .discard(.expired)
        case .revoked: return .discard(.revoked)
        case .unknown: return .discard(.unknown)
        }
    }

    /// A new link request is made only when there is nothing usable: no key, or a pending link whose time has run out.
    static func needsNewRequest(record: AcoustIDLinkRecord?, hasKey: Bool, now: Date) -> Bool {
        guard hasKey else { return true }
        guard let record else { return false }          // a manual key stands as it is
        return record.state == .pending && now >= record.expires
    }
}

/// Keys never appear in anything shown or recorded: any text that may echo one is cleaned first.
enum AcoustIDRedactor {
    static func redact(_ text: String, keys: [String?]) -> String {
        var out = text
        for k in keys.compactMap({ $0 }) where k.count >= 6 { out = out.replacingOccurrences(of: k, with: "••••") }
        return out
    }
}

/// The person's connection to AcoustID: asking for a link, waiting for approval, using the key only once it is approved, and letting go of it again. The
/// stored key and link record live in the same Keychain store as every other key.
actor AcoustIDConnection {
    enum Status: Equatable, Sendable {
        case notConnected
        case pending(code: String, url: String, expires: Date)
        case connected(manual: Bool)
        case ended(AcoustIDLinkOutcome)
        case failed(AcoustIDError)
    }

    private let client: AcoustIDClient
    private let now: @Sendable () -> Date
    private let device: @Sendable () -> String

    init(client: AcoustIDClient = AcoustIDClient(), now: @escaping @Sendable () -> Date = { Date() }, device: @escaping @Sendable () -> String = { "StreamSetu (Mac)" }) {
        self.client = client; self.now = now; self.device = device
    }

    private var keys: AcoustIDKeys { client.keys }

    /// What is stored right now, without asking anyone.
    func current() -> Status {
        guard keys.userKey != nil else { return .notConnected }
        guard let r = keys.link else { return .connected(manual: true) }
        switch r.state {
        case .approved: return .connected(manual: false)
        default: return .pending(code: r.code, url: r.url, expires: r.expires)
        }
    }

    /// Starts a link, or returns the one already waiting. Reopening the screen or relaunching the app never asks AcoustID for a second link.
    func begin() async -> Status {
        let hasKey = keys.userKey != nil
        if !AcoustIDLinkRules.needsNewRequest(record: keys.link, hasKey: hasKey, now: now()) { return current() }
        if hasKey { keys.clearUser() }                    // an expired pending link: forget it before asking again
        do {
            let request = try await client.requestLink(device: device())
            keys.storePendingLink(key: request.userKey, record: request.record)    // stored straight away; not used for lookups until approved
            return current()
        } catch let e as AcoustIDError { return .failed(e) } catch { return .failed(.network("request failed")) }
    }

    /// Asks AcoustID where a waiting link stands and acts on it. A network problem changes nothing.
    func check() async -> Status {
        guard let record = keys.link, let key = keys.userKey else { return current() }
        let state: AcoustIDLinkState
        // A refused key on the status call itself means the application key is wrong: nothing is deleted, and the message is not "waiting".
        do { state = try await client.linkStatus(userKey: key) } catch AcoustIDError.invalidKey { return .failed(.invalidKey) } catch { return current() }
        if record.state == .approved {
            // An approved key is dropped only when AcoustID says it ended (revoked, expired, unknown); a "pending" answer for it changes nothing.
            switch state {
            case .approved, .pending: return current()
            default: if case .discard(let why) = AcoustIDLinkRules.action(for: state, expires: .distantFuture, now: now()) { keys.clearUser(); return .ended(why) }; return current()
            }
        }
        switch AcoustIDLinkRules.action(for: state, expires: record.expires, now: now()) {
        case .activate: keys.markLinkApproved(); return current()
        case .keepWaiting: return current()
        case .discard(let why): keys.clearUser(); return .ended(why)
        }
    }

    /// A lookup said the key is invalid. A key still waiting for approval is not wrong, so its status is checked first and nothing is deleted on a guess.
    func resolveInvalidKey() async -> Status {
        if keys.link != nil { return await check() }
        return current()
    }

    /// Stops waiting. The key is removed from this Mac; the unused code simply runs out.
    func cancel() -> Status { keys.clearUser(); return .notConnected }

    /// Removes the key from this Mac. AcoustID is not told: the key stays valid there until it is disconnected on the person's connected applications page.
    func disconnect() -> Status { keys.clearUser(); return .notConnected }

    /// A key the person pasted from their AcoustID account page. It works with any application and needs no approval.
    func enterManually(_ key: String) -> Status {
        guard keys.setUserKey(key) else { return .failed(.invalidKey) }
        return current()
    }
}
