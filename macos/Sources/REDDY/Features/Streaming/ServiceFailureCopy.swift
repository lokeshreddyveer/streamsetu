import Foundation

/// The words for each way a service's page can fail: short, no technical terms, always a way forward. The service name comes from its
/// definition; a service that never leaves the app does not suggest a browser.
enum ServiceFailureCopy {
    static func text(for failure: ServiceFailure, name: String, offersBrowser: Bool = true, officialSite: String? = nil) -> (symbol: String, title: String, message: String) {
        func t(_ k: String) -> String { Localized.string(k, name) }
        switch failure {
        case .offline: return ("wifi.slash", Localized.string("You're offline"), Localized.string("Check your internet connection, then try again."))
        case .dnsFailure: return ("network.slash", t("%@ can't be found"), t("Your network can't find the %@ website right now. Check your connection or DNS settings, then try again."))
        case .tlsFailure: return ("lock.slash", Localized.string("The secure connection failed"), t("StreamSetu couldn't confirm that this is the real %@ website, so nothing was loaded. Try again later or on another network."))
        case .timedOut: return ("clock.badge.exclamationmark", t("%@ is taking too long"), Localized.string("The website didn't answer in time. Try again in a moment."))
        case .siteUnavailable: return ("exclamationmark.icloud", t("%@ isn't available right now"), Localized.string("The website reported a problem on its side. Try again in a few minutes."))
        case .regionRestricted(let host, let label):
            // Neutral and true for every region: the service chose which regional site to show; the app opens only the site it is set up for.
            let page = label.map { "\(host) (\($0))" } ?? host          // the country only when the path was actually seen
            var lines = [t("%@ chooses which regional site to show from the network location it sees."), Localized.string("Regional page: %@", page)]
            if label == "US" { lines.append(t("This is %@'s old United States page.")) }          // only when /us was actually seen: the legacy, discontinued page
            lines.append(Localized.string("StreamSetu does not change or hide your location, and this app opens only %@.", officialSite ?? name))
            return ("globe", t("%@ sent this connection to another region"), lines.joined(separator: "\n"))
        case .other: return ("exclamationmark.triangle", Localized.string("The page couldn't be shown"),
                             t(offersBrowser ? "Something went wrong while opening %@. Try again, or open it in your browser." : "Something went wrong while opening %@. Try again."))
        }
    }
    /// "hotstar.com/in": the host without a leading "www." and the path of a service's start address, for the one line that says what the app opens.
    static func officialSite(_ home: URL) -> String {
        let host = (home.host ?? "").replacingOccurrences(of: "www.", with: "", options: .anchored)
        let path = home.path == "/" ? "" : home.path
        return host + path
    }

    /// The four things kept apart on the regional-restriction screen (one line each): the person's preference, the network, the service, playback.
    /// The preference line is present only for a service that declares one.
    static func regionSeparation(name: String, profile: RegionProfile?) -> [String] {
        var lines: [String] = []
        if let p = profile {
            let country = p.preferredLocale.localizedString(forRegionCode: p.preferredCountry) ?? p.preferredCountry
            lines.append(Localized.string("Preferred region: %@", "\(country) (\(p.preferredLocaleIdentifier))"))
        }
        lines.append(Localized.string("Network location: decided by your connection, not checked by StreamSetu"))
        lines.append(Localized.string("Service region: decided by %@", name))
        lines.append(Localized.string("Playback: decided by %@", name))
        return lines
    }
    static func terminated(name: String) -> (symbol: String, title: String, message: String) {
        ("arrow.triangle.2.circlepath", Localized.string("The page stopped responding"), Localized.string("%@ was closed to protect the app. Try again to reopen it.", name))
    }
}

/// Kept for the callers and tests that still use the first service's name.
enum NetflixFailureCopy {
    static func text(for failure: ServiceFailure) -> (symbol: String, title: String, message: String) { ServiceFailureCopy.text(for: failure, name: "Netflix") }
}
