import Foundation
import AppIntents

// Apple Shortcuts: a few actions that run Music commands. They go through the same door as everything else (permission "Apple Shortcuts"), so the person controls what a
// shortcut may do. Shortcuts can then be started from Siri, the menu bar, a hotkey or an automation of the person's own.

@available(macOS 13.0, iOS 16.0, *)
struct MusicPlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Control StreamSetu Music"
    static let description = IntentDescription("Play, pause, skip or change the volume in StreamSetu Music.")
    static let openAppWhenRun = false

    enum Action: String, AppEnum {
        case playPause, play, pause, next, previous, like, volumeUp, volumeDown, shuffleOn, shuffleOff
        static let typeDisplayRepresentation: TypeDisplayRepresentation = "Music action"
        static let caseDisplayRepresentations: [Action: DisplayRepresentation] = [
            .playPause: "Play or pause", .play: "Play", .pause: "Pause", .next: "Next song", .previous: "Previous song", .like: "Like this song",
            .volumeUp: "Volume up", .volumeDown: "Volume down", .shuffleOn: "Shuffle on", .shuffleOff: "Shuffle off",
        ]
    }

    @Parameter(title: "Action") var action: Action

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let r = MusicAutomation.perform(MusicCommandCall(name: action.rawValue), from: .shortcuts)
        return .result(dialog: IntentDialog(stringLiteral: r.ok ? "Done." : r.message))
    }
}

@available(macOS 13.0, iOS 16.0, *)
struct MusicPlayPlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Play a StreamSetu playlist"
    static let openAppWhenRun = false
    @Parameter(title: "Playlist name") var name: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let r = MusicAutomation.perform(MusicCommandCall(name: "playPlaylist", argument: name), from: .shortcuts)
        return .result(dialog: IntentDialog(stringLiteral: r.ok ? "Playing \(r.message)." : r.message))
    }
}

@available(macOS 13.0, iOS 16.0, *)
struct MusicNowPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "What is playing in StreamSetu"
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let r = MusicAutomation.perform(MusicCommandCall(name: "nowPlaying"), from: .shortcuts)
        return .result(value: r.message)
    }
}

@available(macOS 13.0, iOS 16.0, *)
struct StreamSetuMusicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MusicNowPlayingIntent(), phrases: ["What is playing in \(.applicationName)"], shortTitle: "What is playing", systemImageName: "music.note")
    }
}
