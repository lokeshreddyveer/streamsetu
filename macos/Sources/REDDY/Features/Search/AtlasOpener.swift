import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Takes the person to a place the atlas knows: a tab, a sidebar list, a destination, a modal, a Settings tab or a window. The same router calls the buttons use; nothing else changes.
@MainActor enum AtlasOpener {
    static func open(_ id: String, container c: AppContainer, router: AppRouter, state: AppState) -> AssistantOutcome {
        guard let e = Atlas.entry(id) else { return .failed("I cannot find that screen any more.") }
        switch e.reach {
        case .tab(let raw):
            guard let t = AppTab(rawValue: raw) else { return .failed("\(e.title) is not a tab on this Mac.") }
            router.navigate(t); router.clearSearch(); return .done("Opened \(e.title).")
        case .shortcut(let raw):
            guard let s = Shortcut(rawValue: raw), let tab = SidebarModel.tab(for: s, current: router.tab) else { return .failed("\(e.title) is not in the sidebar on this Mac.") }
            router.navigate(tab, .shortcut(s)); router.clearSearch(); return .done("Opened \(e.title).")
        case .destination(let name):
            guard let d = Destination.allCases.first(where: { String(describing: $0) == name }) else { return .failed("I could not open \(e.title).") }
            router.go(d); router.clearSearch(); return .done("Opened \(e.title).")
        case .modal(let name):
            guard let m = ModalRoute.allCases.first(where: { String(describing: $0) == name }), m != .unlockRestricted else { return .failed("\(e.title) is not something I can open.") }
            router.modal = m; return .done("Opened \(e.title).")
        case .settingsPage(let tab):
            #if os(macOS)
            guard AtlasNavRequests.shared.showSettings(tab: tab) else { return .failed("Settings could not be opened.") }
            #endif
            return .done("Opened Settings, \(tab) tab. \(e.title) is in \(e.path.joined(separator: " > ")).")
        case .window(let id):
            AtlasNavRequests.shared.window = id
            return .done("Opened \(e.title).")
        case .searchCommand(let word):
            if let t = CommandTarget(rawValue: word) { return SearchCommandRunner.run(.init(kind: .go(t, library: nil)), container: c, router: router, state: state) ? .done("Opened \(e.title).") : .failed("Settings could not be opened.") }
            if word == "askSetu" { AssistantLauncher.shared.ask(nil); return .done("Setu is open.") }
            if word == "focusScreen" { router.focusCurrentScreenSearch(); return .done("The search box of this screen has the cursor.") }
            router.focusTopSearch()
            return .done("The search box at the top has the cursor.")
        case .deepLink: return .failed("\(e.title) is opened from its own menu.")
        case .none: return .failed("\(e.title) is not a screen I can open. \(e.path.isEmpty ? "" : "It is in \(e.path.joined(separator: " > ")).")")
        }
    }
}
