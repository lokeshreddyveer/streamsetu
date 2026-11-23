import Testing
import SwiftUI
import AppKit
@testable import REDDY

/// Renders the redesigned Setu chat to PNG files (ASSISTANT_SNAP_DIR) in several themes, light and dark, so the design can be looked at. Only checks that something real was drawn.
@MainActor @Suite("Assistant: chat snapshots", .serialized) struct AssistantSnapshotTests {
    @Test func chatInThemesLightAndDark() throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-snap-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let dir = ProcessInfo.processInfo.environment["ASSISTANT_SNAP_DIR"].map { URL(fileURLWithPath: $0) }
        // Without a folder to write to this only checks that the chat draws: one theme and two states. It runs on the main thread, so a full set (24 windows) would hold up every other main-actor test in a parallel run.
        let themes: [AppTheme] = dir == nil ? [.cinematic] : [.cinematic, .liquidGlass, .nord]
        let states = dir == nil ? ["welcome", "answer"] : ["welcome", "answer", "choices", "thinking", "notready"]
        let saved = ThemeStore.current
        defer { ThemeStore.current = saved }
        for theme in themes {
            ThemeStore.current = theme
            for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
                for state in states {
                    let model = AssistantModel()
                    model.reset()
                    if state == "answer" {
                        model.messages.append(.init(role: .person, text: "How do I turn on subtitles?"))
                        model.messages.append(.init(role: .assistant, text: "Choose your language and whether they start on, then look any time from the player.\n1. Open Settings, Playback.\n2. Turn on Show subtitles by default.\n3. Pick a Preferred subtitle language.", followUps: ["Preferred subtitle language", "Subtitle size"], followUpIDs: ["Preferred subtitle language": "a", "Subtitle size": "b"]))
                    }
                    if state == "choices" {
                        model.messages.append(.init(role: .person, text: "sync"))
                        model.messages.append(.init(role: .assistant, text: "Did you mean iCloud sync, Sync on this network or Guide sync?", followUps: ["iCloud sync", "Sync on this network", "Guide sync"], followUpIDs: ["iCloud sync": "a", "Sync on this network": "b", "Guide sync": "c"]))
                    }
                    if state == "notready" {
                        model.messages.append(.init(role: .person, text: "Why is my stream buffering?"))
                        model.messages.append(.init(role: .assistant, text: "The on-device model is not ready yet. It may still be downloading, or Apple Intelligence is turned off. Answers from the built-in guide still work: try asking about a setting."))
                    }
                    if state == "thinking" {
                        model.messages.append(.init(role: .person, text: "why does my picture stutter on channel 5"))
                        model.busy = true; model.status = "Checking playback…"
                    }
                    let view = AssistantChatView(container: c, model: model, open: { _ in }, look: { ("Home", nil, nil) }, perform: { _ in .done(nil) }, close: {})
                        .frame(width: 400, height: 600).background(ColorTokens.background).environment(\.colorScheme, scheme)
                    let host = NSHostingView(rootView: view.environment(\.container, c))
                    host.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
                    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    win.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    win.contentView = host
                    win.orderBack(nil)
                    // let SwiftUI lay out and the run loop settle (scroll views and text fields build their AppKit parts lazily)
                    for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }
                    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let png = try #require(rep.representation(using: .png, properties: [:]))
                    win.orderOut(nil)
                    #expect(png.count > 5000)
                    if let dir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); try png.write(to: dir.appendingPathComponent("chat-\(theme.rawValue)-\(name)-\(state).png")) }
                }
            }
        }
    }
}
