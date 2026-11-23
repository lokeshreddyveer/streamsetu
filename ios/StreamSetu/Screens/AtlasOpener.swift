import SwiftUI

/// Takes the person to a place the atlas knows on iPhone and iPad: a tab, a page of More, the Add Playlist sheet or Multi-View. The same router calls the buttons use.
@MainActor enum AtlasOpener {
    static func open(_ id: String, container c: AppContainer, router: IOSRouter, state: AppState) -> AssistantOutcome {
        guard let e = Atlas.entry(id) else { return .failed("I cannot find that screen any more.") }
        switch e.reach {
        case .tab(let name):
            guard let t = PhoneTab.allCases.first(where: { String(describing: $0) == name }) else { return .failed("\(e.title) is not a tab on this device.") }
            router.go(t); router.query = ""; return .done("Opened \(e.title).")
        case .settingsPage:
            router.go(.settings)
            return .done("Opened Settings. \(e.title) is in \(e.path.joined(separator: " > ")).")
        case .modal(let name):
            switch name {
            case "ios.addPlaylist": router.presentAdd = true; return .done("Opened Add Playlist.")
            case "ios.multiView": router.showMultiView = true; return .done("Opened Multi-View.")
            default: return .failed("\(e.title) opens from the screen it belongs to, not from here.")
            }
        case .searchCommand(let word):
            if let t = CommandTarget(rawValue: word) { SearchCommandRunner.run(.init(kind: .go(t, library: nil)), container: c, router: router, state: state); return .done("Opened \(e.title).") }
            router.go(.search); return .done("Opened Search.")
        case .shortcut, .destination, .window, .deepLink: return .failed("\(e.title) is a Mac screen. On this device, look in \(e.path.joined(separator: " > ")).")
        case .none: return .failed("\(e.title) is not a screen I can open.")
        }
    }
}
