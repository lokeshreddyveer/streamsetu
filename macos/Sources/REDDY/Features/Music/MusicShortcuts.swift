import Foundation
#if os(macOS)
import AppKit
import Carbon.HIToolbox
#endif

// Keyboard control for Music. Two separate things live here:
//  * the in-app table: keys that work while a Music window has focus (pure table, plus a macOS key monitor);
//  * optional system-wide hotkeys: parsing and validation here, registration through Carbon on macOS only. Off until the person turns them on.

// MARK: in-app table

enum MusicShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case playPause, seekBack, seekForward, volumeUp, volumeDown, next, previous, shuffle, repeatCycle, like, mute
    case search, toggleNowPlaying, showShortcuts, reload, escape, theatreCinema, zoomIn, zoomOut, zoomReset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playPause: "Play / Pause"; case .seekBack: "Skip back 10 seconds"; case .seekForward: "Skip forward 10 seconds"
        case .volumeUp: "Volume up"; case .volumeDown: "Volume down"; case .next: "Next"; case .previous: "Previous"
        case .shuffle: "Shuffle"; case .repeatCycle: "Repeat"; case .like: "Like"; case .mute: "Mute"
        case .search: "Command palette"; case .toggleNowPlaying: "Toggle now playing"; case .showShortcuts: "Show this list"
        case .reload: "Refresh"; case .escape: "Close"; case .theatreCinema: "Cinema (theatre mode)"
        case .zoomIn: "Zoom in"; case .zoomOut: "Zoom out"; case .zoomReset: "Actual size"
        }
    }

    /// Controls that follow the host while this device is in a listening room. Volume, mute and like stay the person's own.
    var followsRoomHost: Bool {
        switch self {
        case .playPause, .seekBack, .seekForward, .next, .previous, .shuffle, .repeatCycle: true
        default: false
        }
    }
}

/// One key press, reduced to what the table needs. The macOS monitor fills it in; tests build it by hand.
struct MusicKeyEvent: Sendable, Equatable {
    /// The typed character, lower case, without modifiers applied ("f", ";", ">", " ").
    var character: String
    var keyCode: UInt16
    var command = false
    var shift = false
    var option = false
    var control = false
    var isRepeat = false
    /// Focus is in a text field, text area or editor: unmodified keys are left alone.
    var typing = false
    /// The focused control uses arrow keys itself (slider, menu, list, dialog).
    var arrowOwner = false
    var somethingPlaying = false

    init(character: String, keyCode: UInt16 = 0, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false,
         isRepeat: Bool = false, typing: Bool = false, arrowOwner: Bool = false, somethingPlaying: Bool = true) {
        self.character = character; self.keyCode = keyCode; self.command = command; self.shift = shift; self.option = option
        self.control = control; self.isRepeat = isRepeat; self.typing = typing; self.arrowOwner = arrowOwner; self.somethingPlaying = somethingPlaying
    }
}

enum MusicShortcutTable {
    static let keyLeft: UInt16 = 123, keyRight: UInt16 = 124, keyDown: UInt16 = 125, keyUp: UInt16 = 126
    static let keyEscape: UInt16 = 53, keyF5: UInt16 = 96
    /// Step for the arrow keys and the volume keys.
    static let seekSeconds = 10.0
    static let volumeStep: Float = 0.05

    /// The action for a key press, or nil when it is not ours. "Mod" is Command on a Mac and Control elsewhere.
    /// Alt (Option) is never handled in-app: Ctrl+Alt belongs to the global hotkeys, and on some keyboards AltGr arrives as Ctrl+Alt.
    static func action(for e: MusicKeyEvent, mac: Bool = true) -> MusicShortcutAction? {
        if e.option { return nil }
        let mod = mac ? e.command : e.control
        let other = mac ? e.control : e.command
        if other { return nil }
        let c = e.character
        if !mod {
            if e.shift { return nil }
            if e.keyCode == keyF5 { return .reload }
            if e.keyCode == keyEscape { return .escape }
            if e.typing { return nil }
            if c == " " || c == ";" { return .playPause }
            if c == "f" { return .theatreCinema }
            guard e.somethingPlaying, !e.arrowOwner else { return nil }
            switch e.keyCode {
            case keyLeft: return .seekBack
            case keyRight: return .seekForward
            case keyUp: return .volumeUp
            case keyDown: return .volumeDown
            default: return nil
            }
        }
        // Zoom works with or without Shift (plus is Shift and equals on most keyboards). Quit (Command+Q) is deliberately not here: it is the
        // app's own menu command and Music never takes it over.
        if c == "+" || c == "=" { return .zoomIn }
        if c == "-" || c == "_" { return .zoomOut }
        if c == "0", !e.shift { return .zoomReset }
        // Mute needs Shift on a Mac (Cmd+M minimises); the shortcuts list is Cmd+/ because Cmd+H hides the app.
        if mac, e.shift, c == "m" { return .mute }
        if !mac, !e.shift, c == "m" { return .mute }
        if c == ">" || c == "." { return .volumeUp }
        if c == "<" || c == "," { return .volumeDown }
        if e.shift { return nil }
        // Command+F is Search (the main view binds it), so Next lives on Command+Right Arrow.
        if e.keyCode == keyRight { return .next }
        switch c {
        case "d": return .previous
        case "s": return .shuffle
        case "r": return .repeatCycle
        case "l": return .like
        case "k": return .search
        case "e": return e.somethingPlaying ? .toggleNowPlaying : nil
        case "/" where mac: return .showShortcuts
        case "h" where !mac: return .showShortcuts
        default: return nil
        }
    }

    /// The text of the help list, as pairs of action and keys.
    static func help(mac: Bool = true) -> [(MusicShortcutAction, String)] {
        let m = mac ? "\u{2318}" : "Ctrl+"
        return [
            (.playPause, "Space or ;"), (.next, mac ? "\u{2318}\u{2192}" : "Ctrl+\u{2192}"), (.previous, "\(m)D"), (.seekBack, "\u{2190}"), (.seekForward, "\u{2192}"),
            (.shuffle, "\(m)S"), (.repeatCycle, "\(m)R"), (.like, "\(m)L"), (.mute, mac ? "\u{21E7}\u{2318}M" : "Ctrl+M"),
            (.volumeUp, "\u{2191} or \(m)>"), (.volumeDown, "\u{2193} or \(m)<"), (.reload, "F5"), (.search, "\(m)K"),
            (.toggleNowPlaying, "\(m)E"), (.showShortcuts, mac ? "\u{2318}/" : "Ctrl+H"),
            (.zoomIn, "\(m)+"), (.zoomOut, "\(m)\u{2212}"), (.zoomReset, "\(m)0"),
        ]
    }
}

// MARK: performing actions

/// Runs a shortcut action against the hub. Actions that need a screen (search, now playing, help, theatre) are closures the host provides.
@MainActor
struct MusicShortcutHandler {
    let hub: MusicHub
    var onSearch: () -> Void = {}
    var onToggleNowPlaying: () -> Void = {}
    var onShowShortcuts: () -> Void = {}
    /// Refresh: rebuilds the Music view so the page in front loads its data again.
    var onReload: () -> Void = { MusicReload.shared.request() }
    var onEscape: () -> Bool = { false }
    var onCinema: () -> Void = {}

    /// Returns true when the key was used.
    @discardableResult
    func perform(_ a: MusicShortcutAction) -> Bool {
        let p = hub.player
        if a.followsRoomHost, hub.room.controlsLocked { return false }
        switch a {
        case .playPause: p.toggle()
        case .seekBack: p.skip(listeningSeconds: -MusicSeekPrefs.backSeconds())
        case .seekForward: p.skip(listeningSeconds: MusicSeekPrefs.forwardSeconds())
        case .volumeUp: p.nudgeVolume(by: MusicShortcutTable.volumeStep)
        case .volumeDown: p.nudgeVolume(by: -MusicShortcutTable.volumeStep)
        case .next: p.next()
        case .previous: p.previous()
        case .shuffle: p.shuffle.toggle()
        case .repeatCycle: p.repeatMode = MusicQueueLogic.nextRepeat(p.repeatMode)
        case .like:
            guard let t = p.current, t.providerID != "local" else { return false }
            hub.library.toggleLike(t)
        case .mute: p.toggleMute()
        case .search: onSearch()
        case .toggleNowPlaying: onToggleNowPlaying()
        case .showShortcuts: onShowShortcuts()
        case .reload: onReload()
        case .zoomIn: MusicZoom.shared.zoomIn()
        case .zoomOut: MusicZoom.shared.zoomOut()
        case .zoomReset: MusicZoom.shared.reset()
        case .escape: return onEscape()
        case .theatreCinema: onCinema()
        }
        return true
    }
}

#if os(macOS)
/// Watches key presses while a Music window is up and hands them to the table. Installed when Music appears, removed when it goes.
@MainActor
final class MusicKeyboardMonitor {
    private var token: Any?
    private let handler: MusicShortcutHandler
    private let playing: () -> Bool

    init(handler: MusicShortcutHandler, somethingPlaying: @escaping () -> Bool) { self.handler = handler; self.playing = somethingPlaying }

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let used: Bool = MainActor.assumeIsolated {
                guard let self, let a = MusicShortcutTable.action(for: Self.reduce(event, playing: self.playing())) else { return false }
                if (a == .showShortcuts || a == .toggleNowPlaying) && event.isARepeat { return true }
                return self.handler.perform(a)
            }
            return used ? nil : event
        }
    }

    func stop() {
        if let t = token { NSEvent.removeMonitor(t) }
        token = nil
    }

    static func reduce(_ e: NSEvent, playing: Bool) -> MusicKeyEvent {
        let f = e.modifierFlags
        let responder = e.window?.firstResponder
        let typing = responder is NSText || (responder as? NSTextView)?.isFieldEditor == true
        let arrowOwner = responder is NSSlider || responder is NSPopUpButton || responder is NSTableView || responder is NSOutlineView
            || e.window?.isSheet == true || e.window?.attachedSheet != nil
        return MusicKeyEvent(character: (e.charactersIgnoringModifiers ?? "").lowercased(), keyCode: e.keyCode,
                             command: f.contains(.command), shift: f.contains(.shift), option: f.contains(.option), control: f.contains(.control),
                             isRepeat: e.isARepeat, typing: typing, arrowOwner: arrowOwner, somethingPlaying: playing)
    }
}
#endif

// MARK: global hotkeys (parsing and rules; the registration is macOS only)

enum MusicGlobalHotkeyAction: String, CaseIterable, Identifiable, Sendable {
    case playPause = "play_pause", nextTrack = "next_track", prevTrack = "prev_track", volumeUp = "volume_up", volumeDown = "volume_down"
    case seekForward = "seek_forward", seekBackward = "seek_backward", showApp = "show_app", muteToggle = "mute_toggle"
    case toggleShuffle = "toggle_shuffle", toggleRepeat = "toggle_repeat"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playPause: "Play / Pause"; case .nextTrack: "Next track"; case .prevTrack: "Previous track"
        case .volumeUp: "Volume up"; case .volumeDown: "Volume down"; case .seekForward: "Skip forward 10 seconds"
        case .seekBackward: "Skip back 10 seconds"; case .showApp: "Show the app"; case .muteToggle: "Mute"
        case .toggleShuffle: "Toggle shuffle"; case .toggleRepeat: "Cycle repeat"
        }
    }

    /// Mute, shuffle and repeat start unbound: a Ctrl+Alt+letter default would steal characters from every app on some keyboards.
    var defaultBinding: String {
        switch self {
        case .playPause: "Ctrl+Alt+Space"; case .nextTrack: "Ctrl+Alt+Right"; case .prevTrack: "Ctrl+Alt+Left"
        case .volumeUp: "Ctrl+Alt+Up"; case .volumeDown: "Ctrl+Alt+Down"; case .seekForward: "Ctrl+Alt+PageUp"
        case .seekBackward: "Ctrl+Alt+PageDown"; case .showApp: "Ctrl+Alt+Home"
        case .muteToggle, .toggleShuffle, .toggleRepeat: ""
        }
    }

    static var defaultBindings: [String: String] { Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, $0.defaultBinding) }) }
}

/// A parsed binding such as "Ctrl+Alt+Space": the macOS virtual key code and the modifier flags.
struct MusicHotkeyBinding: Equatable, Sendable {
    var keyCode: UInt32
    var control: Bool
    var option: Bool
    var shift: Bool
    var command: Bool
    var token: String

    enum ParseError: Error, Equatable, Sendable {
        case empty, unknownKey(String), needsModifier, mediaKey
        var message: String {
            switch self {
            case .empty: "No key chosen."
            case .unknownKey(let k): "\"\(k)\" is not a key that can be used."
            case .needsModifier: "Needs Ctrl, Alt or Super."
            case .mediaKey: "Media keys already work through the system controls."
            }
        }
    }

    /// Carbon modifier bits: command 256, shift 512, option 2048, control 4096.
    var carbonModifiers: UInt32 { (command ? 256 : 0) | (shift ? 512 : 0) | (option ? 2048 : 0) | (control ? 4096 : 0) }

    var isFunctionKey: Bool { Self.functionTokens.contains(token) }

    /// The canonical text: modifiers in the order Ctrl, Alt, Shift, Super, then the key.
    var text: String {
        var parts: [String] = []
        if control { parts.append("Ctrl") }
        if option { parts.append("Alt") }
        if shift { parts.append("Shift") }
        if command { parts.append("Super") }
        parts.append(token)
        return parts.joined(separator: "+")
    }

    /// What the person sees on a Mac: symbols for the modifiers.
    var display: String {
        (control ? "\u{2303}" : "") + (option ? "\u{2325}" : "") + (shift ? "\u{21E7}" : "") + (command ? "\u{2318}" : "") + token
    }

    static func parse(_ raw: String) throws -> MusicHotkeyBinding {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { throw ParseError.empty }
        var control = false, option = false, shift = false, command = false
        var key: String?
        for part in text.split(separator: "+", omittingEmptySubsequences: false).map({ String($0).trimmingCharacters(in: .whitespaces) }) {
            switch part.lowercased() {
            case "ctrl", "control": control = true
            case "alt", "option": option = true
            case "shift": shift = true
            case "super", "cmd", "command", "meta": command = true
            case "": key = key ?? "+"
            default: key = part
            }
        }
        guard let k = key else { throw ParseError.empty }
        if mediaTokens.contains(k.lowercased()) { throw ParseError.mediaKey }
        guard let (token, code) = lookup(k) else { throw ParseError.unknownKey(k) }
        let b = MusicHotkeyBinding(keyCode: code, control: control, option: option, shift: shift, command: command, token: token)
        // A bare key or a Shift-only chord would fire while typing in any app. F-keys are the one exception.
        if !(control || option || command) && !b.isFunctionKey { throw ParseError.needsModifier }
        return b
    }

    static let mediaTokens: Set<String> = ["mediaplaypause", "medianext", "mediaprevious", "mediastop", "playpause", "volumeupkey", "volumedownkey"]
    static let functionTokens: Set<String> = Set((1...24).map { "F\($0)" })

    /// Key table: token to macOS virtual key code (ANSI layout). F21 to F24 have no key code on a Mac and are refused.
    private static let codes: [String: UInt32] = {
        var d: [String: UInt32] = [
            "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15,
            "Y": 16, "T": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "O": 31, "U": 32, "[": 33, "I": 34, "P": 35, "Enter": 36, "L": 37, "J": 38, "'": 39, "K": 40, ";": 41, "\\": 42,
            ",": 43, "/": 44, "N": 45, "M": 46, ".": 47, "Tab": 48, "Space": 49, "Backspace": 51, "Escape": 53,
            "Numpad0": 82, "Numpad1": 83, "Numpad2": 84, "Numpad3": 85, "Numpad4": 86, "Numpad5": 87, "Numpad6": 88, "Numpad7": 89,
            "Numpad8": 91, "Numpad9": 92,
            "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97, "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103,
            "F12": 111, "F13": 105, "F14": 107, "F15": 113, "F16": 106, "F17": 64, "F18": 79, "F19": 80, "F20": 90,
            "Left": 123, "Right": 124, "Down": 125, "Up": 126, "PageUp": 116, "PageDown": 121, "Home": 115, "End": 119,
            "Insert": 114, "Delete": 117,
        ]
        d["Return"] = 36
        return d
    }()

    private static func lookup(_ raw: String) -> (String, UInt32)? {
        let wanted = raw.lowercased()
        if wanted == "return" { return ("Enter", 36) }
        for (token, code) in codes where token.lowercased() == wanted { return (token, code) }
        return nil
    }

    /// The token for a key code seen while the person records a new binding.
    static func token(forKeyCode code: UInt16) -> String? {
        if code == 36 { return "Enter" }
        return codes.first { $0.value == UInt32(code) }?.key
    }
}

extension MusicHotkeyConfig {
    /// The action that already holds this binding (compared ignoring case and modifier order), other than `except`.
    func holder(of binding: MusicHotkeyBinding, except: MusicGlobalHotkeyAction) -> MusicGlobalHotkeyAction? {
        for a in MusicGlobalHotkeyAction.allCases where a != except {
            if let text = bindings[a.rawValue], let b = try? MusicHotkeyBinding.parse(text), b.text.lowercased() == binding.text.lowercased() { return a }
        }
        return nil
    }

    func binding(for a: MusicGlobalHotkeyAction) -> String { bindings[a.rawValue] ?? a.defaultBinding }
}

#if os(macOS)
/// Registers the global hotkeys with the system. Nothing is registered until `apply` is called with `enabled` true. Keys fire on press only.
@MainActor
final class MusicGlobalHotkeys {
    static let shared = MusicGlobalHotkeys()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: MusicGlobalHotkeyAction] = [:]
    private var handlerInstalled = false
    private var eventHandler: EventHandlerRef?
    /// What each action does. The hub sets this once.
    var perform: (MusicGlobalHotkeyAction) -> Void = { _ in }
    /// Why a binding could not be registered, per action.
    private(set) var errors: [MusicGlobalHotkeyAction: String] = [:]

    /// Unregisters everything, then registers each non-empty binding. The new config is kept even when some bindings fail; the failures
    /// are listed in `errors` next to the action.
    @discardableResult
    func apply(_ config: MusicHotkeyConfig) -> Int {
        unregisterAll()
        errors = [:]
        guard config.enabled else { return 0 }
        installHandlerIfNeeded()
        var next: UInt32 = 1
        for a in MusicGlobalHotkeyAction.allCases {
            let text = config.binding(for: a)
            guard !text.isEmpty else { continue }
            do {
                let b = try MusicHotkeyBinding.parse(text)
                var ref: EventHotKeyRef?
                let id = EventHotKeyID(signature: OSType(0x4D555348), id: next)
                let status = RegisterEventHotKey(b.keyCode, b.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
                if status == noErr, let ref { refs[next] = ref; actions[next] = a; next += 1 }
                else { errors[a] = "The system refused this key combination." }
            } catch let e as MusicHotkeyBinding.ParseError { errors[a] = e.message } catch { errors[a] = "Not a usable key combination." }
        }
        return errors.count
    }

    func unregisterAll() {
        for (_, r) in refs { UnregisterEventHotKey(r) }
        refs = [:]; actions = [:]
    }

    fileprivate func fire(_ id: UInt32) { if let a = actions[id] { perform(a) } }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let r = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                      MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if r == noErr { let id = hk.id; DispatchQueue.main.async { MainActor.assumeIsolated { MusicGlobalHotkeys.shared.fire(id) } } }
            return noErr
        }, 1, &spec, nil, &eventHandler)
        handlerInstalled = status == noErr
    }
}
#endif

extension MusicHub {
    /// What each global hotkey does. Hold the result with `MusicGlobalHotkeys.shared.perform` on macOS.
    func performGlobalHotkey(_ a: MusicGlobalHotkeyAction, bringAppForward: () -> Void = {}) {
        switch a {
        case .playPause: if !room.controlsLocked { player.toggle() }
        case .nextTrack: if !room.controlsLocked { player.next() }
        case .prevTrack: if !room.controlsLocked { player.previous() }
        case .volumeUp: player.nudgeVolume(by: MusicShortcutTable.volumeStep)
        case .volumeDown: player.nudgeVolume(by: -MusicShortcutTable.volumeStep)
        case .seekForward: if !room.controlsLocked { player.skip(listeningSeconds: MusicSeekPrefs.forwardSeconds()) }
        case .seekBackward: if !room.controlsLocked { player.skip(listeningSeconds: -MusicSeekPrefs.backSeconds()) }
        case .showApp: bringAppForward()
        case .muteToggle: player.toggleMute()
        case .toggleShuffle: if !room.controlsLocked { player.shuffle.toggle() }
        case .toggleRepeat: if !room.controlsLocked { player.repeatMode = MusicQueueLogic.nextRepeat(player.repeatMode) }
        }
    }
}
