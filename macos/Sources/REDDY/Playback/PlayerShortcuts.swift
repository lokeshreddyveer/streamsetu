import Foundation

enum PlayerCommand: Equatable, Sendable {
    case togglePause, toggleFullscreen, toggleMute, exitFullscreen
    case seek(TimeInterval)
    case adjustVolume(Double)
    case channelUp, channelDown          // "up" = previous channel, "down" = next channel
    case toggleSwitcher, closeSwitcher, switcherCommit
    /// A digit typed while watching live TV: part of a channel number.
    case digit(Int)
    case numberCommit, numberCancel
    case switcherMove(Int)
}

struct PlayerShortcutContext: Sendable {
    var hasPlayback: Bool
    var isFullscreen: Bool
    var isLive: Bool
    /// The full-screen channel switcher is showing, so the arrow keys move its highlight instead of changing channel.
    var switcherOpen = false
    /// A channel number is being typed, so Return and Esc finish or cancel it.
    var numberEntryActive = false
}

/// Pure keyboard mapping so shortcut behaviour is testable. The caller must already have ruled out
/// text-field focus and Command/Control/Option combinations.
enum PlayerShortcuts {
    /// `characters` is what the key types (digits do not have one fixed key code across keyboard layouts).
    static func resolve(keyCode: UInt16, characters: String? = nil, _ c: PlayerShortcutContext) -> PlayerCommand? {
        if c.hasPlayback, c.isLive, !c.switcherOpen {
            if let ch = characters, ch.count == 1, let d = ch.first?.wholeNumberValue, ch.first?.isASCII == true { return .digit(d) }
            if c.numberEntryActive { if keyCode == 36 || keyCode == 76 { return .numberCommit }; if keyCode == 53 { return .numberCancel } }
        }
        if c.isFullscreen, c.hasPlayback, c.isLive {
            if c.switcherOpen {
                switch keyCode {
                case 126: return .switcherMove(-1)                           // Up
                case 125: return .switcherMove(1)                            // Down
                case 116: return .switcherMove(-8)                           // Page Up
                case 121: return .switcherMove(8)                            // Page Down
                case 36, 76: return .switcherCommit                          // Return, Enter
                case 53, 48, 8: return keyCode == 53 ? .closeSwitcher : .toggleSwitcher   // Esc closes; Tab and C toggle
                default: break
                }
            } else if keyCode == 48 || keyCode == 8 || keyCode == 36 { return .toggleSwitcher }     // Tab, C or Return opens it
        }
        switch keyCode {
        case 49 where c.hasPlayback: return .togglePause                    // Space
        case 3 where c.hasPlayback: return .toggleFullscreen                // F
        case 46 where c.hasPlayback: return .toggleMute                     // M
        case 53 where c.isFullscreen: return .exitFullscreen                // Escape
        // Arrows belong to lists, tables and the guide unless the player itself has the focus (fullscreen).
        case 123 where c.isFullscreen && c.hasPlayback && !c.isLive: return .seek(-10)
        case 124 where c.isFullscreen && c.hasPlayback && !c.isLive: return .seek(10)
        case 126 where c.isFullscreen && c.hasPlayback: return c.isLive ? .channelUp : .adjustVolume(0.05)
        case 125 where c.isFullscreen && c.hasPlayback: return c.isLive ? .channelDown : .adjustVolume(-0.05)
        case 116 where c.hasPlayback && c.isLive: return .channelUp         // Page Up
        case 121 where c.hasPlayback && c.isLive: return .channelDown       // Page Down
        default: return nil
        }
    }
}
