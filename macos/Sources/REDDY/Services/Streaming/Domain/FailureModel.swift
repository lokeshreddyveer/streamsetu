import Foundation

/// Why the page could not be shown, in the words of the person using the app (see the failure copy in the host view).
enum ServiceFailure: Equatable, Sendable {
    case offline, dnsFailure, tlsFailure, timedOut, siteUnavailable(status: Int?), other

    /// From a failed load's error domain and code. nil means "not a failure" (the load was cancelled on purpose).
    static func from(domain: String, code: Int) -> ServiceFailure? {
        if domain == NSURLErrorDomain {
            switch code {
            case NSURLErrorCancelled: return nil
            case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff, NSURLErrorNetworkConnectionLost: return .offline
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .dnsFailure
            case NSURLErrorTimedOut: return .timedOut
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired: return .tlsFailure
            case NSURLErrorCannotConnectToHost, NSURLErrorBadServerResponse, NSURLErrorBadURL, NSURLErrorHTTPTooManyRedirects, NSURLErrorRedirectToNonExistentLocation: return .siteUnavailable(status: nil)
            default: return .other
            }
        }
        if domain == "WebKitErrorDomain" && (code == 102 || code == 101) { return nil }          // load interrupted by a policy decision we made
        return .other
    }
}

/// Kept so existing code keeps compiling until the final cleanup step.
typealias NetflixFailure = ServiceFailure
