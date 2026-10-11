import AppIntents
import Foundation

/// A live channel Siri and Shortcuts can name.
struct ChannelEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Channel")
    static let defaultQuery = ChannelEntityQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ChannelEntityQuery: EntityStringQuery {
    @MainActor private func channels(_ configure: (inout ChannelQuery) -> Void) async -> [ChannelEntity] {
        await IOSCoordinator.shared.boot()
        guard let c = IOSCoordinator.shared.container else { return [] }
        var q = ChannelQuery(); q.collapseVariants = true; q.limit = 25; configure(&q)
        return await Task.detached { ((try? c.catalog.channels(q)) ?? []).map { ChannelEntity(id: $0.id, name: $0.name) } }.value
    }
    func entities(for identifiers: [String]) async throws -> [ChannelEntity] { await channels { $0.collapseVariants = false; $0.ids = identifiers } }
    func entities(matching string: String) async throws -> [ChannelEntity] { await channels { $0.search = string } }
    func suggestedEntities() async throws -> [ChannelEntity] { await channels { $0.favoritesOnly = true } }
}

struct PlayChannelIntent: AppIntent {
    static let title: LocalizedStringResource = "Play a Channel"
    static let description = IntentDescription("Starts a live channel from your playlists.")
    static let openAppWhenRun = true
    @Parameter(title: "Channel") var channel: ChannelEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        await IOSCoordinator.shared.boot()
        guard let c = IOSCoordinator.shared.container, let ch = try? c.catalog.channel(id: channel.id) else { return .result(dialog: "I couldn't find that channel.") }
        c.playback.play(channel: ch, queue: [ch])
        c.playback.isExpanded = true
        return .result(dialog: "Playing \(ch.name).")
    }
}

struct PausePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause StreamSetu"
    @MainActor func perform() async throws -> some IntentResult {
        await IOSCoordinator.shared.boot(); IOSCoordinator.shared.container?.playback.pause(); return .result()
    }
}

struct ResumePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume StreamSetu"
    @MainActor func perform() async throws -> some IntentResult {
        await IOSCoordinator.shared.boot(); IOSCoordinator.shared.container?.playback.resume(); return .result()
    }
}

struct StopPlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop StreamSetu"
    @MainActor func perform() async throws -> some IntentResult {
        await IOSCoordinator.shared.boot(); IOSCoordinator.shared.container?.playback.stop(); return .result()
    }
}

struct SleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set a Sleep Timer"
    @Parameter(title: "Minutes", default: 30, inclusiveRange: (1, 600)) var minutes: Int
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        await IOSCoordinator.shared.boot()
        guard let p = IOSCoordinator.shared.container?.playback, p.current != nil else { return .result(dialog: "Nothing is playing.") }
        p.startSleepTimer(minutes: minutes)
        return .result(dialog: "Playback will stop in \(minutes) minutes.")
    }
}

struct NextChannelIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Channel"
    @MainActor func perform() async throws -> some IntentResult {
        await IOSCoordinator.shared.boot(); IOSCoordinator.shared.container?.playback.nextChannel(); return .result()
    }
}

struct StreamSetuShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayChannelIntent(), phrases: ["Play \(\.$channel) in \(.applicationName)", "Watch \(\.$channel) on \(.applicationName)"], shortTitle: "Play Channel", systemImageName: "tv")
        AppShortcut(intent: PausePlaybackIntent(), phrases: ["Pause \(.applicationName)"], shortTitle: "Pause", systemImageName: "pause.fill")
        AppShortcut(intent: ResumePlaybackIntent(), phrases: ["Resume \(.applicationName)"], shortTitle: "Resume", systemImageName: "play.fill")
        AppShortcut(intent: SleepTimerIntent(), phrases: ["Set a sleep timer in \(.applicationName)"], shortTitle: "Sleep Timer", systemImageName: "moon.zzz")
        AppShortcut(intent: NextChannelIntent(), phrases: ["Next channel in \(.applicationName)"], shortTitle: "Next Channel", systemImageName: "forward.end")
    }
}
