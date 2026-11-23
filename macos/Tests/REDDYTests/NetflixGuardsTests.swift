import Testing
import Foundation
import AppKit
@testable import REDDY

/// The rules around the Netflix destination that live in the shell: dialogs, the app's own player, search, Kids and the lock.
@Suite("Netflix guards") @MainActor struct NetflixGuardsTests {
    @Test func enteringAServiceClosesDialogsCollapsesThePlayerAndPausesIt() {
        let router = AppRouter()
        router.modal = .about
        router.open(movie: Movie(id: "m", sourceID: UUID(), providerID: "m", title: "T", normalizedTitle: "t", streamRef: "x"))
        router.accountMenuOpen = true
        var collapsed = 0, paused = 0
        ServiceGuardActions.serviceEntered(router: router, collapsePlayer: { collapsed += 1 }, pausePlayer: { paused += 1 })
        #expect(router.modal == nil); #expect(router.movie == nil); #expect(router.series == nil); #expect(!router.accountMenuOpen)
        #expect(collapsed == 1 && paused == 1)
    }

    @Test func theNativePlayerStartingStopsTheServiceMedia() {
        var stopped = 0
        ServiceGuardActions.playerStarted(pauseServiceMedia: { stopped += 1 })
        #expect(stopped == 1)
    }

    @Test func kidsLockAndSearchLeaveTheServiceAndStopItsMedia() {
        for _ in 0..<3 {
            let nav = ServiceNavigation(capabilities: .macOS)
            nav.select(.netflix)
            var stopped = 0
            ServiceGuardActions.leave(services: nav, pauseServiceMedia: { stopped += 1 })
            #expect(nav.navExpanded); #expect(stopped == 1)
        }
        // the gate (Kids profile or lock) also refuses a new selection
        let nav = ServiceNavigation(capabilities: .macOS); nav.gate = { true }
        #expect(!nav.select(.netflix))
    }

    @Test func aSearchWhileAServiceShowsLeavesIt() {
        let router = AppRouter(), nav = ServiceNavigation(capabilities: .macOS)
        nav.attach(to: router); nav.select(.netflix)
        router.searchQuery = "matrix"
        #expect(router.isSearching)
        ServiceGuardActions.leave(services: nav, pauseServiceMedia: {})          // what the shell does when isSearching turns on
        #expect(nav.navExpanded)
    }

    // MARK: navigation errors -> the state the person sees

    @Test func everyNavigationErrorMapsToAStateWithItsOwnWords() {
        let cases: [(Int, NetflixFailure)] = [
            (NSURLErrorNotConnectedToInternet, .offline), (NSURLErrorNetworkConnectionLost, .offline), (NSURLErrorDataNotAllowed, .offline),
            (NSURLErrorCannotFindHost, .dnsFailure), (NSURLErrorDNSLookupFailed, .dnsFailure), (NSURLErrorTimedOut, .timedOut),
            (NSURLErrorSecureConnectionFailed, .tlsFailure), (NSURLErrorServerCertificateUntrusted, .tlsFailure), (NSURLErrorServerCertificateHasBadDate, .tlsFailure),
            (NSURLErrorServerCertificateHasUnknownRoot, .tlsFailure), (NSURLErrorServerCertificateNotYetValid, .tlsFailure),
            (NSURLErrorCannotConnectToHost, .siteUnavailable(status: nil)), (NSURLErrorBadServerResponse, .siteUnavailable(status: nil)),
            (NSURLErrorUnknown, .other)]
        var titles = Set<String>()
        for (code, expected) in cases {
            let f = NetflixFailure.from(domain: NSURLErrorDomain, code: code)
            #expect(f == expected, "code \(code)")
            if let f { titles.insert(NetflixFailureCopy.text(for: f).title) }
        }
        #expect(titles.count == 6, "offline, DNS, secure connection, timeout, site unavailable and other each have their own title")
        #expect(NetflixFailure.from(domain: NSURLErrorDomain, code: NSURLErrorCancelled) == nil)
    }

    /// No location permission is asked for, so the site cannot be given one.
    @Test func theAppAsksForNoLocationPermission() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for rel in ["Configuration/Info.plist", "Configuration/REDDY.entitlements", "Configuration/REDDY-Sandbox.entitlements"] {
            let text = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            #expect(!text.contains("NSLocation") && !text.contains("personal-information.location"), "\(rel)")
        }
    }
}

@Suite("Netflix page zoom") @MainActor struct NetflixPageZoomTests {
    private func freshDefaults() -> UserDefaults { let d = UserDefaults(suiteName: "netflix-zoom-" + UUID().uuidString)!; return d }

    @Test func defaultStepsAndClamp() {
        var z = NetflixPageZoom()
        #expect(z.value == 0.85 && z.isDefault && z.percent == 85)
        z.zoomIn(); #expect(abs(z.value - 0.90) < 0.0001)
        z.zoomOut(); z.zoomOut(); #expect(abs(z.value - 0.80) < 0.0001)
        for _ in 0..<100 { z.zoomIn() }
        #expect(z.value == 1.5 && !z.canZoomIn)
        for _ in 0..<100 { z.zoomOut() }
        #expect(abs(z.value - 0.6) < 0.0001 && !z.canZoomOut)
        z.reset(); #expect(z.isDefault)
        #expect(NetflixPageZoom.clamp(9) == 1.5 && NetflixPageZoom.clamp(-3) == NetflixPageZoom.range.lowerBound.rounded(toPlaces: 2))
        #expect(NetflixPageZoom.clamp(.nan) == 0.85 && NetflixPageZoom.clamp(.infinity) == 0.85)
        #expect(abs(NetflixPageZoom(0.873).value - 0.85) < 0.0001)          // always on a 5% step
    }

    @Test func persistsAndRecoversFromNonsense() {
        let d = freshDefaults()
        #expect(NetflixPageZoom(defaults: d).isDefault)
        var z = NetflixPageZoom(); z.zoomIn(); z.zoomIn(); z.save(to: d)
        #expect(abs(NetflixPageZoom(defaults: d).value - 0.95) < 0.0001)
        d.set(42.0, forKey: NetflixPageZoom.defaultsKey); #expect(NetflixPageZoom(defaults: d).value == 1.5)
        d.set("big", forKey: NetflixPageZoom.defaultsKey); #expect(NetflixPageZoom(defaults: d).isDefault)
    }

    @Test func theWebViewGetsTheSavedZoomAndNoPinchZoom() {
        _ = NSApplication.shared
        let d = freshDefaults()
        var z = NetflixPageZoom(); z.zoomOut(); z.zoomOut(); z.save(to: d)          // 75%
        let m = NetflixWebModel(dataStore: { .nonPersistent() }, defaults: d)
        let v = m.hostedView()
        #expect(abs(Double(v.pageZoom) - 0.75) < 0.0001)
        #expect(!v.allowsMagnification)
        m.zoomIn(); #expect(abs(Double(v.pageZoom) - 0.80) < 0.0001)
        #expect(abs(NetflixPageZoom(defaults: d).value - 0.80) < 0.0001)
        m.resetZoom(); #expect(abs(Double(v.pageZoom) - 0.85) < 0.0001)
        // recreated web view: the saved size applies again
        m.serviceBecameHidden(); m.releaseResources(); m.zoomOut()
        #expect(abs(Double(m.hostedView().pageZoom) - 0.80) < 0.0001)
        m.releaseResources()
    }
}

private extension Double { func rounded(toPlaces p: Int) -> Double { let m = pow(10.0, Double(p)); return (self * m).rounded() / m } }
