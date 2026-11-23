import Testing
import Foundation
@testable import REDDY

/// The in-memory record of blocked hosts and load errors: capped, cleared on request, host and error number only, never stored.
@Suite("Service diagnostics", .serialized) @MainActor struct ServiceDiagnosticsTests {
    @Test func ringBufferKeepsTheNewestFiftyPerService() {
        let d = ServiceDiagnostics()
        for i in 0..<(ServiceDiagnostics.capacity + 20) { d.recordBlocked(.hulu, url: URL(string: "https://h\(i).example/")) }
        d.recordBlocked(.youtube, url: URL(string: "https://other.example/"))
        let e = d.entries(for: .hulu)
        #expect(ServiceDiagnostics.capacity == 50 && e.count == 50)
        #expect(e.first?.host == "h20.example" && e.last?.host == "h69.example")
        #expect(d.entries(for: .youtube).count == 1)
    }

    @Test func clearEmptiesOnlyThatService() {
        let d = ServiceDiagnostics()
        d.recordBlocked(.hulu, url: URL(string: "https://a.example/")); d.recordBlocked(.youtube, url: URL(string: "https://b.example/"))
        d.clear(.hulu)
        #expect(d.entries(for: .hulu).isEmpty && d.entries(for: .youtube).count == 1)
        d.clearAll()
        #expect(d.entries(for: .youtube).isEmpty && d.hostList(for: .youtube).isEmpty)
    }

    @Test func anAddressYieldsItsHostAndNothingElse() {
        let d = ServiceDiagnostics()
        d.recordBlocked(.hulu, url: URL(string: "https://user:secret@Evil.Example:8443/private/path?token=abc123#frag"))
        d.recordBlocked(.hulu, url: URL(string: "javascript:alert(1)"))
        d.recordBlocked(.hulu, url: URL(string: "about:blank"))
        d.recordBlocked(.hulu, url: nil)
        #expect(d.entries(for: .hulu) == [.init(host: "evil.example", kind: .blocked)])
        #expect(d.hostList(for: .hulu) == "evil.example")
        let text = String(describing: d.entries(for: .hulu))
        for secret in ["secret", "private", "token", "abc123", "frag", "8443", "user"] { #expect(!text.contains(secret), Comment(rawValue: secret)) }
    }

    @Test func aFailureKeepsTheHostAndTheErrorNumberOnly() {
        let d = ServiceDiagnostics()
        let failing = URL(string: "https://media.example/video/secret-title?session=xyz")!
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSURLErrorFailingURLErrorKey: failing, NSLocalizedDescriptionKey: "The request for secret-title timed out"])
        d.recordFailure(.hulu, error: err, fallbackURL: URL(string: "https://page.example/x"))
        d.recordFailure(.hulu, error: NSError(domain: NSURLErrorDomain, code: -1009), fallbackURL: URL(string: "https://www.hulu.com/watch?id=1"))
        d.recordFailure(.hulu, error: NSError(domain: NSURLErrorDomain, code: -1009), fallbackURL: nil)          // no host at all: nothing recorded
        #expect(d.entries(for: .hulu) == [.init(host: "media.example", kind: .failure(code: -1001)), .init(host: "www.hulu.com", kind: .failure(code: -1009))])
        let text = String(describing: d.entries(for: .hulu))
        for secret in ["secret", "session", "xyz", "video", "timed out", "watch"] { #expect(!text.contains(secret), Comment(rawValue: secret)) }
    }

    @Test func subframePopupTerminationAndHTTPStatusKeepHostAndNumberOnly() {
        let d = ServiceDiagnostics()
        d.recordSubframeBlocked(.hbomax, url: URL(string: "data:text/html,secret"))
        d.recordSubframeBlocked(.hbomax, url: URL(string: "http://Frame.Example/p?q=secret"))
        d.recordPopupRefused(.hbomax, url: URL(string: "https://u:pw@pop.example/a?t=secret"))
        d.recordProcessTerminated(.hbomax, url: URL(string: "https://www.hbomax.com/path?x=secret"))
        d.recordHTTPStatus(.hbomax, url: URL(string: "https://api.example/x?k=secret"), status: 503)
        d.recordHTTPStatus(.hbomax, url: URL(string: "https://ok.example/"), status: 200)
        d.recordHTTPStatus(.hbomax, url: URL(string: "https://ok.example/"), status: nil)
        #expect(d.entries(for: .hbomax) == [.init(host: "frame.example", kind: .subframeBlocked), .init(host: "pop.example", kind: .popupRefused),
                                            .init(host: "www.hbomax.com", kind: .processTerminated), .init(host: "api.example", kind: .httpStatus(503))])
        #expect(!String(describing: d.entries(for: .hbomax)).contains("secret"))
    }

    @Test func theCopiedListHoldsDistinctHostsOnly() {
        let d = ServiceDiagnostics()
        for u in ["https://a.example/1", "https://b.example/", "https://a.example/2?x=1"] { d.recordBlocked(.hulu, url: URL(string: u)) }
        d.recordFailure(.hulu, error: NSError(domain: NSURLErrorDomain, code: -1200), fallbackURL: URL(string: "https://b.example/"))
        #expect(d.hostList(for: .hulu) == "a.example\nb.example")
    }

    @Test func settingsShowsHostsAndCodesAndCopyAndClearActOnOneService() {
        let d = ServiceDiagnostics()
        d.recordBlocked(.youtube, url: URL(string: "https://consent.example/path?q=1"))
        d.recordFailure(.youtube, error: NSError(domain: NSURLErrorDomain, code: -1009), fallbackURL: URL(string: "https://www.youtube.com/watch?v=1"))
        d.recordBlocked(.hulu, url: URL(string: "https://x.example/"))
        let m = StreamingServicesSettingsModel(defaults: UserDefaults(suiteName: "diag-\(UUID().uuidString)")!, diagnostics: d)
        #expect(m.diagnosticLines(.youtube) == ["consent.example: blocked", "www.youtube.com: error -1009"])
        #expect(m.diagnosticHostList(.youtube) == "consent.example\nwww.youtube.com")
        m.clearDiagnostics(.youtube)
        #expect(m.diagnosticLines(.youtube).isEmpty && m.diagnosticLines(.hulu).count == 1)
    }

    @Test func nothingIsPersistedOrLogged() throws {
        let src = try String(contentsOf: ServiceSources.root.appendingPathComponent("Services/Streaming/Diagnostics/ServiceDiagnostics.swift"), encoding: .utf8)
        for token in ["UserDefaults", "FileManager", "Logger", "os_log", "NSLog", "print(", "write(", "Codable", "Keychain", "URLSession", "NSPasteboard"] { #expect(!src.contains(token), Comment(rawValue: token)) }
        let section = try String(contentsOf: ServiceSources.root.appendingPathComponent("Features/Settings/Views/StreamingServicesSettingsSection.swift"), encoding: .utf8)
        #expect(section.contains("Shown only on this Mac; hosts and error codes only; cleared when you quit."))
    }

    @Test func theNavigationDelegateRecordsABlockedMainFrameHost() async throws {
        ServiceDiagnostics.shared.clearAll(); defer { ServiceDiagnostics.shared.clearAll() }
        let rig = try await ServiceWebModelTests.Rig(.hulu); defer { rig.finish() }
        rig.show(); _ = await ServiceTestSupport.until { rig.model.phase == .ready }
        rig.model.load(rig.server.url("/redirect-out"))
        #expect(await ServiceTestSupport.until { rig.model.blockedLinkHost == "localhost" })
        let e = ServiceDiagnostics.shared.entries(for: .hulu)
        #expect(e.contains(.init(host: "localhost", kind: .blocked)))
        #expect(!String(describing: e).contains("redirect-out"))
        #expect(ServiceDiagnostics.shared.entries(for: .youtube).isEmpty)
    }

    @Test func theDelegateRecordsAnOffSiteNewWindowHostOnly() async throws {
        ServiceDiagnostics.shared.clearAll(); defer { ServiceDiagnostics.shared.clearAll() }
        let rig = try await ServiceWebModelTests.Rig(.hulu); defer { rig.finish() }
        rig.show(); _ = await ServiceTestSupport.until { rig.model.phase == .ready }
        rig.model.load(rig.server.url("/popup")); _ = await ServiceTestSupport.until { rig.title == "popup" }
        _ = try? await rig.model.webView?.evaluateJavaScript("document.getElementById('x').click()")
        #expect(await ServiceTestSupport.until { rig.model.blockedLinkHost == "localhost" })
        let e = ServiceDiagnostics.shared.entries(for: .hulu)
        // WebKit asks the navigation policy first (recorded as blocked); createWebView records popupRefused when it is reached
        #expect(e.contains { $0.host == "localhost" && ($0.kind == .blocked || $0.kind == .popupRefused) })
        #expect(!String(describing: e).contains("popup"))
    }
}
