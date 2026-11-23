import Testing
import WebKit
import AppKit
@testable import REDDY

/// The nine services that never leave the app: no link, pop-up, redirect or mail address reaches another application, whatever the page does.
/// Local fixtures only.
@Suite("No external launch", .serialized) @MainActor struct NoExternalLaunchTests {
    nonisolated static let nine: [ProviderID] = ProviderCatalog.all.filter { $0.externalLinks == .blockWithNotice }.map(\.id)

    @Test func nineServicesHaveNoWayToLeave() {
        #expect(Self.nine.count == 9 && !Self.nine.contains(.netflix))
        for d in ServiceTestSupport.blocking {
            let m = ServiceWebModel(definition: d, dataStore: { .nonPersistent() }, openExternal: { _ in Issue.record("launched \(d.id)") })
            #expect(m.openExternal == nil, "\(d.id)")
            m.openInDefaultBrowser(); m.confirmExternal()          // both are harmless when there is no opener
            #expect(m.pendingExternal == nil)
        }
    }

    @Test(arguments: NoExternalLaunchTests.nine) func everyOffSiteRouteIsCancelledWithANoticeAndNothingLaunches(_ id: ProviderID) async throws {
        let rig = try await ServiceWebModelTests.Rig(id); defer { rig.finish() }
        var launches = 0
        rig.model.openExternal = { _ in launches += 1 }
        rig.show(); _ = await ServiceTestSupport.until { rig.model.phase == .ready }
        // a redirect to another host
        rig.model.load(rig.server.url("/redirect-out"))
        #expect(await ServiceTestSupport.until { rig.model.blockedLinkHost == "localhost" }, "\(id) redirect")
        #expect(rig.model.pendingExternal == nil)
        rig.model.dismissBlockedLink()
        // a pop-up window to another host
        rig.model.load(rig.server.url("/popup")); _ = await ServiceTestSupport.until { rig.title == "popup" }
        _ = try? await rig.model.webView?.evaluateJavaScript("document.getElementById('x').click()")          // test-only click on a fixture
        #expect(await ServiceTestSupport.until { rig.model.blockedLinkHost == "localhost" }, "\(id) popup")
        #expect(rig.model.pendingExternal == nil)
        rig.model.dismissBlockedLink()
        // a mail link, a link to another host and an app-specific scheme
        rig.model.load(rig.server.url("/links")); _ = await ServiceTestSupport.until { rig.title == "links" }
        for link in ["mail", "ext", "custom"] {
            _ = try? await rig.model.webView?.evaluateJavaScript("document.getElementById('\(link)').click()")
            try? await Task.sleep(for: .milliseconds(200))
            #expect(rig.model.pendingExternal == nil, "\(id) \(link)")
            rig.model.dismissBlockedLink()
        }
        #expect(launches == 0 && rig.opened.isEmpty, "\(id): nothing was launched")
    }

    @Test func theScreensOfTheNineNameNoWayToOpenAnotherApplication() throws {
        let tokens = ["NSWorkspace", "openURL", "LSOpen", "canOpenURL", "NSApp.open"]
        let files: [(String, String)] = [
            ("Features/Streaming", "ServicesDropdown.swift"), ("Features/Streaming", "PinnedServicesBar.swift"),
            ("Features/Settings/Views", "StreamingServicesSettingsSection.swift"), ("Features/Streaming", "ServiceHostView.swift"),
            ("Features/Streaming", "ServiceFailureCopy.swift"), ("Features/Streaming", "ServiceDataClearing.swift")]
        for (dir, name) in files {
            let text = try String(contentsOf: ServiceSources.root.appendingPathComponent(dir).appendingPathComponent(name), encoding: .utf8)
            for t in tokens { #expect(!text.contains(t), "\(name) contains \(t)") }
        }
        let runtime = try ServiceSources.runtime()
        #expect(runtime.components(separatedBy: "NSWorkspace").count == 2, "the one default opener of the service that asks first")
    }
}
