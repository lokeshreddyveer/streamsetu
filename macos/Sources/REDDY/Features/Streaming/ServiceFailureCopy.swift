import Foundation

/// The words for each way a service's page can fail: short, no technical terms, always a way forward. The service name comes from its
/// definition; a service that never leaves the app does not suggest a browser.
enum ServiceFailureCopy {
    static func text(for failure: ServiceFailure, name: String, offersBrowser: Bool = true) -> (symbol: String, title: String, message: String) {
        func t(_ k: String) -> String { Localized.string(k, name) }
        switch failure {
        case .offline: return ("wifi.slash", Localized.string("You're offline"), Localized.string("Check your internet connection, then try again."))
        case .dnsFailure: return ("network.slash", t("%@ can't be found"), t("Your network can't find the %@ website right now. Check your connection or DNS settings, then try again."))
        case .tlsFailure: return ("lock.slash", Localized.string("The secure connection failed"), t("StreamSetu couldn't confirm that this is the real %@ website, so nothing was loaded. Try again later or on another network."))
        case .timedOut: return ("clock.badge.exclamationmark", t("%@ is taking too long"), Localized.string("The website didn't answer in time. Try again in a moment."))
        case .siteUnavailable: return ("exclamationmark.icloud", t("%@ isn't available right now"), Localized.string("The website reported a problem on its side. Try again in a few minutes."))
        case .other: return ("exclamationmark.triangle", Localized.string("The page couldn't be shown"),
                             t(offersBrowser ? "Something went wrong while opening %@. Try again, or open it in your browser." : "Something went wrong while opening %@. Try again."))
        }
    }
    static func terminated(name: String) -> (symbol: String, title: String, message: String) {
        ("arrow.triangle.2.circlepath", Localized.string("The page stopped responding"), Localized.string("%@ was closed to protect the app. Try again to reopen it.", name))
    }
}

/// Kept for the callers and tests that still use the first service's name.
enum NetflixFailureCopy {
    static func text(for failure: ServiceFailure) -> (symbol: String, title: String, message: String) { ServiceFailureCopy.text(for: failure, name: "Netflix") }
}
