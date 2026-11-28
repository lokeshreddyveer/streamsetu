import SwiftUI
#if os(macOS)
import AppKit
#endif

/// System-wide hotkeys: a master switch (off by default) and one binding per action, recorded by pressing the keys. A binding needs Ctrl,
/// Alt or Super unless it is an F-key, and media keys cannot be bound because they already arrive through the system controls.
struct MusicHotkeysSection: View {
    let hub: MusicHub
    @State private var recording: MusicGlobalHotkeyAction?
    @State private var errors: [MusicGlobalHotkeyAction: String] = [:]
    @State private var note: String?
    @State private var monitor: Any?
    @Environment(\.reddyAccent) private var accent

    private var config: MusicHotkeyConfig { hub.library.settings.player.globalHotkeys }

    var body: some View {
        #if os(macOS)
        MusicSettingsGroup(title: "Global hotkeys") {
            MusicToggleRow(title: "Use global hotkeys", info: "Control playback from any app. A key needs Control, Option or Command unless it is an F-key. Media keys already work through the system.",
                           isOn: Binding(get: { config.enabled }, set: { on in update { $0.enabled = on } }))
            if config.enabled {
                ForEach(MusicGlobalHotkeyAction.allCases) { a in row(a) }
                ForEach(MusicGlobalHotkeyAction.allCases.filter { errors[$0] ?? MusicGlobalHotkeys.shared.errors[$0] != nil }) { a in
                    MusicNote(text: a.title + ": " + (errors[a] ?? MusicGlobalHotkeys.shared.errors[a] ?? ""), tone: .bad)
                }
            }
            if let n = note { MusicNote(text: n, tone: .bad) }
        }
        .onDisappear { stopRecording() }
        #else
        MusicNote(text: "Global hotkeys are available on the Mac app.")
        #endif
    }

    #if os(macOS)
    private func row(_ a: MusicGlobalHotkeyAction) -> some View {
        let text = config.binding(for: a)
        let shown = (try? MusicHotkeyBinding.parse(text))?.display ?? (text.isEmpty ? Localized.string("Not set") : text)
        return MusicSettingsRow(title: a.title) {
            HStack(spacing: Spacing.sm) {
                Text(verbatim: recording == a ? Localized.string("Press keys...") : shown).font(Typography.timestamp)
                    .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xxs)
                    .background(recording == a ? accent.opacity(MusicTokens.flashFill) : ColorTokens.elevated, in: RoundedRectangle(cornerRadius: MusicTokens.radiusRow, style: .continuous))
                Button((recording == a ? "Cancel" : "Record").loc) { recording == a ? stopRecording() : startRecording(a) }.musicButton()
                    .accessibilityLabel(recording == a ? Text("Cancel recording") : Text(verbatim: Localized.string("Record a key combination for %@", a.title))).atlas("control.music.settingsShortcutsCancelRecording")
                Menu {
                    Button("Clear") { set(a, "") }.disabled(text.isEmpty).atlas("control.music.settingsShortcutsClear")
                    Button("Use default") { set(a, a.defaultBinding) }.disabled(text == a.defaultBinding).atlas("control.music.settingsShortcutsUseDefault")
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(Text(verbatim: Localized.string("More for %@", a.title))).atlas("control.music.settingsShortcutsClear")
            }
        }
    }

    private func update(_ change: (inout MusicHotkeyConfig) -> Void) {
        var c = config
        change(&c)
        hub.library.settings.player.globalHotkeys = c
        // The new config is kept even when some bindings fail to register; the failures are shown next to each action.
        let failed = MusicGlobalHotkeys.shared.apply(c)
        note = failed > 0 ? "\(failed) hotkey\(failed == 1 ? "" : "s") failed to register." : nil
    }

    private func set(_ a: MusicGlobalHotkeyAction, _ text: String) { errors[a] = nil; update { $0.bindings[a.rawValue] = text } }

    private func startRecording(_ a: MusicGlobalHotkeyAction) {
        stopRecording()
        recording = a
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let (code, flags) = (event.keyCode, event.modifierFlags)
            let done: Bool = MainActor.assumeIsolated {
                if code == 53 { stopRecording(); return true }
                guard let token = MusicHotkeyBinding.token(forKeyCode: code) else { return true }
                var parts: [String] = []
                if flags.contains(.control) { parts.append("Ctrl") }
                if flags.contains(.option) { parts.append("Alt") }
                if flags.contains(.shift) { parts.append("Shift") }
                if flags.contains(.command) { parts.append("Super") }
                parts.append(token)
                accept(a, parts.joined(separator: "+"))
                return true
            }
            return done ? nil : event
        }
    }

    /// Validates a recorded combination: needs Ctrl, Alt or Super unless an F-key, and may not duplicate another action's (case-insensitive).
    private func accept(_ a: MusicGlobalHotkeyAction, _ text: String) {
        do {
            let b = try MusicHotkeyBinding.parse(text)
            if let other = config.holder(of: b, except: a) { errors[a] = "Already used for \(other.title)."; note = "\(b.display) is used for \(other.title)." ; stopRecording(); return }
            errors[a] = nil; note = nil
            update { $0.bindings[a.rawValue] = b.text }
        } catch let e as MusicHotkeyBinding.ParseError { errors[a] = e.message } catch { errors[a] = "Not a usable key combination." }
        stopRecording()
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = nil
    }
    #endif
}
