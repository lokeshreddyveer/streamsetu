import Foundation

enum NetworkError: Error, LocalizedError, Sendable {
    case invalidURL
    case offline
    /// The name of the server could not be turned into an address, while the internet itself may be fine. Often a DNS filter.
    case nameNotFound(host: String?)
    case timeout
    case http(status: Int, retryAfter: TimeInterval?)
    case tooLarge(limit: Int64)
    case cancelled
    case unreadable
    case other(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The address is not valid."
        case .offline: "No internet connection. Check your connection and try again."
        case .nameNotFound(let host):
            "The server name\(host.map { " \"\($0)\"" } ?? "") couldn't be found. If you use a DNS ad-blocker or filter (Pi-hole, AdGuard, NextDNS), a VPN with its own DNS, or a content-filtering profile, allow that name or turn it off for StreamSetu, then try again."
        case .timeout: "The server took too long to respond."
        case .http(let status, _):
            switch status {
            case 401, 403: "The provider rejected the login (HTTP \(status)). Check the username and password."
            case 404: "The provider has no resource at this address (HTTP 404)."
            case 429: "The provider is rate limiting requests. Try again in a moment."
            case 500...599: "The provider had a problem (HTTP \(status)). Try again later."
            default: "The provider returned HTTP \(status)."
            }
        case .tooLarge: "The response was larger than StreamSetu allows."
        case .cancelled: "Cancelled."
        case .unreadable: "The response could not be read."
        case .other(let m): CredentialRedactor.redact(m)
        }
    }

    var isRetryable: Bool {
        switch self {
        case .timeout, .offline, .nameNotFound: true
        case .http(let s, _): s == 408 || s == 429 || (500...599).contains(s)
        default: false
        }
    }

    var isAuthFailure: Bool {
        if case .http(let s, _) = self { return s == 401 || s == 403 }
        return false
    }

    static func from(_ error: Error) -> NetworkError {
        if let e = error as? NetworkError { return e }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCancelled: return .cancelled
            case NSURLErrorTimedOut: return .timeout
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
                return .nameNotFound(host: failing?.host)
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost: return .offline
            case NSURLErrorBadURL, NSURLErrorUnsupportedURL: return .invalidURL
            default: break
            }
        }
        return .other(error.localizedDescription)
    }
}
