import Foundation
import Observation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Where the Last.fm application key lives for read-only calls (similar artists, tags) that need no session.
enum LastFMKeys {
    typealias Pair = (key: String, secret: String)

    /// The app's built-in application, or nil in tests and in builds without it.
    static func builtIn() -> Pair? {
        guard let k = BuiltInLastFM.apiKey(), let s = BuiltInLastFM.sharedSecret(), !k.isEmpty, !s.isEmpty else { return nil }
        return (k, s)
    }

    /// The person's own key if they entered one (in Settings, or with their own sign-in), otherwise the built-in application.
    /// `secret` is nil only when no secret is available for the key found.
    static func current(store: any ScrobbleSecretStore = ScrobbleKeychainStore(), builtIn: () -> Pair? = LastFMKeys.builtIn) -> (apiKey: String, secret: String?)? {
        if let own = LastFMClient(store: store).appKeys() { return (own.key, own.secret) }
        if let b = builtIn() { return (b.key, b.secret) }
        return nil
    }
}

/// Opens a page in the person's default browser. The only platform-specific part of the Last.fm sign-in.
protocol LastFMBrowserOpening: Sendable {
    @MainActor func open(_ url: URL) -> Bool
}

struct SystemBrowserOpener: LastFMBrowserOpening {
    @MainActor func open(_ url: URL) -> Bool {
        #if os(macOS)
        return NSWorkspace.shared.open(url)
        #elseif os(iOS)
        UIApplication.shared.open(url)
        return true
        #else
        return false
        #endif
    }
}

/// Why a Last.fm sign-in ended without a session. `message` is plain text for the screen.
enum LastFMAuthError: Error, Equatable, Sendable {
    case failed(String)
    case timedOut
    case cancelled

    var message: String {
        switch self {
        case .failed(let m): m
        case .timedOut: "Last.fm was not approved in time. Try again."
        case .cancelled: "Sign-in cancelled."
        }
    }
}

/// Last.fm's desktop-application sign-in with the app's built-in key: get a token, send the person to the approval page in their browser,
/// then ask for the session every couple of seconds until they have approved. Nothing here reads a clock or opens a window by itself,
/// so a test drives it with a stub transport, a fake sleep and a fake opener. Cancelling the surrounding task ends it.
struct LastFMAuth: Sendable {
    static let pollSeconds: TimeInterval = 2
    static let maxSeconds: TimeInterval = 180

    var http: MusicHTTP = MusicHTTP()
    var store: any ScrobbleSecretStore = ScrobbleKeychainStore()
    var keys: @Sendable () -> LastFMKeys.Pair? = { LastFMKeys.builtIn() }
    /// True when `keys` is the built-in application: the stored sign-in then holds no key or secret, only the marker.
    var usesBuiltInApp = true
    var opener: any LastFMBrowserOpening = SystemBrowserOpener()
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }

    /// Runs the whole sign-in and returns the Last.fm user name. The session is already stored when this returns.
    func connect() async throws -> String {
        guard let k = keys() else { throw LastFMAuthError.failed("Last.fm sign-in is not available in this build. Use your own Last.fm key.") }
        let token = try await requestToken(k)
        guard let url = LastFMClient.authURL(apiKey: k.key, token: token) else { throw LastFMAuthError.failed("Last.fm sent a bad address.") }
        guard await opener.open(url) else { throw LastFMAuthError.failed("Could not open your browser.") }

        let polls = Int(Self.maxSeconds / Self.pollSeconds)
        for _ in 0..<polls {
            do { try await sleep(Self.pollSeconds) } catch { throw LastFMAuthError.cancelled }
            if Task.isCancelled { throw LastFMAuthError.cancelled }
            do {
                let (name, key) = try await requestSession(k, token: token)
                try save(session: key, user: name)
                return name
            } catch let e as LastFMAPIError {
                switch e.code {
                case 14, 16: continue           // not approved yet, or Last.fm is busy for a moment
                default: throw LastFMAuthError.failed(Self.plain(e))
                }
            } catch let e as LastFMAuthError { throw e
            } catch { continue }                // a network hiccup: ask again
        }
        throw LastFMAuthError.timedOut
    }

    static func plain(_ e: LastFMAPIError) -> String {
        switch e.code {
        case 4, 15: "The Last.fm request expired. Try again."
        case 10: "Last.fm did not accept this app's key."
        case 26: "Last.fm has suspended this app's key."
        case 29: "Last.fm is limiting requests. Try again in a minute."
        default: "Last.fm: \(e.message)"
        }
    }

    // MARK: calls

    private func call(_ method: String, _ k: LastFMKeys.Pair, _ extra: [String: String]) async throws -> [String: Any] {
        let p = LastFMClient.signed(extra, method: method, apiKey: k.key, secret: k.secret)
        var c = URLComponents(); c.queryItems = p.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = URL(string: LastFMClient.defaultEndpoint.absoluteString + "?" + (c.percentEncodedQuery ?? "")) else {
            throw LastFMAuthError.failed("Could not reach Last.fm.")
        }
        let reply: (status: Int, data: Data)
        reply = try await ScrobbleHTTP.send(http, url: url, method: "GET")
        let obj = (try? JSONSerialization.jsonObject(with: reply.data)) as? [String: Any]
        if let obj, let code = obj.int("error") { throw LastFMAPIError(code: code, message: obj.str("message") ?? "error \(code)") }
        guard (200..<300).contains(reply.status), let obj else { throw ScrobbleSendError.network("HTTP \(reply.status)") }
        return obj
    }

    private func requestToken(_ k: LastFMKeys.Pair) async throws -> String {
        do {
            let o = try await call("auth.getToken", k, [:])
            guard let t = o["token"] as? String, !t.isEmpty else { throw LastFMAuthError.failed("Last.fm sent no token.") }
            return t
        } catch let e as LastFMAPIError { throw LastFMAuthError.failed(Self.plain(e))
        } catch is ScrobbleSendError { throw LastFMAuthError.failed("Could not reach Last.fm.") }
    }

    private func requestSession(_ k: LastFMKeys.Pair, token: String) async throws -> (name: String, key: String) {
        let o = try await call("auth.getSession", k, ["token": token])
        guard let s = o["session"] as? [String: Any], let name = s["name"] as? String, let key = s["key"] as? String, !name.isEmpty, !key.isEmpty
        else { throw LastFMAuthError.failed("Last.fm sent an unexpected reply.") }
        return (name, key)
    }

    private func save(session: String, user: String) throws {
        let c = LastFMProvider.Credentials(apiKey: usesBuiltInApp ? "" : (keys()?.key ?? ""), secret: usesBuiltInApp ? "" : (keys()?.secret ?? ""),
                                           sessionKey: session, username: user, usesBuiltInApp: usesBuiltInApp)
        guard let d = try? JSONEncoder().encode(c) else { throw LastFMAuthError.failed("Could not save the sign-in.") }
        store.write(String(decoding: d, as: UTF8.self), account: LastFMProvider.credentialsAccount)
        store.write(user, account: LastFMClient.usernameAccount)
    }
}

/// The screen's view of one-click sign-in.
@MainActor @Observable
final class LastFMConnectModel {
    enum State: Equatable { case idle, waiting, connected(String), failed(String) }

    private(set) var state: State = .idle
    @ObservationIgnored private let auth: LastFMAuth
    @ObservationIgnored private var task: Task<Void, Never>?

    init(auth: LastFMAuth = LastFMAuth()) { self.auth = auth }

    var isAvailable: Bool { auth.keys() != nil }

    func start() {
        guard task == nil else { return }
        state = .waiting
        let auth = auth
        task = Task { [weak self] in
            let result: Result<String, LastFMAuthError>
            do { result = .success(try await auth.connect()) } catch let e as LastFMAuthError { result = .failure(e) } catch { result = .failure(.cancelled) }
            guard let self else { return }
            self.task = nil
            switch result {
            case .success(let name): self.state = .connected(name)
            case .failure(.cancelled): self.state = .idle
            case .failure(let e): self.state = .failed(e.message)
            }
        }
    }

    func cancel() { task?.cancel() }
    func reset() { task?.cancel(); task = nil; state = .idle }
}
