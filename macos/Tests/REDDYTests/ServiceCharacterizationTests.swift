import Testing
import Foundation
@testable import REDDY

/// Pins the externally visible Netflix identifiers and strings as they are before the streaming-hub refactor. Any change here is a behaviour change.
@Suite("Service characterization") struct ServiceCharacterizationTests {
    private func source(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/REDDY")
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    @Test func externalServiceRawValuesAndTitles() {
        #expect(ExternalService.allCases.map(\.rawValue) == ["netflix", "primevideo", "disneyplus", "hulu", "hbomax", "peacock", "paramountplus", "appletv", "youtube", "crunchyroll", "spotify", "jiohotstar"])          // nine added by the hub, then Spotify; Netflix stays first
        #expect(ExternalService.netflix.id == "netflix")
        #expect(ExternalService.netflix.title == "Netflix")
        #expect(ServiceCapabilities.macOS.externalServices == ExternalService.allCases.filter { $0 != .jiohotstar }, "JioHotstar is on hold: defined, not listed")
        #expect(ServiceCapabilities.none.externalServices.isEmpty)
    }

    @Test func destinationStateRawValues() {
        #expect(TopLevelDestination.streamSetu.rawValue == "streamSetu")
        #expect(TopLevelDestination.service(.netflix).rawValue == "service.netflix")
        #expect(DestinationState(rawValue: "service.netflix", capabilities: .macOS).activeService == .netflix)
        #expect(DestinationState(rawValue: "service.netflix", capabilities: .none).activeService == nil)
        #expect(DestinationState(rawValue: "service.unknown", capabilities: .macOS).activeService == nil)
    }

    @Test func zoomKeyAndDefault() {
        #expect(NetflixPageZoom.defaultsKey == "netflix.pageZoom")
        #expect(NetflixPageZoom.defaultValue == 0.85)
        #expect(NetflixPageZoom.range == 0.6...1.5)
        #expect(NetflixPageZoom.step == 0.05)
    }

    @Test func homeAndPolicy() {
        #expect(NetflixURLPolicy.homeURL.absoluteString == "https://www.netflix.com/")
        #expect(NetflixURLPolicy.production.hostSuffixes == ["netflix.com"] + HostRule.googleSignInHosts)
        #expect(NetflixURLPolicy.production.inAppSchemes == ["https"])
    }

    @Test func topBarIdentifiers() {
        let plain = TopBarItem.items(for: TopBarState(tab: .home, initials: "A", accountMenuOpen: false, width: 1280, destination: .streamSetu, services: [.netflix]))
        #expect(plain.map(\.identifier) == ["tab.Home", "tab.Live TV", "tab.Movies", "tab.Series", "tab.TV Guide", "tab.Netflix"])
        #expect(plain.last?.atlas == "control.nav.netflix")
        #expect(plain.last?.title == "Netflix")
        let inService = TopBarItem.items(for: TopBarState(tab: .home, initials: "A", accountMenuOpen: false, width: 1280, destination: .service(.netflix), services: [.netflix]))
        #expect(inService.map(\.identifier) == ["tab.StreamSetu", "tab.Netflix"])
        #expect(inService.first?.atlas == "control.nav.streamsetu")
        #expect(inService.last?.selected == true)
    }

    @Test func deepLinkOpenService() {
        let url = URL(string: "streamsetu://open?tab=netflix")!
        #expect(DeepLink.parse(url, capabilities: .macOS) == .openService(.netflix))
        #expect(DeepLink.parse(url, capabilities: .none) == nil)
    }

    @Test func hostViewAccessibilityIdentifiers() throws {
        let host = try source("Features/Streaming/ServiceHostView.swift")          // the one host view; ids are templated from the service id (netflix.web ...)
        for suffix in ["slowBanner", "web", "loading", "error", "terminated", "notice"] {
            #expect(host.contains("\"\\(key).\(suffix)\""), "\(suffix)")
        }
    }

    @Test func menuShortcutsAndAtlasIdentifiers() throws {
        let menu = try source("Application/MenuCommands.swift")
        // The hub replaced the per-service Netflix menu with one Services menu acting on the active service; ⌘6 opens the Services list.
        #expect(menu.contains("Button(\"Services\") { NotificationCenter.default.post(name: .openServicesList, object: nil) }.keyboardShortcut(\"6\")"))
        #expect(menu.contains("\"menu.navigate.services\"") && menu.contains("\"menu.navigate.streamsetu\""))
        #expect(menu.contains("CommandMenu(\"Services\")"))
        #expect(menu.contains(".keyboardShortcut(.leftArrow, modifiers: .command)") && menu.contains(".keyboardShortcut(.rightArrow, modifiers: .command)"))
        #expect(menu.contains("keyboardShortcut(\"r\")") && menu.contains("keyboardShortcut(\"=\")") && menu.contains("keyboardShortcut(\"-\")"))
        #expect(menu.contains("keyboardShortcut(\"0\", modifiers: [.command, .option])"))
        #expect(menu.contains("keyboardShortcut(\"o\", modifiers: [.command, .option, .shift])"))
        for id in ["back", "forward", "reload", "zoomIn", "zoomOut", "clearData", "pin"] { #expect(menu.contains("\"menu.services.\(id)\""), Comment(rawValue: id)) }
        let atlas = try source("Atlas/Declarations/Menus.swift")
        for id in ["back", "forward", "reload", "zoomIn", "zoomOut", "actualSize", "openInBrowser", "clearData", "pin"] { #expect(atlas.contains("\"services.\(id)\""), Comment(rawValue: id)) }
    }
}
