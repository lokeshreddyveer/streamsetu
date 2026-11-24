import Testing
import WebKit
@testable import REDDY

@Suite("Service user agent", .serialized) @MainActor struct ServiceUserAgentTests {
    @Test func builderIsPure() {
        #expect(SafariUserAgent.applicationName(forSafariVersion: "26.2") == "Version/26.2 Safari/605.1.15")
        #expect(SafariUserAgent.applicationName(forSafariVersion: "26.3.1") == "Version/26.3 Safari/605.1.15")
        #expect(SafariUserAgent.applicationName(forSafariVersion: " 27 \n") == "Version/27 Safari/605.1.15")
        for bad in [nil, "", "x", "26..2", "26.a"] {
            #expect(SafariUserAgent.applicationName(forSafariVersion: bad) == "Version/\(SafariUserAgent.fallbackVersion) Safari/605.1.15")
        }
        #expect(SafariUserAgent.installedVersion(paths: ["/nonexistent"]) == nil)
    }

    @Test func everyProviderCarriesTheSafariApplicationName() {
        for d in ProviderCatalog.all {
            #expect(d.userAgentProfile == .safari, "\(d.id.rawValue)")
            let c = ServiceWebViewFactory.makeConfiguration(dataStore: .nonPersistent(), userAgent: d.userAgentProfile)
            let n = c.applicationNameForUserAgent ?? ""
            #expect(n.hasPrefix("Version/") && n.hasSuffix("Safari/605.1.15"), "\(d.id.rawValue)")
        }
    }

    @Test func spotifyIdentifiesAsSafariLikeTheOthers() {
        #expect(ProviderCatalog.spotify.userAgentProfile == .safari)
        #expect(ServiceWebViewFactory.makeConfiguration(dataStore: .nonPersistent(), userAgent: ProviderCatalog.spotify.userAgentProfile).applicationNameForUserAgent == SafariUserAgent.applicationName)
    }

    @Test func webKitDefaultProfileSetsNothing() {
        var d = ProviderCatalog.netflix; d.userAgentProfile = .webKitDefault
        #expect(ServiceWebViewFactory.makeConfiguration(dataStore: .nonPersistent(), userAgent: d.userAgentProfile).applicationNameForUserAgent == nil)
    }

    @Test func configurationIsAppliedAndThePageSeesSafari() async throws {
        let server = try ServiceFixtureServer(); try await server.start(); defer { server.stop() }
        var d = ServiceTestSupport.fixture(.netflix, server)
        d.userAgentProfile = .safari
        let v = ServiceWebViewFactory().makeWebView(definition: d, dataStore: .nonPersistent(), zoom: 1)
        #expect(v.configuration.applicationNameForUserAgent == SafariUserAgent.applicationName)
        #expect((v.customUserAgent ?? "").isEmpty)
        v.load(URLRequest(url: server.url("/home")))
        #expect(await ServiceTestSupport.until { !v.isLoading && v.url != nil })
        let ua = try await v.evaluateJavaScript("navigator.userAgent") as? String ?? ""
        print("MEASURE user agent: \(ua)")
        #expect(ua.contains("Safari/605.1.15") && ua.contains("Version/") && ua.hasPrefix("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/"))
    }

    /// Read-only capability probe on the local fixture page. It records what this web view reports and asserts nothing about availability.
    @Test func mediaKeySystemProbeRecordsAvailability() async throws {
        let server = try ServiceFixtureServer(); try await server.start(); defer { server.stop() }
        let d = ServiceTestSupport.fixture(.netflix, server)
        let v = ServiceWebViewFactory().makeWebView(definition: d, dataStore: .nonPersistent(), zoom: 1)
        v.load(URLRequest(url: server.url("/home")))
        _ = await ServiceTestSupport.until { !v.isLoading && v.url != nil }
        let js = """
        const out = {};
        const cfg = [{initDataTypes:['sinf','cenc','skd'], videoCapabilities:[{contentType:'video/mp4; codecs="avc1.640028"'}]}];
        for (const ks of ['com.apple.fps','com.apple.fps.1_0','com.apple.fps.2_0','com.apple.fps.3_0','com.widevine.alpha']) {
          try { if (!navigator.requestMediaKeySystemAccess) { out[ks] = 'no-eme-api'; continue; }
                await navigator.requestMediaKeySystemAccess(ks, cfg); out[ks] = 'available'; }
          catch (e) { out[ks] = 'unavailable:' + (e && e.name); }
        }
        const ms = (window.MediaSource || window.ManagedMediaSource);
        for (const t of ['video/mp4; codecs="avc1.640028"','video/mp4; codecs="hvc1.2.4.L123.B0"','audio/mp4; codecs="ec-3"']) {
          out['MSE ' + t] = ms ? String(ms.isTypeSupported(t)) : 'no-mse';
        }
        return JSON.stringify(out);
        """
        let r = try? await v.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
        print("MEASURE drm probe: \(r as? String ?? "probe failed")")
    }
}
