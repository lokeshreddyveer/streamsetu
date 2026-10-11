import Foundation

struct PlaybackError: Error, Equatable, Sendable {
    enum Kind: String, Sendable {
        case network, timeout, authorization, unsupportedFormat, providerUnavailable, notFound, engineUnavailable, unknown
    }
    let kind: Kind
    let detail: String?

    init(_ kind: Kind, detail: String? = nil) { self.kind = kind; self.detail = detail.map(CredentialRedactor.redact) }

    /// Plain-language message shown to the user.
    var message: String {
        switch kind {
        case .network: "Network unavailable. Check your connection and try again."
        case .timeout: "The stream took too long to start. Try again."
        case .authorization: "Your streaming provider rejected the playback request."
        case .unsupportedFormat: "This stream format is not supported by the selected playback engine."
        case .providerUnavailable: "The stream could not be reached."
        case .notFound: "The provider no longer has this stream."
        case .engineUnavailable: "The selected playback engine is not available."
        case .unknown: "This stream can't be played."
        }
    }

    /// What to try next, in plain words. Shown under the message so a failure always comes with a way forward.
    var advice: String {
        switch kind {
        case .network: "Check your Wi-Fi or mobile data. If other apps work, your provider's server may be down."
        case .timeout: "Live streams can be slow to start. Try again, or choose the Smooth buffering profile in Settings > Playback."
        case .authorization: "Your login may have expired, or too many devices are using the account. Check the playlist's login."
        case .unsupportedFormat: "Try the other playback engine in Settings > Playback, or leave it on Automatic."
        case .providerUnavailable: "The channel may be offline right now. Try another channel, or try again later."
        case .notFound: "Refresh the playlist; the provider may have removed or renamed it."
        case .engineUnavailable: "Set the playback engine back to Automatic in Settings > Playback."
        case .unknown: "Try again. If it keeps failing, try the other playback engine or another channel."
        }
    }

    /// Network-ish failures are worth a bounded retry. Authorization and format problems are not.
    var isTransient: Bool { [.network, .timeout, .providerUnavailable, .unknown].contains(kind) }

    static func classify(_ error: Error, httpStatus: Int? = nil) -> PlaybackError {
        if let s = httpStatus { return fromHTTP(s) }
        if let pe = error as? PlaybackError { return pe }
        if let ne = error as? NetworkError {
            switch ne {
            case .offline: return .init(.network)
            case .timeout: return .init(.timeout)
            case .http(let s, _): return fromHTTP(s)
            default: return .init(.unknown, detail: ne.errorDescription)
            }
        }
        let ns = error as NSError
        switch ns.domain {
        case NSURLErrorDomain:
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed: return .init(.network)
            case NSURLErrorTimedOut: return .init(.timeout)
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost: return .init(.providerUnavailable)
            case NSURLErrorUserAuthenticationRequired, NSURLErrorNoPermissionsToReadFile: return .init(.authorization)
            default: break
            }
        case "AVFoundationErrorDomain":
            switch ns.code {
            case -11829, -11833, -11832, -11821, -11828: return .init(.unsupportedFormat, detail: ns.localizedDescription)  // not recognised / no decoder / cannot decode
            case -11835, -11836: return .init(.authorization)
            default: break
            }
            if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return classify(u) }
        case "CoreMediaErrorDomain":
            switch ns.code {
            case -12660, -12661: return .init(.authorization)                    // HTTP 403 / 401
            case -12938, -12939: return .init(.notFound)                         // HTTP 404-ish
            case -12642, -12645, -12643: return .init(.unsupportedFormat)
            case -12889, -12885, -12886: return .init(.providerUnavailable)
            default: break
            }
        default: break
        }
        return .init(.unknown, detail: error.localizedDescription)
    }

    static func fromHTTP(_ s: Int) -> PlaybackError {
        switch s {
        case 401, 403: .init(.authorization)
        case 404, 410: .init(.notFound)
        case 405, 408, 429, 500...599: .init(.providerUnavailable, detail: "HTTP \(s)")
        default: .init(.unknown, detail: "HTTP \(s)")
        }
    }
}

enum PlaybackState: Equatable, Sendable {
    case idle, resolving, preparing, buffering, playing, paused, seeking, ended
    /// A transient failure is being retried (bounded, with backoff). Distinct from `failed`, which is terminal.
    case recovering
    case failed(PlaybackError)

    var isActive: Bool { switch self { case .idle, .ended, .failed: false; default: true } }
    var isPlaying: Bool { self == .playing }
    var isBusy: Bool { switch self { case .resolving, .preparing, .buffering, .seeking, .recovering: true; default: false } }
}

enum PlaybackEvent: Sendable {
    case startResolving, resolved, buffering, ready, pause, resume
    case seekBegan, seekEnded, reachedEnd
    case failed(PlaybackError)
    case stop, retry, recover
}
