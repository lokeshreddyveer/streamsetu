import Foundation
#if os(macOS)
import AppKit
import Carbon.HIToolbox

/// A key and its modifiers.
struct MusicKeyCombo: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32      // Carbon modifier bits (cmdKey, optionKey, controlKey, shiftKey)

    static func carbon(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + (MusicKeyCombo.names[keyCode] ?? MusicKeyCombo.character(keyCode) ?? "key \(keyCode)")
    }
    private static let names: [UInt32: String] = [UInt32(kVK_Space): "Space", UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→", UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
                                                  UInt32(kVK_Return): "↩", UInt32(kVK_Escape): "⎋", UInt32(kVK_Tab): "⇥"]
    private static func character(_ code: UInt32) -> String? {
        let map: [UInt32: String] = [0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
                                     18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0", 27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/"]
        return map[code]
    }
}

struct MusicAutomationKey: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var call: MusicCommandCall
    var combo: MusicKeyCombo
    /// True works from any app; false only while StreamSetu is the app in front.
    var global = true
}

/// The person's own key mappings. Global ones use the system's hotkey service (no Accessibility permission is needed); the others are caught while the app is in front.
@MainActor @Observable
final class MusicHotkeys {
    static let shared = MusicHotkeys()
    static let key = "music.automation.hotkeys"

    var bindings: [MusicAutomationKey] { didSet { save(); register() } }
    @ObservationIgnored private var refs: [EventHotKeyRef?] = []
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored weak var hub: MusicHub?

    init() { bindings = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([MusicAutomationKey].self, from: $0) } ?? [] }
    private func save() { if let d = try? JSONEncoder().encode(bindings) { UserDefaults.standard.set(d, forKey: Self.key) } }

    func start(hub: MusicHub) {
        self.hub = hub
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let index = Int(hk.id)
                DispatchQueue.main.async { MainActor.assumeIsolated { MusicHotkeys.shared.fire(index: index) } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, NSApp.keyWindow?.firstResponder is NSText == false else { return e }
                let combo = MusicKeyCombo(keyCode: UInt32(e.keyCode), modifiers: MusicKeyCombo.carbon(from: e.modifierFlags))
                guard combo.modifiers != 0, let b = self.bindings.first(where: { !$0.global && $0.combo == combo }) else { return e }
                MusicAutomation.perform(b.call, from: .hotkey, hub: self.hub ?? .shared)
                return nil
            }
        }
        register()
    }

    private func register() {
        for r in refs { if let r { UnregisterEventHotKey(r) } }
        refs = []
        for (i, b) in bindings.filter(\.global).enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x53544D55), id: UInt32(i))      // 'STMU'
            if RegisterEventHotKey(b.combo.keyCode, b.combo.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr { refs.append(ref) } else { refs.append(nil) }
        }
    }

    fileprivate func fire(index: Int) {
        let globals = bindings.filter(\.global)
        guard globals.indices.contains(index) else { return }
        MusicAutomation.perform(globals[index].call, from: .hotkey, hub: hub ?? .shared)
    }

    /// True when another of the person's own bindings already uses this key.
    func conflicts(_ combo: MusicKeyCombo, except id: UUID? = nil) -> Bool { bindings.contains { $0.combo == combo && $0.id != id } }
}
#endif
