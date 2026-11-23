import Foundation

struct NavigationContext: Sendable {
    /// The host the in-flight main-frame load began on (nil when unknown or not a redirect).
    var fromHost: String?
    var userInitiated: Bool
    var isRedirect: Bool
}

/// ONLY for what a `HostRule` cannot say. May tighten or loosen one decision, never load anything.
/// Rules for adding one: (a) a failing config-only attempt documented in the adapter's file header, (b) a test, (c) reviewer sign-off.
protocol ProviderNavigationAdapter: Sendable {
    func refine(_ decision: ProviderURLPolicy.Decision, for url: URL, isMainFrame: Bool, context: NavigationContext) -> ProviderURLPolicy.Decision
}

/// The default: changes nothing.
struct NoAdapter: ProviderNavigationAdapter {
    func refine(_ decision: ProviderURLPolicy.Decision, for url: URL, isMainFrame: Bool, context: NavigationContext) -> ProviderURLPolicy.Decision { decision }
}

enum AdapterRegistry {
    /// Adapters live in `Policy/Adapters/`, one file per service. None exist at launch, so every service answers nil.
    static func adapter(for id: ProviderID) -> (any ProviderNavigationAdapter)? { nil }

    /// The decision a service's page navigation gets: the config-driven policy, refined by the service's adapter if it has one.
    static func decide(_ definition: ProviderDefinition, _ url: URL?, isMainFrame: Bool, context: NavigationContext) -> ProviderURLPolicy.Decision {
        let base = definition.urlPolicy.decide(url, isMainFrame: isMainFrame, isRedirect: context.isRedirect, originHost: context.fromHost)
        guard let url, let a = adapter(for: definition.id) else { return base }
        return a.refine(base, for: url, isMainFrame: isMainFrame, context: context)
    }
}
