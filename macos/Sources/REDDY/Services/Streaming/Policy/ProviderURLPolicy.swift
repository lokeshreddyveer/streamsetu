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
    /// true = this exact host only (no subdomain). Default false: the suffix and every subdomain of it.
    var exactHost: Bool = false
    /// Whole leading path segments a main-frame address must start with (for example ["in"] admits "/in" and "/in/x" but never "/india", "/in.x",
    /// "/%69n", "//in" or "/in/../us"). Empty (the default) = any path, which is how every service but one is configured. Case-sensitive.
    var pathPrefixSegments: [String] = []
}

extension HostRule {
    /// The exact hosts of Google's sign-in flow for a first-party site: the sign-in pages (including the "Sign in with Google" button's pop-up and
    /// redirect pages, which live under accounts.google.com/gsi) and the cookie hand-back page. Exact hosts only (never a "google.com" suffix, so
    /// www, myaccount, mail and every lookalike stay blocked); https only through the policy's own scheme rule; role auth. Static assets and the
    /// identity script load as sub-resources and need no rule. Every service includes this group (data, not a per-service exception).
    static let googleSignInHosts = ["accounts.google.com", "accounts.youtube.com"]
    static var googleSignIn: [HostRule] { googleSignInHosts.map { HostRule(suffix: $0, role: .auth, exactHost: true) } }
}

/// One address of the provider's OWN official regional or "not available here" pages. EXACT host name only (never a suffix, never a
/// wildcard subdomain), with an optional shape for the path. It is reached by a redirect from the provider's own site, never loaded by the
/// app; it lets StreamSetu tell "the provider's server sent this connection to its regional page" from "StreamSetu's own policy refused an
/// unexpected address". The scheme and port rules are the site's own (production: https, default port).
struct RegionNoticeHost: Equatable, Sendable {
    /// Lower-case exact host, for example "www.example.com".
    let host: String
    /// Optional regular expression the URL's path must match (for example a country-code path `^/[a-z]{2}(/|$)`); nil = any path.
    var pathPattern: String? = nil

    init(host: String, pathPattern: String? = nil) { self.host = host.lowercased(); self.pathPattern = pathPattern }

    /// A country-code path that is not "/in": the shape of the per-country pages of a service whose own pages live under one path.
    static let countryPathExceptIn = "^/(?!in(/|$))[a-z]{2}(/|$)"

    /// `path` is the RESOLVED, still percent-encoded path (so "/%75s" is not "/us").
    func matches(host other: String, path: String) -> Bool {
        guard other.lowercased() == host else { return false }
        return matchesPath(path)
    }

    func matchesPath(_ path: String) -> Bool {
        guard let pattern = pathPattern else { return true }
        return path.range(of: pattern, options: .regularExpression) != nil
    }

    /// Well formed: a plain host name (letters, digits, hyphen, dots), no wildcard, no port, no path, no leading dot; and a path pattern that compiles.
    var isWellFormed: Bool {
        guard !host.isEmpty, !host.hasPrefix("."), !host.hasSuffix("."), !host.contains(".."),
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) else { return false }
        if let p = pathPattern { return (try? NSRegularExpression(pattern: p)) != nil }
        return true
    }
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
        /// A main-frame redirect, from a load that began on the service's own site, to one of the provider's exact regional-notice hosts. The
        /// app cancels it (that host is never loaded) and says the PROVIDER's server decided this; it is not the app's own address policy.
        /// `label` is the two-letter country of the path (upper-case) when that path was actually seen; nil when it was not.
        case providerRegionRestriction(host: String, label: String?)
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
    /// The provider's own regional pages (exact hosts). Empty for every service but the one that declares them; never widens what loads.
    var regionNoticeHosts: [RegionNoticeHost] = []

    init(hostRules: [HostRule], inAppSchemes: Set<String>, allowsAnyPort: Bool = false, adapterKey: ProviderID? = nil, regionNoticeHosts: [RegionNoticeHost] = []) {
        self.hostRules = hostRules; self.inAppSchemes = inAppSchemes; self.allowsAnyPort = allowsAnyPort; self.adapterKey = adapterKey; self.regionNoticeHosts = regionNoticeHosts
    }

    /// The original initialiser: every suffix is a site host.
    init(hostSuffixes: [String], inAppSchemes: Set<String>, allowsAnyPort: Bool = false) {
        self.init(hostRules: hostSuffixes.map { HostRule(suffix: $0, role: .site) }, inAppSchemes: inAppSchemes, allowsAnyPort: allowsAnyPort)
    }

    /// Suffixes of the active rules.
    var hostSuffixes: [String] { hostRules.filter(\.active).map(\.suffix) }

    private func matches(_ host: String, _ suffix: String) -> Bool { host == suffix || host.hasSuffix("." + suffix) }
    private func matches(_ host: String, _ rule: HostRule) -> Bool { rule.exactHost ? host == rule.suffix : matches(host, rule.suffix) }

    /// Allowed by an active rule of any role at SOME path (a redirect-only host counts here; `decide` applies the redirect and path conditions).
    func isAllowedHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        return hostRules.contains { $0.active && matches(h, $0) }
    }

    /// The path's whole segments with "." and ".." resolved, from the percent-ENCODED path (nothing is decoded, so an encoded letter never
    /// matches). nil = not trustworthy: an encoded slash, backslash or dot-segment, or an empty segment inside the path ("//in"). A trailing slash is ignored.
    static func resolvedSegments(_ url: URL) -> [String]? {
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return nil }
        let low = raw.lowercased()
        if low.contains("%2f") || low.contains("%5c") || raw.contains("\\") { return nil }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        var out: [String] = []
        for (i, part) in parts.enumerated() {
            let seg = String(part)
            if ["%2e", "%2e%2e", ".%2e", "%2e."].contains(seg.lowercased()) { return nil }
            if seg == "." { continue }
            if seg == ".." { if !out.isEmpty { out.removeLast() }; continue }
            if seg.isEmpty { if i == parts.count - 1 { continue } else { return nil } }
            out.append(seg)
        }
        return out
    }

    /// A rule admits an address when its host matches and, for a path-restricted rule, the path starts with the rule's whole segments. The bare
    /// root ("/") of such a host is admitted only as a hop of a redirect that began on the service's own site (a country router's entry point);
    /// it is never reachable by a link or a typed address.
    private func isAllowed(_ host: String, segments: [String]?, isRedirect: Bool, fromSite: Bool) -> Bool {
        let h = host.lowercased()
        return hostRules.contains { r in
            guard r.active, matches(h, r), r.role != .redirectOnly || isRedirect else { return false }
            if r.pathPrefixSegments.isEmpty { return true }
            guard let segs = segments else { return false }
            return segs.starts(with: r.pathPrefixSegments) || (segs.isEmpty && isRedirect && fromSite)
        }
    }

    /// One of Google's sign-in hosts (exact) that this policy allows. Only these may open a sign-in pop-up window.
    func isGoogleSignInHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased(), HostRule.googleSignInHosts.contains(h) else { return false }
        return isAllowedHost(h)
    }

    /// An active SITE-role rule covers this host (the service's own pages, as opposed to a sign-in or redirect-only host).
    func isSiteHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        return hostRules.contains { $0.active && $0.role == .site && matches(h, $0) }
    }

    /// True when a declared regional-notice host overlaps any site-role rule (active or not): that would let a loadable host be classed as a notice.
    var regionNoticeOverlapsSite: Bool {
        regionNoticeHosts.contains { n in
            hostRules.contains { r in
                guard r.role == .site, matches(n.host, r) else { return false }
                if r.pathPrefixSegments.isEmpty { return true }
                let prefix = "/" + r.pathPrefixSegments.joined(separator: "/")
                return n.matchesPath(prefix) || n.matchesPath(prefix + "/x")          // path-aware: a notice shape that could match the service's own path overlaps
            }
        }
    }

    private func regionNotice(for url: URL, host: String, scheme: String, segments: [String]) -> RegionNoticeHost? {
        guard inAppSchemes.contains(scheme) else { return nil }                                                       // https only in production
        if !allowsAnyPort, let port = url.port, port != (scheme == "https" ? 443 : 80) { return nil }
        return regionNoticeHosts.first { $0.matches(host: host, path: "/" + segments.joined(separator: "/")) }
    }

    /// `isMainFrame` is false for pages the site embeds (a captcha, a payment frame): those may load over https from any host, because
    /// the site chose them; they can never replace the page itself. `isRedirect` lets a redirect-only host through.
    /// `originHost` is the host the in-flight main-frame load began on. Only a redirect (`isRedirect`) from a load that began on one of the
    /// service's own SITE hosts, to an exact regional-notice host, is a `providerRegionRestriction`; every other address stays `openExternally`.
    func decide(_ url: URL?, isMainFrame: Bool, isRedirect: Bool = false, originHost: String? = nil) -> Decision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .block }
        if url.user != nil || url.password != nil { return .block }                 // no credentials in addresses
        switch scheme {
        case "about": return url.absoluteString == "about:blank" ? .allowInApp : .block
        case "mailto", "tel": return isMainFrame ? .openExternally : .block
        case "http", "https":
            guard let host = url.host, !host.isEmpty else { return .block }
            if !isMainFrame { return scheme == "https" || inAppSchemes.contains(scheme) ? .allowInApp : .block }
            let segments = Self.resolvedSegments(url)
            if isAllowed(host, segments: segments, isRedirect: isRedirect, fromSite: isSiteHost(originHost)) {
                if !allowsAnyPort, let port = url.port, port != (scheme == "https" ? 443 : 80) { return .block }          // the site is on its default port
                return inAppSchemes.contains(scheme) ? .allowInApp : .block
            }          // never downgrade the site itself to http
            if isRedirect, isSiteHost(originHost), let segs = segments, let n = regionNotice(for: url, host: host, scheme: scheme, segments: segs) {
                let first = segs.first.flatMap { $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isLowercase && $0.isLetter } ? $0.uppercased() : nil }
                return .providerRegionRestriction(host: n.host, label: first)
            }
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
