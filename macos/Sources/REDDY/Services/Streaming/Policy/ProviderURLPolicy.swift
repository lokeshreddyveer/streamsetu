import Foundation

/// One host a service may use. Matched on whole labels (never as a substring).
struct HostRule: Equatable, Sendable {
    enum Role: Sendable {
        /// The service's own pages.
        case site
        /// A sign-in host.
        case auth
        /// May be reached by a redirect, never by a typed or clicked address.
        case redirectOnly
    }
    var suffix: String
    var role: Role
    /// false = declared but NOT allowed until the owner confirms it (behaves as blocked).
    var active: Bool = true
}

enum SubframeRule: Equatable, Sendable { case anyHTTPS }
enum PopupRule: Equatable, Sendable { case sameViewIfAllowed }

/// What to do with an address a service's web view is asked to open. Pure: no WebKit, no I/O, so every rule is a table test.
/// Foundation only; shared with the iOS target because the service definitions hold one.
struct ProviderURLPolicy: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        /// Load it in the service's view.
        case allowInApp
        /// Off-site. The runtime classifies this as a cancelled navigation plus a notice (or, for a service that confirms, an external open).
        case openExternally
        /// Never load or open it.
        case block
    }

    var hostRules: [HostRule]
    /// Schemes that may be loaded in the app. Production: https only.
    var inAppSchemes: Set<String>
    /// Production keeps the site's own host to the default port; tests use a local server on a free port.
    var allowsAnyPort = false
    var subframes: SubframeRule = .anyHTTPS
    var popups: PopupRule = .sameViewIfAllowed
    /// Names a narrow adapter for what rules cannot say; nil for every service at launch.
    var adapterKey: ProviderID?

    init(hostRules: [HostRule], inAppSchemes: Set<String>, allowsAnyPort: Bool = false, adapterKey: ProviderID? = nil) {
        self.hostRules = hostRules; self.inAppSchemes = inAppSchemes; self.allowsAnyPort = allowsAnyPort; self.adapterKey = adapterKey
    }

    /// The original initialiser: every suffix is a site host.
    init(hostSuffixes: [String], inAppSchemes: Set<String>, allowsAnyPort: Bool = false) {
        self.init(hostRules: hostSuffixes.map { HostRule(suffix: $0, role: .site) }, inAppSchemes: inAppSchemes, allowsAnyPort: allowsAnyPort)
    }

    /// Suffixes of the active rules.
    var hostSuffixes: [String] { hostRules.filter(\.active).map(\.suffix) }

    private func matches(_ host: String, _ suffix: String) -> Bool { host == suffix || host.hasSuffix("." + suffix) }

    /// Allowed by an active rule of any role (a redirect-only host counts here; `decide` applies the redirect condition).
    func isAllowedHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        return hostRules.contains { $0.active && matches(h, $0.suffix) }
    }

    private func isAllowed(_ host: String, isRedirect: Bool) -> Bool {
        let h = host.lowercased()
        return hostRules.contains { $0.active && matches(h, $0.suffix) && ($0.role != .redirectOnly || isRedirect) }
    }

    /// `isMainFrame` is false for pages the site embeds (a captcha, a payment frame): those may load over https from any host, because
    /// the site chose them; they can never replace the page itself. `isRedirect` lets a redirect-only host through.
    func decide(_ url: URL?, isMainFrame: Bool, isRedirect: Bool = false) -> Decision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .block }
        if url.user != nil || url.password != nil { return .block }                 // no credentials in addresses
        switch scheme {
        case "about": return url.absoluteString == "about:blank" ? .allowInApp : .block
        case "mailto", "tel": return isMainFrame ? .openExternally : .block
        case "http", "https":
            guard let host = url.host, !host.isEmpty else { return .block }
            if !isMainFrame { return scheme == "https" || inAppSchemes.contains(scheme) ? .allowInApp : .block }
            if isAllowed(host, isRedirect: isRedirect) {
                if !allowsAnyPort, let port = url.port, port != (scheme == "https" ? 443 : 80) { return .block }          // the site is on its default port
                return inAppSchemes.contains(scheme) ? .allowInApp : .block
            }          // never downgrade the site itself to http
            return .openExternally
        default: return .block            // javascript:, data:, file:, blob:, ftp: and every app-specific scheme
        }
    }

    /// What may appear in a log: the host and the path, never the query, fragment or any credentials.
    static func loggable(_ url: URL?) -> String {
        guard let url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "-" }
        c.query = nil; c.fragment = nil; c.user = nil; c.password = nil
        return c.string ?? "-"
    }
}

/// Kept so existing code keeps compiling until the final cleanup step.
typealias NetflixURLPolicy = ProviderURLPolicy

extension ProviderURLPolicy {
    /// Netflix's policy and start page, under their old names.
    static var production: ProviderURLPolicy { ProviderCatalog.netflix.urlPolicy }
    static var homeURL: URL { ProviderCatalog.netflix.homeURL }
}
