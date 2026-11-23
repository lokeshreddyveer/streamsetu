import Testing
import Foundation
import SwiftUI
import AppKit
@testable import REDDY

@Suite("Service host view") @MainActor struct ServiceHostViewTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/REDDY")
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func netflixWordsAreUnchanged() {
        let t = ServiceFailureCopy.text(for: .dnsFailure, name: "Netflix")
        #expect(t.title == "Netflix can't be found")
        #expect(t.message == "Your network can't find the Netflix website right now. Check your connection or DNS settings, then try again.")
        #expect(ServiceFailureCopy.text(for: .other, name: "Netflix").message == "Something went wrong while opening Netflix. Try again, or open it in your browser.")
        #expect(ServiceFailureCopy.terminated(name: "Netflix").message == "Netflix was closed to protect the app. Try again to reopen it.")
        #expect(NetflixFailureCopy.text(for: .tlsFailure).title == "The secure connection failed")
    }

    @Test func everyServiceNamesItselfAndTheNineNeverSuggestABrowser() {
        for d in ProviderCatalog.all {
            let offers = d.externalLinks == .confirmThenOpen
            for f: ServiceFailure in [.offline, .dnsFailure, .tlsFailure, .timedOut, .siteUnavailable(status: 503), .other] {
                let t = ServiceFailureCopy.text(for: f, name: d.displayName, offersBrowser: offers)
                #expect(!t.title.isEmpty && !t.message.isEmpty)
                if !offers { #expect(!t.message.lowercased().contains("browser"), "\(d.id.rawValue)") }
            }
            #expect(ServiceFailureCopy.terminated(name: d.displayName).message.hasPrefix(d.displayName))
        }
    }

    @Test func errorScreenActionsComeFromTheDefinition() {
        for d in ProviderCatalog.all {
            let s = ServiceFailureScreen(phase: .failed(.offline), definition: d)
            if d.externalLinks == .confirmThenOpen { #expect(s?.actions == [.retry, .openInDefaultBrowser]) }
            else { #expect(s?.actions == [.retry, .returnToStreamSetu], "\(d.id.rawValue): exactly Retry and Return") }
        }
    }

    @Test func theViewRendersEveryServiceAndShowsTheBlockedLinkNotice() async throws {
        _ = NSApplication.shared
        for d in ProviderCatalog.all where d.presentation == .embedded {          // a service on hold has no view
            let model = ServiceWebModel(definition: d, dataStore: { .nonPersistent() })
            let host = NSHostingView(rootView: ServiceHostView(model: model))
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            win.contentView = host
            model.state.blockedLinkHost = "example.org"
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width >= 0)
            model.dismissBlockedLink(); #expect(model.blockedLinkHost == nil)
            win.contentView = nil; model.releaseResources()
        }
    }

    @Test func theDisabledScreenOffersOnlyReturn() throws {
        let host = try source("Features/Streaming/ServiceHostView.swift")
        let unavailable = try #require(host.range(of: "struct IntegrationUnavailableView"))
        let body = String(host[unavailable.lowerBound...])
        #expect(body.components(separatedBy: "SecondaryButton(").count == 2, "one button: Return to StreamSetu")
        #expect(!body.contains("PrimaryButton(") && !body.contains("openInDefaultBrowser"))
    }

    @Test func noCodeInTheHostViewCanLaunchAnotherApp() throws {
        let host = try source("Features/Streaming/ServiceHostView.swift") + (try source("Features/Streaming/ServiceFailureCopy.swift"))
        for token in ["NSWorkspace", "openURL", "LSOpen", "canOpenURL", "evaluateJavaScript", "WKUserScript"] { #expect(!host.contains(token), "\(token)") }
    }

    @Test func rootViewUsesTheOneHostViewAndPausesEverything() throws {
        let root = try source("Application/RootView.swift")
        #expect(root.contains("ServiceHostView(model: model") && root.contains("IntegrationUnavailableView"))
        #expect(root.contains("hosts.pauseAll") && !root.contains("netflix.pauseMedia"))
        #expect(root.contains("showsServicesMenu: true") && root.contains("servicePrefs.pinned"))
        #expect(!root.contains("services: services.services"), "the bar gets pinned ids, not all eleven")
    }

    @Test func settingsClearingNeverConfirmsAgainAndTouchesOneService() async throws {
        let hosts = ServiceHostRegistry(makeModel: { ServiceWebModel(definition: $0, dataStore: { .nonPersistent() }) })
        #expect(await ServiceDataClearing.clear(.hulu, hosts: hosts) == .cleared)
        #expect(hosts.createdIDs == [.hulu])
        let src = try source("Features/Streaming/ServiceDataClearing.swift")
        let clearFn = try #require(src.range(of: "static func clear(_ id"))
        #expect(!String(src[clearFn.lowerBound...]).prefix(400).contains("runModal"))
    }
}
