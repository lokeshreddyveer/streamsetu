import Testing
import Foundation
@testable import REDDY

@Suite("Navigation adapters") struct NavigationAdapterTests {
    private let ctx = NavigationContext(fromHost: nil, userInitiated: true, isRedirect: false)

    @Test func noServiceHasAnAdapterAtLaunch() {
        for id in ProviderID.allCases { #expect(AdapterRegistry.adapter(for: id) == nil, Comment(rawValue: id.rawValue)) }
        #expect(ProviderRegistry.standard.definitions.allSatisfy { $0.urlPolicy.adapterKey == nil })
    }

    @Test func noAdapterChangesNothing() {
        let a = NoAdapter(), u = URL(string: "https://x.test/")!
        for dec in [ProviderURLPolicy.Decision.allowInApp, .openExternally, .block] { #expect(a.refine(dec, for: u, isMainFrame: true, context: ctx) == dec) }
    }

    @Test func theRegistryDecisionEqualsThePolicyWhenThereIsNoAdapter() {
        for def in ProviderRegistry.standard.definitions {
            for s in [def.homeURL.absoluteString, "https://evil.test/", "javascript:1", "mailto:a@b.test"] {
                let url = URL(string: s)
                #expect(AdapterRegistry.decide(def, url, isMainFrame: true, context: ctx) == def.urlPolicy.decide(url, isMainFrame: true))
            }
        }
        let yt = ProviderCatalog.youtube
        #expect(AdapterRegistry.decide(yt, URL(string: "https://youtu.be/x"), isMainFrame: true, context: NavigationContext(fromHost: nil, userInitiated: false, isRedirect: true)) == .allowInApp)
    }

    @Test func anAdapterMayRefineOneDecision() {
        struct Tighten: ProviderNavigationAdapter {
            func refine(_ d: ProviderURLPolicy.Decision, for url: URL, isMainFrame: Bool, context: NavigationContext) -> ProviderURLPolicy.Decision { url.path == "/no" ? .block : d }
        }
        let t = Tighten()
        #expect(t.refine(.allowInApp, for: URL(string: "https://www.hulu.com/no")!, isMainFrame: true, context: ctx) == .block)
        #expect(t.refine(.allowInApp, for: URL(string: "https://www.hulu.com/yes")!, isMainFrame: true, context: ctx) == .allowInApp)
    }
}
